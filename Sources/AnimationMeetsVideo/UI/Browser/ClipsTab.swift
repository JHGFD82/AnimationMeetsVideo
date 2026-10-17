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

/// The browser's Clips tab: every asset as a filmstrip, and a video's
/// scenes as clips of their own once it is expanded. See docs/browser.md.
struct ClipsTab: View {
    @Binding var project: EditingProject
    let activeTimelineID: UUID
    @Binding var selection: TimelineSelection?
    let analysis: AssetAnalysis
    let replacement: MediaReplacementController
    let packageURL: URL?

    @AppStorage("browserThumbnailInterval") private var interval = ThumbnailInterval.all
    @AppStorage("browserThumbnailSize") private var thumbnailSize = ThumbnailSize.medium
    @State private var picked = BrowserSelection<BrowserItemID>()
    @State private var expandedAssets: Set<UUID> = []
    @State private var width: CGFloat = 240
    @State private var sensitivityTarget: SensitivityTarget?
    @State private var previewTarget: ScenePreviewTarget?
    /// The end of the range being dragged out, and its fixed end.
    @State private var rangeDrag: (item: BrowserItemID, anchor: Double)?
    /// Where the arrow keys move from: the last clip clicked or stepped to.
    @State private var cursor: BrowserItemID?
    @FocusState private var focused: Bool

    private static let padding: CGFloat = 10
    /// How close to a range's end a press grabs its handle.
    private static let handleReach: CGFloat = 6

    // MARK: - Entries

    private var entries: [BrowserEntry] {
        var entries: [BrowserEntry] = []
        for clip in project.clips {
            entries.append(BrowserEntry(id: .asset(clip.id), clip: clip, start: .zero, duration: clip.duration))
            guard clip.kind == .video, expandedAssets.contains(clip.id) else { continue }
            for (index, scene) in scenes(of: clip).enumerated() {
                entries.append(BrowserEntry(
                    id: .scene(asset: clip.id, scene: scene.id), clip: clip, start: scene.start, duration: scene.duration,
                    sceneNumber: index + 1, setByHand: scene.origin == .manual
                ))
            }
        }
        return entries
    }

    private func scenes(of clip: MediaClip) -> [SceneRange] {
        project.scenes(ofAsset: clip.id, track: analysis.tracks[clip.id])
    }

    private var cellSize: CGSize {
        CGSize(width: (thumbnailSize.height * 16 / 9).rounded(), height: thumbnailSize.height)
    }

    private func layout(of entry: BrowserEntry) -> FilmstripLayout {
        FilmstripLayout(duration: entry.seconds, interval: interval, cellSize: cellSize, width: width - Self.padding * 2)
    }

    /// An expanded video shows its scenes' strips, not its own.
    private func showsStrip(_ entry: BrowserEntry) -> Bool {
        if case .asset(let id) = entry.id { return !expandedAssets.contains(id) }
        return true
    }

    // MARK: - Body

