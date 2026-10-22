import AppKit
import CoreMedia
import SwiftUI

/// Something listed in the Clips tab: a whole asset, or one of its scenes.
enum BrowserItemID: Hashable {
    case asset(UUID)
    case scene(asset: UUID, scene: String)

    var assetID: UUID {
        switch self {
        case .asset(let id), .scene(let id, _): id
        }
    }
}

/// One clip of the Clips tab as it is drawn: the asset or scene, and the
/// stretch of the asset's original time it stands for.
struct BrowserEntry: Identifiable {
    var id: BrowserItemID
    var clip: MediaClip
    var start: CMTime
    var duration: CMTime
    /// The scene's number, for scenes.
    var sceneNumber: Int?
    var setByHand = false

    var seconds: Double { duration.seconds }

    /// The parts of `ranges` (in the asset's original time) inside this
    /// clip, in seconds into it, joined where they overlap or touch.
    func seconds(within ranges: [CMTimeRange]) -> [(start: Double, end: Double)] {
        let from = start.seconds, to = from + seconds
        let inside = ranges
            .map { (max($0.start.seconds, from) - from, min($0.end.seconds, to) - from) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var joined: [(start: Double, end: Double)] = []
        for (a, b) in inside {
            if let last = joined.last, a <= last.end + 1e-6 {
                joined[joined.count - 1].end = max(last.end, b)
            } else {
                joined.append((a, b))
            }
        }
        return joined
    }

    func piece(from a: Double = 0, to b: Double? = nil) -> MediaPiece {
        let timescale = max(duration.timescale, 600)
        let end = b.map { CMTimeAdd(start, CMTime(seconds: $0, preferredTimescale: timescale)) } ?? CMTimeAdd(start, duration)
        return MediaPiece(assetID: clip.id, start: CMTimeAdd(start, CMTime(seconds: a, preferredTimescale: timescale)), end: end)
    }
}

/// The browser's Clips tab: every asset as a filmstrip. A video is one
/// clip until its scenes are found, with their progress across its top,
/// and is then replaced by its scenes under its name. See docs/browser.md.
struct ClipsTab: View {
    /// The project, read and edited through an object SwiftUI doesn't
    /// watch: the tab redraws when the browser does, which compares what it
    /// shows, not at every edit (see `BrowserPanel`).
    let access: ProjectAccess
    let activeTimelineID: UUID
    @Binding var selection: TimelineSelection?
    let analysis: AssetAnalysis
    let replacement: MediaReplacementController
    let packageURL: URL?

    @AppStorage(Preferences.thumbnailInterval) private var interval = ThumbnailInterval.all
    @AppStorage(Preferences.thumbnailSize) private var thumbnailSize = ThumbnailSize.medium
    /// Off, the pointer moving over a strip leaves the viewer alone, and a
    /// click shows the frame clicked instead.
    @AppStorage(Preferences.browserSkimming) private var skimming = true
    @AppStorage(Preferences.browserMutesAddedSound) private var mutesAddedSound = false
    @State private var picked = BrowserSelection<BrowserItemID>()
    @State private var width: CGFloat = 240
    @State private var sensitivityTarget: SensitivityTarget?
    /// The end of the range being dragged out, and its fixed end.
    @State private var rangeDrag: (item: BrowserItemID, anchor: Double)?
    /// Where the arrow keys move from: the last clip clicked or stepped to.
    @State private var cursor: BrowserItemID?
    @State private var coverageCache = SceneCoverageCache()
    @FocusState private var focused: Bool
    /// Shows the clip under the pointer in the viewer; absent where there
    /// is no viewer to show it (previews, tests).
    @Environment(BrowserSkim.self) private var skim: BrowserSkim?
    /// Splits and merges scenes, showing what is picked here; absent where
    /// there is no editor (previews, tests).
    @Environment(SceneSplitter.self) private var splitter: SceneSplitter?
    /// Files on their way in, listed after the clips.
    @Environment(MediaImports.self) private var imports: MediaImports?

    private var project: EditingProject {
        get { access.value }
        nonmutating set { access.binding.wrappedValue = newValue }
    }

