import AppKit
import CoreMedia
import SwiftUI

/// A timeline's strip as the skimmer's item, apart from the Clips tab's.
struct TimelineStripID: Hashable {
    let timelineID: UUID
}

/// The Timelines tab laid out as the Clips tab is: each timeline a
/// filmstrip of its own frames (`TimelinePreview`), in the tree's order
/// read top to bottom, with its name, settings and duration. Skimming one
/// shows it in the viewer, and selecting works as for clips: a click
/// selects, Command- and Shift-click add, dragging across a strip picks a
/// range, and a double-click opens the timeline. The parts other
/// timelines embed are underlined in red. See docs/browser.md, "Tabs".
struct TimelineFilmstrips: View {
    let project: EditingProject
    let activeTimelineID: UUID
    /// The timelines in the tab's order.
    let order: [UUID]
    @Binding var picked: BrowserSelection<UUID>
    @Binding var renamingID: UUID?
    let onOpen: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    /// The menu of a timeline, shared with the list.
    let menu: (UUID) -> AnyView

    @Environment(BrowserSkim.self) private var skim: BrowserSkim?
    @AppStorage(Preferences.browserSkimming) private var skimming = true
    @AppStorage(Preferences.thumbnailInterval) private var interval = ThumbnailInterval.all
    @AppStorage(Preferences.thumbnailSize) private var thumbnailSize = ThumbnailSize.medium
    @FocusState private var focused: Bool
    @State private var width: CGFloat = 300
    /// A range being dragged out: its timeline, and the end that stays.
    @State private var rangeDrag: (timelineID: UUID, anchor: Double)?
    /// The timeline the keyboard last moved to or clicked.
    @State private var cursor: UUID?

    private static let padding: CGFloat = 10
    private static let handleReach: CGFloat = 6

    /// One line of the tab: a timeline's title, or a row of its strip.
    /// Each has an ID of its own, so the lazy stack keeps them apart.
    private enum Line: Identifiable {
        case title(Timeline)
        case strip(Timeline, FilmstripLayout, row: Int, used: [(start: Double, end: Double)])

        var id: String {
            switch self {
            case .title(let timeline): "title-\(timeline.id)"
            case .strip(let timeline, _, let row, _): "strip-\(timeline.id)-\(row)"
            }
        }
    }

    private func lines() -> [Line] {
        order.compactMap { project.timeline(id: $0) }.flatMap { timeline -> [Line] in
            let layout = layout(of: timeline)
            let used = usedSeconds(of: timeline)
            return [.title(timeline)] + (0..<layout.rowCount).map { .strip(timeline, layout, row: $0, used: used) }
        }
    }