    var body: some View {
        let entries = entries
        let order = entries.map(\.id)
        // What the project's timelines use of each asset, for the red line.
        let used = Dictionary(project.clips.map { ($0.id, project.usedRanges(ofMedia: $0.id)) }, uniquingKeysWith: { a, _ in a })
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    let layout = layout(of: entry)
                    let usedHere = entry.seconds(within: used[entry.clip.id] ?? [])
                    title(entry, isUsed: !usedHere.isEmpty)
                        .padding(.top, Design.Space.step)
                        .padding(.bottom, Design.Space.tight)
                        .id("\(entry.id)-title")
                    if showsStrip(entry) {
                        ForEach(0..<layout.rowCount, id: \.self) { row in
                            stripRow(entry, layout: layout, row: row, used: usedHere, order: order)
                                .padding(.bottom, FilmstripLayout.rowSpacing)
                        }
                    }
                    if case .asset(let id) = entry.id, expandedAssets.contains(id), let note = coverageNote(for: entry.clip) {
                        Text(note)
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, Self.padding)
            .padding(.bottom, Design.Space.group)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
            handleKey(press, order: order) ? .handled : .ignored
        }
        .onChange(of: order) { _, order in picked.keep(only: order) }
        .sheet(item: $sensitivityTarget) { target in
            SensitivitySheet(project: $project, target: target, track: analysis.tracks[target.assetID])
        }
        .sheet(item: $previewTarget) { target in
            ScenePreviewSheet(project: $project, target: target, track: analysis.tracks[target.assetID])
        }
        .sunken(.sunken)
    }

    // MARK: - Titles

    @ViewBuilder
    private func title(_ entry: BrowserEntry, isUsed: Bool) -> some View {
        let isSelected = picked.contains(entry.id)
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.tight) {
            if case .asset(let id) = entry.id, entry.clip.kind == .video {
                Button {
                    if expandedAssets.contains(id) { expandedAssets.remove(id) } else { expandedAssets.insert(id) }
                } label: {
                    Image(systemName: expandedAssets.contains(id) ? "chevron.down" : "chevron.right")
                        .font(Design.Typeface.micro)
                        .frame(width: 12)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expandedAssets.contains(id) ? "Hide scenes" : "Show scenes")
            }
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
                    assetStatus(entry.clip)
                }
            }
        }
        .padding(.leading, entry.sceneNumber == nil ? 0 : 16)
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            picked.click(entry.id)
            cursor = entry.id
        }
        .contextMenu { menu(for: entry) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName(entry, isUsed: isUsed))
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { picked.click(entry.id) }
        .accessibilityAction(named: "Add to Timeline") { addToTimeline(dragPieces(for: [entry.id])) }
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
        _ entry: BrowserEntry, layout: FilmstripLayout, row: Int, used: [(start: Double, end: Double)], order: [BrowserItemID]
    ) -> some View {
        let rowTop = CGFloat(row) * layout.rowPitch
        let range = picked.range?.item == entry.id ? picked.range : nil
        return FilmstripRow(
            entry: entry, layout: layout, row: row,
            isSelected: picked.contains(entry.id) && range == nil,
            range: range.map { ($0.start, $0.end) },
            used: used,
            durationText: row == 0 ? durationText(entry) : nil
        )
        .overlay {
            FilmstripMouseView(
                rowOffset: rowTop,
                onDown: { point, flags in pressBegan(entry, layout: layout, at: point, flags: flags) },
                onPress: { press in pressed(press, entry: entry, layout: layout, order: order) },
                dragText: { point in dragText(entry, layout: layout, at: point, order: order) }
            )
        }
        .contextMenu { menu(for: entry) }
        // The title line is the clip for VoiceOver; the pictures add nothing.
        .accessibilityHidden(true)
    }

    private func pressBegan(_ entry: BrowserEntry, layout: FilmstripLayout, at point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        focused = true
        let seconds = snapped(layout.seconds(at: point), entry)
        if let range = picked.range, range.item == entry.id {
            let start = layout.position(atSeconds: range.start), end = layout.position(atSeconds: range.end)
            let row = Int(point.y / layout.rowPitch)
            if row == start.row, abs(point.x - start.x) <= Self.handleReach {
                rangeDrag = (entry.id, range.end)
                return true
            }
            if row == end.row, abs(point.x - end.x) <= Self.handleReach {
                rangeDrag = (entry.id, range.start)
                return true
            }
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
            }
        case .track(let point):
            guard let rangeDrag, rangeDrag.item == entry.id else { return }
            picked.setRange(of: entry.id, from: rangeDrag.anchor, to: snapped(layout.seconds(at: point), entry), duration: entry.seconds)
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
    private func dragText(_ entry: BrowserEntry, layout: FilmstripLayout, at point: CGPoint, order: [BrowserItemID]) -> (text: String, label: String)? {
        let pieces: [MediaPiece]
        let label: String
        if let range = picked.range, range.item == entry.id, range.contains(layout.seconds(at: point)) {
            pieces = [entry.piece(from: range.start, to: range.end)]
            label = "\(entry.clip.name) \(timecode(range.end - range.start, entry))"
        } else {
            if !picked.contains(entry.id) { picked.click(entry.id) }
            let ids = picked.dragged(from: entry.id, in: order)
            pieces = dragPieces(for: ids)
            label = ids.count == 1 ? (entry.sceneNumber.map { "Scene \($0)" } ?? entry.clip.name) : "\(ids.count) clips"
        }
        guard !pieces.isEmpty else { return nil }
        return (MediaDragPayload.beginDrag(pieces).text, label)
    }

    /// The pieces for `ids`, in that order. A scene whose whole asset is
    /// also picked is left out, since the asset already carries it.
    private func dragPieces(for ids: [BrowserItemID]) -> [MediaPiece] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wholeAssets = Set(ids.compactMap { id -> UUID? in
            if case .asset(let asset) = id { return asset }
            return nil
        })
        return ids.compactMap { id in
            if case .scene(let asset, _) = id, wholeAssets.contains(asset) { return nil }
            return byID[id]?.piece()
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

    // MARK: - Keys

    /// Up and down move the selection (Shift extends it); Return adds the
    /// selection to the timeline.
    private func handleKey(_ press: KeyPress, order: [BrowserItemID]) -> Bool {
        if press.key == .return {
            let ids = picked.ordered(in: order)
            guard !ids.isEmpty else { return false }
            if let range = picked.range, let entry = entries.first(where: { $0.id == range.item }) {
                addToTimeline([entry.piece(from: range.start, to: range.end)])
            } else {
                addToTimeline(dragPieces(for: ids))
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
    private func menu(for entry: BrowserEntry) -> some View {
        let ids = picked.contains(entry.id) ? picked.ordered(in: entries.map(\.id)) : [entry.id]
        Button(ids.count > 1 ? "Add \(ids.count) Clips to Timeline" : "Add to Timeline") {
            if let range = picked.range, range.item == entry.id {
                addToTimeline([entry.piece(from: range.start, to: range.end)])
            } else {
                addToTimeline(dragPieces(for: ids))
            }
        }
        if ids.count == 1 {
            switch entry.id {
            case .asset:
                assetMenu(entry.clip)
            case .scene(let assetID, _):
                sceneMenu(entry, assetID: assetID)
            }
        } else {
            let sceneIDs = ids.compactMap { id -> String? in
                if case .scene(let asset, let scene) = id, asset == entry.clip.id { return scene }
                return nil
            }
            if sceneIDs.count == ids.count, canMerge(Set(sceneIDs), assetID: entry.clip.id) {
                Divider()
                Button("Merge Selected Scenes") { mergeScenes(Set(sceneIDs), assetID: entry.clip.id) }
            }
        }
    }

    @ViewBuilder
    private func assetMenu(_ clip: MediaClip) -> some View {
        if clip.kind == .video {
            Divider()
            Button("Cut Sensitivity…") {
                sensitivityTarget = SensitivityTarget(assetID: clip.id, scope: .asset)
            }
            .disabled(analysis.tracks[clip.id] == nil)
            Button("Find Scenes Again") {
                analysis.reanalyze(clip, in: project)
            }
            .disabled(analysis.progress[clip.id] != nil)
        }
        if let problem = analysis.persistenceProblem(for: clip.id) {
            Button(problem.kind == .unreadableProject ? "Retry Reading Results" : "Retry Saving Results") {
                Task { await analysis.retryPersistence() }
            }
        }
        if analysis.firstFailure(for: clip.id) != nil {
            Button("Retry Failed Analysis") {
                analysis.retryFailures(for: clip.id, in: project)
            }
            .disabled(analysis.progress[clip.id] != nil)
        }
        Divider()
        ReplaceMediaMenuItems(clip: clip, project: $project, analysis: analysis, controller: replacement, packageURL: packageURL)
    }

    @ViewBuilder
    private func sceneMenu(_ entry: BrowserEntry, assetID: UUID) -> some View {
        if let url = entry.clip.url, let number = entry.sceneNumber {
            Button("Preview…") {
                let scene = SceneRange(start: entry.start, end: CMTimeAdd(entry.start, entry.duration), origin: entry.setByHand ? .manual : .auto)
                previewTarget = ScenePreviewTarget(assetID: assetID, url: url, scene: scene, number: number)
            }
        }
        Divider()
        if analysis.tracks[assetID] != nil {
            Button("Adjust Cut Sensitivity…") {
                sensitivityTarget = SensitivityTarget(assetID: assetID, scope: .span(start: entry.start, end: CMTimeAdd(entry.start, entry.duration)))
            }
        }
        if case .scene(_, let sceneID) = entry.id {
            Button("Merge with Previous Scene") { mergeScenes([sceneID], assetID: assetID) }
                .disabled(!canMerge([sceneID], assetID: assetID))
        }
    }

    // MARK: - Editing

    private func addToTimeline(_ pieces: [MediaPiece]) {
        guard let result = project.addPieces(pieces, intoTimeline: activeTimelineID), let clipID = result.clipIDs.first else { return }
        selection = TimelineSelection(timelineID: activeTimelineID, layerID: result.layerID, timelineClipID: clipID)
    }

    /// The cuts whose removal joins the picked scenes: each picked scene's
    /// start, except where it begins the run (a single scene merges back into
    /// the one before it).
    private func cutsToRemove(_ sceneIDs: Set<String>, assetID: UUID) -> [SceneCut] {
        let all = project.scenes(ofAsset: assetID, track: analysis.tracks[assetID])
        let single = sceneIDs.count == 1
        var cuts: [SceneCut] = []
        for (index, scene) in all.enumerated() where sceneIDs.contains(scene.id) && index > 0 {
            if single || sceneIDs.contains(all[index - 1].id) {
                cuts.append(SceneCut(time: scene.start, origin: scene.origin))
            }
        }
        return cuts
    }

    private func canMerge(_ sceneIDs: Set<String>, assetID: UUID) -> Bool {
        !cutsToRemove(sceneIDs, assetID: assetID).isEmpty
    }

    private func mergeScenes(_ sceneIDs: Set<String>, assetID: UUID) {
        let cuts = cutsToRemove(sceneIDs, assetID: assetID)
        project.editScenes(ofAsset: assetID) { edits in
            for cut in cuts { edits.removeCut(cut) }
        }
        picked.clear()
    }

    // MARK: - Status

    private func coverageNote(for clip: MediaClip) -> String? {
        Self.coverageNote(project.sceneCoverage(ofAsset: clip.id, track: analysis.tracks[clip.id]), replaced: clip.wasReplaced)
    }

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

    @ViewBuilder
    private func assetStatus(_ clip: MediaClip) -> some View {
        if let fraction = analysis.progress[clip.id] {
            HStack(spacing: Design.Space.close) {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(width: 60)
                Text(analysis.stages[clip.id]?.label ?? "Waiting…")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textTertiary)
            }
        } else if replacement.missingMedia.contains(clip.id) {
            Text("File missing")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help("Its clips play as gaps until the file is back. Control-click to replace it.")
        } else if let failure = analysis.firstFailure(for: clip.id) {
            Text(failure.title)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help(failure.detail)
                .accessibilityHint(failure.detail)
        } else if analysis.changedFiles[clip.id] != nil {
            Text("File changed outside the app")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help("Scenes and beats aren't found until the change is checked. Control-click and choose \u{201C}File Changed — Check Sync…\u{201D}.")
                .accessibilityHint("Scenes and beats aren't found until the change is checked.")
        } else if let problem = analysis.persistenceProblem(for: clip.id) {
            Text(problem.title)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help(problem.detail)
                .accessibilityHint(problem.detail)
        } else if let beats = analysis.beats[clip.id], !beats.isEmpty {
            Text(Self.tempoText(beats))
                .font(Design.Typeface.numericMicro)
                .foregroundStyle(Design.textTertiary)
        }
    }
}