    private static let padding: CGFloat = 10
    /// How close to a range's end a press grabs its handle.
    private static let handleReach: CGFloat = 6

    // MARK: - Entries

    /// Everything listed, worked out once per redraw and handed to what
    /// needs it, since scenes are costly to find.
    private struct Snapshot {
        var entries: [BrowserEntry] = []
        var order: [BrowserItemID] = []
        var byID: [BrowserItemID: BrowserEntry] = [:]
        /// Only for videos whose scenes are found.
        var coverage: [UUID: SceneCoverage] = [:]

        func scenes(of assetID: UUID) -> [SceneRange] { coverage[assetID]?.scenes ?? [] }
    }

    private func makeSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        for clip in project.clips {
            guard clip.kind == .video, let track = analysis.tracks[clip.id],
                  let coverage = coverageCache.coverage(of: clip, in: project, track: track)
            else {
                snapshot.entries.append(BrowserEntry(id: .asset(clip.id), clip: clip, start: .zero, duration: clip.duration))
                continue
            }
            snapshot.coverage[clip.id] = coverage
            for (index, scene) in coverage.scenes.enumerated() {
                snapshot.entries.append(BrowserEntry(
                    id: .scene(asset: clip.id, scene: scene.id), clip: clip, start: scene.start, duration: scene.duration,
                    sceneNumber: index + 1, setByHand: scene.origin == .manual
                ))
            }
        }
        snapshot.order = snapshot.entries.map(\.id)
        snapshot.byID = Dictionary(snapshot.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshot
    }

    /// One line of the list: a video's name over its scenes, a clip's
    /// title, one row of its filmstrip, or a note under a video's scenes.
    /// Every line has an ID of its own, so a recycled line never shows
    /// another clip's title or pictures.
    private enum Line: Identifiable {
        case heading(MediaClip, sceneCount: Int)
        case title(BrowserEntry, isUsed: Bool)
        case strip(BrowserEntry, FilmstripLayout, row: Int, used: [(start: Double, end: Double)])
        case note(UUID, String)

        var id: String {
            switch self {
            case .heading(let clip, _): "heading|\(clip.id)"
            case .title(let entry, _): "title|\(entry.id)"
            case .strip(let entry, let layout, let row, _): "strip|\(entry.id)|\(row)|\(layout.rowCount)"
            case .note(let assetID, _): "note|\(assetID)"
            }
        }
    }

    private func lines(_ snapshot: Snapshot) -> [Line] {
        // What the project's timelines use of each asset, for the red line.
        let used = Dictionary(project.clips.map { ($0.id, project.usedRanges(ofMedia: $0.id)) }, uniquingKeysWith: { a, _ in a })
        var lines: [Line] = []
        var entries = snapshot.entries[...]
        for clip in project.clips {
            if let coverage = snapshot.coverage[clip.id] {
                lines.append(.heading(clip, sceneCount: coverage.scenes.count))
            }
            while let entry = entries.first, entry.clip.id == clip.id {
                entries = entries.dropFirst()
                let usedHere = entry.seconds(within: used[entry.clip.id] ?? [])
                lines.append(.title(entry, isUsed: !usedHere.isEmpty))
                let layout = layout(of: entry)
                for row in 0..<layout.rowCount {
                    lines.append(.strip(entry, layout, row: row, used: usedHere))
                }
            }
            if let coverage = snapshot.coverage[clip.id], let note = Self.coverageNote(coverage, replaced: clip.wasReplaced) {
                lines.append(.note(clip.id, note))
            }
        }
        return lines
    }

    private var cellSize: CGSize {
        CGSize(width: (thumbnailSize.height * 16 / 9).rounded(), height: thumbnailSize.height)
    }

    private func layout(of entry: BrowserEntry) -> FilmstripLayout {
        FilmstripLayout(duration: entry.seconds, interval: interval, cellSize: cellSize, width: width - Self.padding * 2)
    }

    // MARK: - Body