    var body: some View {
        let previews = TimelinePreviews.previews(of: order, in: project)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines()) { line in
                    switch line {
                    case .title(let timeline):
                        title(timeline)
                            .padding(.top, Design.Space.step)
                            .padding(.bottom, Design.Space.tight)
                    case .strip(let timeline, let layout, let row, let used):
                        strip(timeline, preview: previews[timeline.id], layout: layout, row: row, used: used)
                            .padding(.bottom, FilmstripLayout.rowSpacing)
                    }
                }
            }
            .padding(.horizontal, Self.padding)
            .padding(.bottom, Design.Space.group)
            // Clicking off the timelines, below them included, picks nothing.
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture {
                focused = true
                picked.clear()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape, "i", "o"]) { press in
            handleKey(press, previews: previews) ? .handled : .ignored
        }
        // As in the Clips tab: leaving the browser, or its keyboard, gives
        // the viewer back to the timeline being edited.
        .onHover { inside in
            if !inside, skimming { skim?.end() }
        }
        .onChange(of: focused) { _, focused in
            if !focused { skim?.end() }
        }
        .sunken(.sunken)
    }

    // MARK: - Layout

    private func cellSize(of timeline: Timeline) -> CGSize {
        let aspect = timeline.frameSize.height > 0 ? timeline.frameSize.width / timeline.frameSize.height : 16.0 / 9
        return CGSize(width: (thumbnailSize.height * aspect).rounded(), height: thumbnailSize.height)
    }

    private func layout(of timeline: Timeline) -> FilmstripLayout {
        FilmstripLayout(
            duration: timeline.duration.seconds, interval: interval, cellSize: cellSize(of: timeline),
            width: width - Self.padding * 2
        )
    }

    /// What other timelines embed of `timeline`, in seconds into it, joined
    /// where they overlap.
    private func usedSeconds(of timeline: Timeline) -> [(start: Double, end: Double)] {
        let sorted = project.usedRanges(ofTimeline: timeline.id)
            .map { (max(0, $0.start.seconds), min(timeline.duration.seconds, $0.end.seconds)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var joined: [(start: Double, end: Double)] = []
        for (a, b) in sorted {
            if let last = joined.last, a <= last.end + 1e-6 {
                joined[joined.count - 1].end = max(last.end, b)
            } else {
                joined.append((a, b))
            }
        }
        return joined
    }

    // MARK: - Titles

    private func title(_ timeline: Timeline) -> some View {
        let isSelected = picked.contains(timeline.id)
        let isActive = timeline.id == activeTimelineID
        return HStack(alignment: .firstTextBaseline, spacing: Design.Space.tight) {
            Image(systemName: "rectangle.stack")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.ClipTone.nested.color)
            InlineNameField(
                name: timeline.name,
                isEditing: Binding(
                    get: { renamingID == timeline.id },
                    set: { editing in renamingID = editing ? timeline.id : nil }
                ),
                isSelected: isSelected && picked.items.count == 1 && picked.range == nil,
                onCommit: { onRename(timeline.id, $0) }
            )
            .font(Design.Typeface.label)
            .foregroundStyle(isSelected ? Design.accent : Design.textPrimary)
            if isActive {
                Text("Open")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textSecondary)
            }
            Text(timeline.timebaseSummary)
                .font(Design.Typeface.numericMicro)
                .foregroundStyle(Design.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .onMouseDown { clicks in
            focused = true
            cursor = timeline.id
            let keys = NSApp.currentEvent?.modifierFlags ?? []
            if keys.contains(.command) {
                picked.commandClick(timeline.id)
            } else if keys.contains(.shift) {
                picked.shiftClick(timeline.id, in: order)
            } else {
                picked.click(timeline.id)
                if clicks == 2 { onOpen(timeline.id) }
            }
        }
        // Dragged by its name, as from the list: onto the timeline, or onto
        // an effect that takes an input.
        .draggable(TimelinesList.dragPayload(from: timeline.id, picked: picked, order: order, in: project))
        .contextMenu { menu(timeline.id) }
        .help(isActive ? "The timeline open in the editor" : "Double-click to open in the editor")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName(timeline))
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Opens the timeline in the editor")
        .accessibilityAction { onOpen(timeline.id) }
        .accessibilityAction(named: isSelected ? "Deselect" : "Add to selection") { picked.commandClick(timeline.id) }
        .accessibilityAction(named: "Skim Forward") { skimStep(timeline, seconds: 1) }
        .accessibilityAction(named: "Skim Back") { skimStep(timeline, seconds: -1) }
        .accessibilityAction(named: "Set Range Start") { setRangeEnd(.start, of: timeline) }
        .accessibilityAction(named: "Set Range End") { setRangeEnd(.end, of: timeline) }
        .accessibilityAction(named: "Rename timeline") { renamingID = timeline.id }
    }

    private func accessibilityName(_ timeline: Timeline) -> String {
        var parts = [timeline.name, timecode(timeline.duration.seconds, timeline), timeline.timebaseSummary]
        if timeline.id == activeTimelineID { parts.append("open") }
        if !project.usedRanges(ofTimeline: timeline.id).isEmpty { parts.append("embedded in a timeline") }
        if let range = picked.range, range.item == timeline.id {
            parts.append("range \(timecode(range.start, timeline)) to \(timecode(range.end, timeline))")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Strips

    private func strip(
        _ timeline: Timeline, preview: TimelinePreview?, layout: FilmstripLayout, row: Int, used: [(start: Double, end: Double)]
    ) -> some View {
        let rowTop = CGFloat(row) * layout.rowPitch
        let range = picked.range?.item == timeline.id ? picked.range : nil
        return FilmstripStrip(
            layout: layout, row: row,
            isSelected: picked.contains(timeline.id) && range == nil,
            range: range.map { ($0.start, $0.end) },
            used: used,
            durationText: row == 0 ? timecode(timeline.duration.seconds, timeline) : nil,
            picture: { cell in
                TimelineFrame(preview: preview, time: CMTime(seconds: cell.start, preferredTimescale: 600), height: layout.cellSize.height)
            },
            top: { EmptyView() }
        )
        .overlay(alignment: .topLeading) {
            if let skim {
                SkimLine(skim: skim, item: TimelineStripID(timelineID: timeline.id), layout: layout, row: row)
            }
        }
        .overlay {
            FilmstripMouseView(
                rowOffset: rowTop,
                onDown: { point, flags in pressBegan(timeline, layout: layout, at: point, flags: flags) },
                onPress: { press in pressed(press, timeline: timeline, preview: preview, layout: layout) },
                dragText: { point in dragText(timeline, preview: preview, layout: layout, at: point) },
                isOnHandle: { point in handle(of: timeline, layout: layout, at: point) != nil },
                onHover: { point in
                    if skimming, let point, let preview { skim(timeline, preview: preview, at: layout.seconds(at: point)) }
                }
            )
        }
        .contextMenu { menu(timeline.id) }
        // The title line is the timeline for VoiceOver; the pictures add nothing.
        .accessibilityHidden(true)
    }

    /// What a drag from `point` carries, as in the Clips tab: the range when
    /// it starts inside the timeline's range, otherwise the timeline, or
    /// every selected timeline when it is one of them. The picture that
    /// follows the pointer is the first one's frame there, once made.
    private func dragText(
        _ timeline: Timeline, preview: TimelinePreview?, layout: FilmstripLayout, at point: CGPoint
    ) -> (text: String, image: NSImage)? {
        // Dragged to the timeline, the viewer goes back to showing it.
        skim?.end()
        let payload: MediaDragPayload
        var start = CMTime.zero
        if let range = picked.range, range.item == timeline.id, range.contains(layout.seconds(at: point)) {
            start = CMTime(seconds: range.start, preferredTimescale: 600)
            payload = MediaDragPayload.beginDrag([.timeline(timeline.id, from: start, to: CMTime(seconds: range.end, preferredTimescale: 600))])
        } else {
            if !picked.contains(timeline.id) { picked.click(timeline.id) }
            payload = TimelinesList.dragPayload(from: timeline.id, picked: picked, order: order, in: project)
        }
        guard !payload.pieces.isEmpty else { return nil }
        let size = layout.cellSize
        let picture = preview?.cachedImage(at: start, height: size.height)
            ?? NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: nil)
            ?? NSImage(size: size)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            picture.draw(in: rect)
            return true
        }
        return (payload.text, image)
    }

    /// The end of the range whose handle is at `point`: the far end, which
    /// stays put while the handle is dragged.
    private func handle(of timeline: Timeline, layout: FilmstripLayout, at point: CGPoint) -> Double? {
        guard let range = picked.range, range.item == timeline.id else { return nil }
        let start = layout.position(atSeconds: range.start), end = layout.position(atSeconds: range.end)
        let row = Int(point.y / layout.rowPitch)
        if row == start.row, abs(point.x - start.x) <= Self.handleReach { return range.end }
        if row == end.row, abs(point.x - end.x) <= Self.handleReach { return range.start }
        return nil
    }

    /// Whether a press tracks a range once it moves: on a handle, or off
    /// what is selected (with Option, anywhere), as in the Clips tab.
    private func pressBegan(_ timeline: Timeline, layout: FilmstripLayout, at point: CGPoint, flags: NSEvent.ModifierFlags) -> Bool {
        focused = true
        if let fixed = handle(of: timeline, layout: layout, at: point) {
            rangeDrag = (timeline.id, fixed)
            return true
        }
        guard flags.isDisjoint(with: [.command, .shift]) else { return false }
        let seconds = layout.seconds(at: point)
        guard flags.contains(.option) || !picked.pressDrags(timeline.id, at: seconds) else { return false }
        rangeDrag = (timeline.id, snapped(seconds, timeline))
        return true
    }

    private func pressed(_ press: FilmstripPress, timeline: Timeline, preview: TimelinePreview?, layout: FilmstripLayout) {
        switch press {
        case .click(let point, let flags):
            rangeDrag = nil
            cursor = timeline.id
            if flags.contains(.command) {
                picked.commandClick(timeline.id)
            } else if flags.contains(.shift) {
                picked.shiftClick(timeline.id, in: order)
            } else if handle(of: timeline, layout: layout, at: point) == nil {
                picked.click(timeline.id, at: layout.seconds(at: point))
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                    onOpen(timeline.id)
                } else if !skimming, let preview {
                    skim(timeline, preview: preview, at: layout.seconds(at: point))
                }
            }
        case .track(let point):
            guard let rangeDrag, rangeDrag.timelineID == timeline.id else { return }
            let duration = timeline.duration.seconds
            picked.setRange(of: timeline.id, from: rangeDrag.anchor, to: snapped(layout.seconds(at: point), timeline), duration: duration)
            if let preview { skim(timeline, preview: preview, at: layout.seconds(at: point)) }
        case .endTrack:
            rangeDrag = nil
            // A drag too short to span a frame picks the whole timeline.
            if let range = picked.range, range.item == timeline.id, range.end - range.start < 1 / max(timeline.frameRate, 1) {
                picked.click(timeline.id)
            }
        }
    }

    // MARK: - Skimming

    private func skim(_ timeline: Timeline, preview: TimelinePreview, at seconds: Double) {
        let target = BrowserSkim.Target(
            item: TimelineStripID(timelineID: timeline.id),
            source: .timeline(preview, name: timeline.name, frameRate: timeline.frameRate),
            start: .zero, duration: timeline.duration
        )
        skim?.skim(target, at: snapped(seconds, timeline))
    }

    /// Where `timeline` is skimmed, in seconds into it; nil when it isn't.
    private func skimmed(_ timeline: Timeline) -> Double? {
        guard let skim, skim.target?.item == AnyHashable(TimelineStripID(timelineID: timeline.id)) else { return nil }
        return skim.seconds
    }

    private func skimStep(_ timeline: Timeline, seconds: Double) {
        // Asked for with the rest, which a lone request would let go.
        guard let preview = TimelinePreviews.previews(of: order, in: project)[timeline.id] else { return }
        skim(timeline, preview: preview, at: (skimmed(timeline) ?? 0) + seconds)
    }

    private enum RangeEnd { case start, end }

    /// Sets the start or end of the range where `timeline` is skimmed,
    /// keeping the other end (or the timeline's own); false when it isn't
    /// skimmed.
    @discardableResult
    private func setRangeEnd(_ end: RangeEnd, of timeline: Timeline) -> Bool {
        guard let at = skimmed(timeline) else { return false }
        let duration = timeline.duration.seconds
        let current = picked.range?.item == timeline.id ? picked.range : nil
        switch end {
        case .start: picked.setRange(of: timeline.id, from: at, to: max(current?.end ?? duration, at), duration: duration)
        case .end: picked.setRange(of: timeline.id, from: min(current?.start ?? 0, at), to: at, duration: duration)
        }
        cursor = timeline.id
        return true
    }

    // MARK: - Keys

    /// As in the Clips tab: Up and Down move the selection (Shift extends
    /// it), Option-Left and Option-Right skim the selected timeline a frame
    /// at a time (ten with Shift), I and O set its range's ends where it is
    /// skimmed, and Escape stops skimming. Return renames, as in the list.
    private func handleKey(_ press: KeyPress, previews: [UUID: TimelinePreview]) -> Bool {
        guard renamingID == nil else { return false }
        let keyboardID = cursor.flatMap { picked.contains($0) ? $0 : nil } ?? picked.ordered(in: order).first
        let skimmedID = (skim?.target?.item.base as? TimelineStripID)?.timelineID
        switch press.key {
        case .leftArrow, .rightArrow:
            guard press.modifiers.contains(.option), let id = keyboardID,
                  let timeline = project.timeline(id: id), let preview = previews[id]
            else { return false }
            let frames = (press.modifiers.contains(.shift) ? 10 : 1) * (press.key == .leftArrow ? -1 : 1)
            if skimmed(timeline) == nil {
                skim(timeline, preview: preview, at: picked.range?.item == id ? picked.range?.start ?? 0 : 0)
            }
            skim?.step(frames: frames)
            return true
        case "i", "o":
            guard press.modifiers.isEmpty, let id = skimmedID ?? keyboardID, let timeline = project.timeline(id: id) else { return false }
            return setRangeEnd(press.key == "i" ? .start : .end, of: timeline)
        case .escape:
            guard skim?.isActive == true else { return false }
            skim?.end()
            return true
        case .return:
            guard picked.items.count == 1, let id = picked.items.first else { return false }
            renamingID = id
            return true
        default:
            break
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
        if press.modifiers.contains(.shift) {
            picked.shiftClick(order[next], in: order)
        } else {
            picked.click(order[next])
        }
        return true
    }

    // MARK: - Times

    /// `seconds` on the nearest frame of the timeline, within it.
    private func snapped(_ seconds: Double, _ timeline: Timeline) -> Double {
        let duration = timeline.duration.seconds
        guard timeline.frameRate > 0 else { return seconds.clamped(between: 0, and: duration) }
        return ((seconds * timeline.frameRate).rounded() / timeline.frameRate).clamped(between: 0, and: duration)
    }

    private func timecode(_ seconds: Double, _ timeline: Timeline) -> String {
        CMTime(seconds: seconds, preferredTimescale: 600).compactTimecode(frameRate: timeline.frameRate)
    }
}

/// A timeline's frame at `time`, fitted into its cell. Unlike a file's,
/// the cell keeps its last picture while a new one is made, so an edit to
/// the timeline doesn't blink its strip to black.
struct TimelineFrame: View {
    let preview: TimelinePreview?
    let time: CMTime
    let height: CGFloat
    @State private var loaded: NSImage?

    private var key: String {
        "\(preview.map { ObjectIdentifier($0).hashValue } ?? 0)|\(time.value)/\(time.timescale)|\(height)"
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.black)
            if let loaded {
                Image(nsImage: loaded)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: key) {
            guard let preview else { return }
            if let cached = preview.cachedImage(at: time, height: height) {
                loaded = cached
                return
            }
            guard let image = await preview.image(at: time, height: height) else { return }
            loaded = image
        }
    }
}