    var body: some View {
        let snapshot = makeSnapshot()
        let order = snapshot.order
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines(snapshot)) { line in
                    switch line {
                    case .heading(let clip, let count):
                        heading(clip, sceneCount: count)
                            .padding(.top, Design.Space.group)
                    case .title(let entry, let isUsed):
                        title(entry, isUsed: isUsed, snapshot: snapshot)
                            .padding(.top, Design.Space.step)
                            .padding(.bottom, Design.Space.tight)
                    case .strip(let entry, let layout, let row, let used):
                        stripRow(entry, layout: layout, row: row, used: used, snapshot: snapshot)
                            .padding(.bottom, FilmstripLayout.rowSpacing)
                    case .note(_, let note):
                        Text(note)
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let imports {
                    ImportingClips(imports: imports)
                }
            }
            .padding(.horizontal, Self.padding)
            .padding(.bottom, Design.Space.group)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape, "i", "o"]) { press in
            handleKey(press, snapshot: snapshot) ? .handled : .ignored
        }
        // Leaving the browser gives the viewer back to the timeline; so does
        // leaving it from the keyboard. Without skimming, a frame clicked
        // stays shown until the browser loses the keyboard, so the pointer
        // can go to look at it.
        .onHover { inside in
            if !inside, skimming { skim?.end() }
        }
        .onChange(of: focused) { _, focused in
            if !focused { skim?.end() }
        }
        .onChange(of: order) { _, order in
            picked.keep(only: order)
            coverageCache.keep(only: Set(project.clips.map(\.id)))
        }
        // Only what the person picks: a scene renamed by an edit dropping
        // out of the selection leaves the splitter where it is.
        .onChange(of: picked.revision) { _, _ in
            splitter?.follow(splitterFocus(for: picked.ordered(in: order), snapshot: snapshot))
        }
        .sheet(item: $sensitivityTarget) { target in
            SensitivitySheet(project: access.binding, target: target, track: analysis.tracks[target.assetID])
        }
        .sunken(.sunken)
    }

    // MARK: - Titles

    @ViewBuilder
    private func title(_ entry: BrowserEntry, isUsed: Bool, snapshot: Snapshot) -> some View {
        let isSelected = picked.contains(entry.id)
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.tight) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Design.Space.tight) {
                    Text(entry.sceneNumber.map { "Scene \($0)" } ?? entry.clip.name)
                        .font(Design.Typeface.label)
                        .foregroundStyle(isSelected ? Design.accent : Design.textPrimary)
                        .lineLimit(1)
                    if entry.setByHand {
                        Image(systemName: "hand.point.up.left")
                            .font(Design.Typeface.micro)
                            .foregroundStyle(Design.textTertiary)
                            .help("Boundary set by hand")
                            .accessibilityLabel("set by hand")
                    }
                }
                if case .asset = entry.id {
                    // Detection shows its progress across the strip instead.
                    AssetStatusLine(analysis: analysis, replacement: replacement, clip: entry.clip, stripShowsDetection: true)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            picked.click(entry.id)
            cursor = entry.id
        }
        .contextMenu { menu(for: entry, snapshot: snapshot) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName(entry, isUsed: isUsed))
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { picked.click(entry.id) }
        .accessibilityAction(named: "Add to Timeline") { addToTimeline(dragPieces(for: [entry.id], snapshot: snapshot)) }
        .accessibilityAction(named: "Skim Forward") { skimStep(entry, seconds: 1) }
        .accessibilityAction(named: "Skim Back") { skimStep(entry, seconds: -1) }
        .accessibilityAction(named: "Set Range Start") { setRangeEnd(.start, of: entry) }
        .accessibilityAction(named: "Set Range End") { setRangeEnd(.end, of: entry) }
    }

    /// A video's name over its scenes: not a clip itself, but where the
    /// video's own menu is.
    private func heading(_ clip: MediaClip, sceneCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.tight) {
                Text(clip.name)
                    .font(Design.Typeface.label.weight(.semibold))
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                Text(sceneCount == 1 ? "1 scene" : "\(sceneCount) scenes")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textTertiary)
            }
            AssetStatusLine(analysis: analysis, replacement: replacement, clip: clip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Add Whole Clip to Timeline") {
                addToTimeline([MediaPiece(assetID: clip.id, start: .zero, end: clip.duration)])
            }
            assetMenu(clip)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: "Add Whole Clip to Timeline") {
            addToTimeline([MediaPiece(assetID: clip.id, start: .zero, end: clip.duration)])
        }
    }

    private func accessibilityName(_ entry: BrowserEntry, isUsed: Bool) -> String {
        var parts = [entry.sceneNumber.map { "Scene \($0) of \(entry.clip.name)" } ?? entry.clip.name, durationText(entry)]
        if isUsed { parts.append("used in a timeline") }
        if let range = picked.range, range.item == entry.id {
            parts.append("range \(timecode(range.start, entry)) to \(timecode(range.end, entry))")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Strips

    private func stripRow(
        _ entry: BrowserEntry, layout: FilmstripLayout, row: Int, used: [(start: Double, end: Double)], snapshot: Snapshot
    ) -> some View {
        let rowTop = CGFloat(row) * layout.rowPitch
        let range = picked.range?.item == entry.id ? picked.range : nil
        return FilmstripRow(
            entry: entry, layout: layout, row: row,
            isSelected: picked.contains(entry.id) && range == nil,
            range: range.map { ($0.start, $0.end) },
            used: used,
            durationText: row == 0 ? durationText(entry) : nil,
            detection: row == 0 && entry.id == .asset(entry.clip.id) ? analysis : nil
        )
        .overlay(alignment: .topLeading) {
            if let skim {
                SkimLine(skim: skim, item: entry.id, layout: layout, row: row)
            }
        }
        .overlay {
            FilmstripMouseView(
                rowOffset: rowTop,
                onDown: { point, flags in pressBegan(entry, layout: layout, at: point, flags: flags) },
                onPress: { press in pressed(press, entry: entry, layout: layout, order: snapshot.order) },
                dragText: { point in dragText(entry, layout: layout, at: point, snapshot: snapshot) },
                isOnHandle: { point in handle(of: entry, layout: layout, at: point) != nil },
                onHover: { point in
                    if skimming, let point { skim(entry, at: layout.seconds(at: point)) }
                }
            )
        }
        .contextMenu { menu(for: entry, snapshot: snapshot) }
        // The title line is the clip for VoiceOver; the pictures add nothing.
        .accessibilityHidden(true)
    }

    /// The end of the clip's range whose handle is at `point`: the far
    /// end, which stays put while the handle is dragged.
    private func handle(of entry: BrowserEntry, layout: FilmstripLayout, at point: CGPoint) -> Double? {
        guard let range = picked.range, range.item == entry.id else { return nil }
        let start = layout.position(atSeconds: range.start), end = layout.position(atSeconds: range.end)
        let row = Int(point.y / layout.rowPitch)
        if row == start.row, abs(point.x - start.x) <= Self.handleReach { return range.end }
        if row == end.row, abs(point.x - end.x) <= Self.handleReach { return range.start }
        return nil
    }

    private func pressBegan(_ entry: BrowserEntry, layout: FilmstripLayout, at point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        focused = true
        let seconds = snapped(layout.seconds(at: point), entry)
        if let fixed = handle(of: entry, layout: layout, at: point) {
            rangeDrag = (entry.id, fixed)
            return true
        }
        guard flags.contains(.option) else { return false }
        rangeDrag = (entry.id, seconds)
        picked.setRange(of: entry.id, from: seconds, to: seconds, duration: entry.seconds)
        return true
    }

    private func pressed(_ press: FilmstripPress, entry: BrowserEntry, layout: FilmstripLayout, order: [BrowserItemID]) {
        switch press {
        case .click(let point, let flags):
            cursor = entry.id
            if flags.contains(.command) {
                picked.commandClick(entry.id)
            } else if flags.contains(.shift) {
                picked.shiftClick(entry.id, in: order)
            } else {
                picked.click(entry.id, at: layout.seconds(at: point))
                if !skimming { skim(entry, at: layout.seconds(at: point)) }
            }
        case .track(let point):
            guard let rangeDrag, rangeDrag.item == entry.id else { return }
            picked.setRange(of: entry.id, from: rangeDrag.anchor, to: snapped(layout.seconds(at: point), entry), duration: entry.seconds)
            // The viewer shows the end being dragged, as skimming does.
            skim(entry, at: layout.seconds(at: point))
        case .endTrack:
            rangeDrag = nil
            // A press with Option that never moved picks nothing.
            if let range = picked.range, range.item == entry.id, range.end - range.start < frameSeconds(entry) {
                picked.click(entry.id)
            }
        }
    }

    /// What a drag from `point` carries: the range when it starts inside
    /// the clip's range, otherwise the clip, or every selected clip when it
    /// is one of them.
    private func dragText(_ entry: BrowserEntry, layout: FilmstripLayout, at point: CGPoint, snapshot: Snapshot) -> (text: String, image: NSImage)? {
        // Dragged to the timeline, the viewer goes back to showing it.
        skim?.end()
        let pieces: [MediaPiece]
        if let range = picked.range, range.item == entry.id, range.contains(layout.seconds(at: point)) {
            pieces = [entry.piece(from: range.start, to: range.end)]
        } else {
            if !picked.contains(entry.id) { picked.click(entry.id) }
            pieces = dragPieces(for: picked.dragged(from: entry.id, in: snapshot.order), snapshot: snapshot)
        }
        guard let first = pieces.first, let clip = project.mediaClip(id: first.assetID) else { return nil }
        let image = Self.dragImage(of: clip, at: first.start, size: cellSize, count: pieces.count)
        return (MediaDragPayload.beginDrag(pieces).text, image)
    }

    /// One thumbnail of the first thing dragged: its picture at its start,
    /// or the nearest one made (a range seldom starts where a thumbnail
    /// does); for sound, a tile of its colour with a waveform on it, as for
    /// a picture not yet made. With how many things are dragged when there
    /// are several.
    static func dragImage(of clip: MediaClip, at start: CMTime, size: CGSize, count: Int) -> NSImage {
        let picture = clip.kind.hasPictures ? clip.url.flatMap {
            FrameThumbnails.nearestCached(url: $0, time: clip.fileTime(forSourceTime: start), height: size.height)
        } : nil
        let waveform = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size.height * 0.4, weight: .medium))
        let tone = NSColor(Design.ClipTone.of(.media(clip), streams: .videoAndAudio).color)
        return NSImage(size: size, flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect, xRadius: Design.Radius.chip, yRadius: Design.Radius.chip)
            (picture == nil ? tone : NSColor.black).setFill()
            tile.fill()
            if let picture {
                let fitted = picture.size.width > 0 && picture.size.height > 0
                    ? min(rect.width / picture.size.width, rect.height / picture.size.height) : 1
                let drawn = CGSize(width: picture.size.width * fitted, height: picture.size.height * fitted)
                picture.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            } else if let waveform {
                // Tinted white: a symbol image draws in its own colour.
                let tinted = NSImage(size: waveform.size, flipped: false) { bounds in
                    waveform.draw(in: bounds)
                    NSColor.white.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: CGRect(
                    x: rect.midX - waveform.size.width / 2, y: rect.midY - waveform.size.height / 2,
                    width: waveform.size.width, height: waveform.size.height
                ))
            }
            NSColor(Design.accent).setStroke()
            tile.lineWidth = 2
            tile.stroke()
            if count > 1 {
                let text = NSAttributedString(string: "\(count)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
                ])
                let badge = CGRect(x: rect.maxX - text.size().width - 14, y: rect.maxY - 20, width: text.size().width + 10, height: 16)
                NSColor(Design.accent).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
                text.draw(at: CGPoint(x: badge.minX + 5, y: badge.minY + (badge.height - text.size().height) / 2))
            }
            return true
        }
    }

    /// The pieces for `ids`, in that order. A scene whose whole asset is
    /// also picked is left out, since the asset already carries it.
    private func dragPieces(for ids: [BrowserItemID], snapshot: Snapshot) -> [MediaPiece] {
        let wholeAssets = Set(ids.compactMap { id -> UUID? in
            if case .asset(let asset) = id { return asset }
            return nil
        })
        return ids.compactMap { id in
            if case .scene(let asset, _) = id, wholeAssets.contains(asset) { return nil }
            return snapshot.byID[id]?.piece()
        }
    }

    // MARK: - Times

    private func frameSeconds(_ entry: BrowserEntry) -> Double {
        entry.clip.frameRate > 0 ? 1 / entry.clip.frameRate : 1.0 / 600
    }

    /// `seconds` on the nearest frame of the clip.
    private func snapped(_ seconds: Double, _ entry: BrowserEntry) -> Double {
        guard entry.clip.frameRate > 0 else { return seconds }
        return min((seconds * entry.clip.frameRate).rounded() / entry.clip.frameRate, entry.seconds)
    }

    private func timecode(_ seconds: Double, _ entry: BrowserEntry) -> String {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return entry.clip.frameRate > 0 ? time.compactTimecode(frameRate: entry.clip.frameRate) : time.formatted
    }

    private func durationText(_ entry: BrowserEntry) -> String {
        timecode(entry.seconds, entry)
    }

    // MARK: - Skimming

    private func skimTarget(_ entry: BrowserEntry) -> BrowserSkim.Target {
        BrowserSkim.Target(item: entry.id, clip: entry.clip, start: entry.start, duration: entry.duration)
    }

    /// Shows `entry` at `seconds` into it in the viewer, on its nearest frame.
    private func skim(_ entry: BrowserEntry, at seconds: Double) {
        skim?.skim(skimTarget(entry), at: snapped(seconds, entry))
    }

    /// Where `entry` is skimmed, in seconds into it; nil when it isn't.
    private func skimmed(_ entry: BrowserEntry) -> Double? {
        guard let skim, skim.target?.item == AnyHashable(entry.id) else { return nil }
        return skim.seconds
    }

    private func skimmedEntry(_ snapshot: Snapshot) -> BrowserEntry? {
        (skim?.target?.item.base as? BrowserItemID).flatMap { snapshot.byID[$0] }
    }

    /// The clip the keyboard skims: the one last stepped to or clicked
    /// while it is selected, otherwise the first selected.
    private func keyboardEntry(_ snapshot: Snapshot) -> BrowserEntry? {
        let id = cursor.flatMap { picked.contains($0) ? $0 : nil } ?? picked.ordered(in: snapshot.order).first
        return id.flatMap { snapshot.byID[$0] }
    }

    /// Moves `entry`'s skim position by `seconds`, from its start when it
    /// isn't skimmed yet.
    private func skimStep(_ entry: BrowserEntry, seconds: Double) {
        skim(entry, at: (skimmed(entry) ?? 0) + seconds)
    }

    private enum RangeEnd { case start, end }

    /// Sets the start or end of `entry`'s range where it is skimmed, keeping
    /// the other end (or the clip's own); false when it isn't skimmed.
    @discardableResult
    private func setRangeEnd(_ end: RangeEnd, of entry: BrowserEntry) -> Bool {
        guard let at = skimmed(entry) else { return false }
        let current = picked.range?.item == entry.id ? picked.range : nil
        switch end {
        case .start:
            picked.setRange(of: entry.id, from: at, to: max(current?.end ?? entry.seconds, at), duration: entry.seconds)
        case .end:
            picked.setRange(of: entry.id, from: min(current?.start ?? 0, at), to: at, duration: entry.seconds)
        }
        cursor = entry.id
        return true
    }

    // MARK: - Keys

    /// Up and down move the selection (Shift extends it); Return adds the
    /// selection to the timeline. Option-Left and Option-Right skim the
    /// selected clip a frame at a time (ten with Shift), I and O set its
    /// range's ends where it is skimmed, and Escape stops skimming.
    private func handleKey(_ press: KeyPress, snapshot: Snapshot) -> Bool {
        let order = snapshot.order
        switch press.key {
        case .leftArrow, .rightArrow:
            guard press.modifiers.contains(.option), let entry = keyboardEntry(snapshot) else { return false }
            let frames = (press.modifiers.contains(.shift) ? 10 : 1) * (press.key == .leftArrow ? -1 : 1)
            if skimmed(entry) == nil { skim(entry, at: picked.range?.item == entry.id ? picked.range?.start ?? 0 : 0) }
            skim?.step(frames: frames)
            return true
        case "i", "o":
            guard press.modifiers.isEmpty, let entry = skimmedEntry(snapshot) ?? keyboardEntry(snapshot) else { return false }
            return setRangeEnd(press.key == "i" ? .start : .end, of: entry)
        case .escape:
            guard skim?.isActive == true else { return false }
            skim?.end()
            return true
        default:
            break
        }
        if press.key == .return {
            let ids = picked.ordered(in: order)
            guard !ids.isEmpty else { return false }
            if let range = picked.range, let entry = snapshot.byID[range.item] {
                addToTimeline([entry.piece(from: range.start, to: range.end)])
            } else {
                addToTimeline(dragPieces(for: ids, snapshot: snapshot))
            }
            return true
        }
        guard !order.isEmpty else { return false }
        let current = cursor.flatMap { order.firstIndex(of: $0) }
        let next: Int
        switch press.key {
        case .upArrow: next = max((current ?? order.count) - 1, 0)
        case .downArrow: next = min((current ?? -1) + 1, order.count - 1)
        default: return false
        }
        cursor = order[next]
        skim?.end()
        // Shift extends from the anchor, which stays put, to the cursor.
        if press.modifiers.contains(.shift) {
            picked.shiftClick(order[next], in: order)
        } else {
            picked.click(order[next])
        }
        return true
    }

    // MARK: - Menus

    @ViewBuilder
    private func menu(for entry: BrowserEntry, snapshot: Snapshot) -> some View {
        let ids = picked.contains(entry.id) ? picked.ordered(in: snapshot.order) : [entry.id]
        Button(ids.count > 1 ? "Add \(ids.count) Clips to Timeline" : "Add to Timeline") {
            if let range = picked.range, range.item == entry.id {
                addToTimeline([entry.piece(from: range.start, to: range.end)])
            } else {
                addToTimeline(dragPieces(for: ids, snapshot: snapshot))
            }
        }
        if ids.count == 1 {
            switch entry.id {
            case .asset:
                assetMenu(entry.clip)
            case .scene(let assetID, _):
                sceneMenu(entry, assetID: assetID, scenes: snapshot.scenes(of: assetID))
            }
        } else {
            let sceneIDs = ids.compactMap { id -> String? in
                if case .scene(let asset, let scene) = id, asset == entry.clip.id { return scene }
                return nil
            }
            let scenes = snapshot.scenes(of: entry.clip.id)
            if sceneIDs.count == ids.count {
                Divider()
                Button("Split Scenes…") { splitter?.show(splitterFocus(for: ids, snapshot: snapshot)) }
                if !cutsToRemove(Set(sceneIDs), in: scenes).isEmpty {
                    Button("Merge Selected Scenes") { mergeScenes(Set(sceneIDs), assetID: entry.clip.id, scenes: scenes) }
                }
            }
        }
    }

    @ViewBuilder
    private func assetMenu(_ clip: MediaClip) -> some View {
        if clip.kind == .video {
            Divider()
            Button("Split Scenes…") {
                splitter?.show(SceneSplitter.Focus(assetID: clip.id, start: .zero, end: clip.duration))
            }
            Button("Cut Sensitivity…") {
                sensitivityTarget = SensitivityTarget(assetID: clip.id)
            }
            .disabled(analysis.tracks[clip.id] == nil)
            AnalysisIdleButton(title: "Find Scenes Again", analysis: analysis, assetID: clip.id) {
                analysis.reanalyze(clip, in: project)
            }
        }
        if let problem = analysis.persistenceProblem(for: clip.id) {
            Button(problem.kind == .unreadableProject ? "Retry Reading Results" : "Retry Saving Results") {
                Task { await analysis.retryPersistence() }
            }
        }
        if analysis.firstFailure(for: clip.id) != nil {
            AnalysisIdleButton(title: "Retry Failed Analysis", analysis: analysis, assetID: clip.id) {
                analysis.retryFailures(for: clip.id, in: project)
            }
        }
        Divider()
        ReplaceMediaMenuItems(clip: clip, project: access.binding, analysis: analysis, controller: replacement, packageURL: packageURL)
    }

    @ViewBuilder
    private func sceneMenu(_ entry: BrowserEntry, assetID: UUID, scenes: [SceneRange]) -> some View {
        Divider()
        Button("Split Scenes…") {
            splitter?.show(SceneSplitter.Focus(assetID: assetID, start: entry.start, end: CMTimeAdd(entry.start, entry.duration)))
        }
        if case .scene(_, let sceneID) = entry.id {
            Button("Merge with Previous Scene") { mergeScenes([sceneID], assetID: assetID, scenes: scenes) }
                .disabled(cutsToRemove([sceneID], in: scenes).isEmpty)
        }
    }

    // MARK: - Editing

    private func addToTimeline(_ pieces: [MediaPiece]) {
        guard let result = project.addPieces(pieces, intoTimeline: activeTimelineID, mutingSound: mutesAddedSound),
              let clipID = result.clipIDs.first else { return }
        selection = TimelineSelection(timelineID: activeTimelineID, layerID: result.layerID, timelineClipID: clipID)
    }

    /// The cuts whose removal joins the picked scenes: each picked scene's
    /// start, except where it begins the run (a single scene merges back into
    /// the one before it).
    private func cutsToRemove(_ sceneIDs: Set<String>, in all: [SceneRange]) -> [SceneCut] {
        let single = sceneIDs.count == 1
        var cuts: [SceneCut] = []
        for (index, scene) in all.enumerated() where sceneIDs.contains(scene.id) && index > 0 {
            if single || sceneIDs.contains(all[index - 1].id) {
                cuts.append(SceneCut(time: scene.start, origin: scene.origin))
            }
        }
        return cuts
    }

    private func mergeScenes(_ sceneIDs: Set<String>, assetID: UUID, scenes: [SceneRange]) {
        let cuts = cutsToRemove(sceneIDs, in: scenes)
        project.editScenesFollowingClips(ofAsset: assetID, track: analysis.tracks[assetID]) { edits in
            for cut in cuts { edits.removeCut(cut) }
        }
        picked.clear()
    }

    /// What the scene splitter shows for these picks: the stretch from the
    /// first to the end of the last of them that belong to the first one's
    /// video. Nil when that isn't a video.
    private func splitterFocus(for ids: [BrowserItemID], snapshot: Snapshot) -> SceneSplitter.Focus? {
        guard let first = ids.first.flatMap({ snapshot.byID[$0] }), first.clip.kind == .video else { return nil }
        let entries = ids.compactMap { snapshot.byID[$0] }.filter { $0.clip.id == first.clip.id }
        let start = entries.map(\.start).reduce(first.start, CMTimeMinimum)
        let end = entries.map { CMTimeAdd($0.start, $0.duration) }.reduce(CMTimeAdd(first.start, first.duration), CMTimeMaximum)
        return SceneSplitter.Focus(assetID: first.clip.id, start: start, end: end)
    }

    // MARK: - Status

    /// Says what the file the asset uses now can't play of the original's
    /// time, when it can't.
    static func coverageNote(_ coverage: SceneCoverage?, replaced: Bool) -> String? {
        guard let coverage else { return nil }
        if coverage.hasNoOverlap {
            return replaced ? "The replacement doesn't overlap the original's time, so there are no scenes." : "The file has no footage, so there are no scenes."
        }
        guard !coverage.uncovered.isEmpty else { return nil }
        let spans = coverage.uncovered.map { "\(Self.clock($0.start.seconds))–\(Self.clock($0.end.seconds))" }
        return "\(replaced ? "The replacement has" : "The file has") no footage for \(spans.joined(separator: ", "))."
    }

    private static func clock(_ seconds: Double) -> String {
        String(format: "%d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    /// "120 BPM", or "92–140 BPM" when the tempo changes noticeably.
    static func tempoText(_ beats: BeatTrack) -> String {
        if let range = beats.tempoRange, range.upperBound / range.lowerBound > 1.04 {
            return "\(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded())) BPM"
        }
        return "\(Int(beats.beatsPerMinute.rounded())) BPM"
    }
}
