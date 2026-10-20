import AppKit
import CoreMedia
import SwiftUI

/// A lasso being dragged across the tracks, in window coordinates (the
/// layers' frames are recorded in those, see `TimelineGeometryStore`).
struct LassoDrag: Equatable {
    var start: CGPoint
    var current: CGPoint
    /// Clips already picked when it began, kept when Shift was held.
    var kept: Set<UUID>

    var rect: CGRect {
        CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(start.x - current.x), height: abs(start.y - current.y)
        )
    }

    /// Less than a few points of travel is a click.
    var isClick: Bool { rect.width < 4 && rect.height < 4 }
}

/// Mouse presses and drags in the empty part of the tracks, which no view
/// of the tracks takes, as window coordinates. It only watches: clicks go on
/// to the views around it. Whether a press begins a lasso is for
/// `onDown` to say.
struct LassoMonitor: NSViewRepresentable {
    /// A press at a point; true to follow the drag until the button comes up.
    let onDown: (CGPoint, NSEvent.ModifierFlags) -> Bool
    let onDrag: (CGPoint) -> Void
    let onUp: (CGPoint) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onDown = onDown
        view.onDrag = onDrag
        view.onUp = onUp
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onDown = onDown
        view.onDrag = onDrag
        view.onUp = onUp
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onDown: ((CGPoint, NSEvent.ModifierFlags) -> Bool)?
        var onDrag: ((CGPoint) -> Void)?
        var onUp: ((CGPoint) -> Void)?
        private var monitor: Any?
        private var following = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, let height = window.contentView?.bounds.height else { return }
            // Window coordinates, top left origin, as SwiftUI's global space.
            let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            switch event.type {
            case .leftMouseDown:
                let local = convert(event.locationInWindow, from: nil)
                following = bounds.contains(local)
                    && onDown?(point, event.modifierFlags.intersection(.deviceIndependentFlagsMask)) == true
            case .leftMouseDragged:
                if following { onDrag?(point) }
            case .leftMouseUp:
                if following { onUp?(point) }
                following = false
            default:
                break
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            following = false
        }

        isolated deinit { stopMonitoring() }
    }
}

// Picking clips with a lasso, deselecting, and what is done with several
// clips at once (see docs/timeline.md, "Selecting several clips").
extension TimelineView {
    /// What the lasso is drawn as, over the tracks.
    var lassoOverlay: some View {
        GeometryReader { proxy in
            if let lasso, !lasso.isClick {
                let origin = proxy.frame(in: .global).origin
                let rect = lasso.rect
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Design.accent.opacity(0.12))
                    .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Design.accent.opacity(0.9), lineWidth: 1) }
                    .frame(width: rect.width, height: rect.height)
                    .opacity(lassoFading ? 0 : 1)
                    .offset(x: rect.minX - origin.x, y: rect.minY - origin.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where a clip is drawn, in window coordinates, clipped to its area's
    /// visible part and the tracks beside the layer names.
    private func frame(of clip: TimelineClip, on layer: TimelineLayer, pixelsPerSecond: CGFloat) -> CGRect? {
        guard let row = geometryStore.layerRows[layer.id], let area = geometryStore.areas[layer.kind] else { return nil }
        let x0 = row.minX + CGFloat(clip.startOffset.seconds) * pixelsPerSecond
        let x1 = row.minX + CGFloat(clip.endOffset.seconds) * pixelsPerSecond
        let tracks = CGRect(x: geometryStore.namesColumn.maxX, y: area.minY, width: max(0, area.maxX - geometryStore.namesColumn.maxX), height: area.height)
        return CGRect(x: x0, y: row.minY, width: max(2, x1 - x0), height: row.height).intersection(tracks)
    }

    /// Whether a press at a window point is in the empty part of the
    /// tracks: on a layer's row between its clips, or in an area's space
    /// under its layers. Not on a clip, a layer name, a lane under a layer
    /// or anything outside the areas.
    private func isEmptyTrackSpace(_ point: CGPoint, pixelsPerSecond: CGFloat) -> Bool {
        guard tool == .arrow, point.x >= geometryStore.namesColumn.maxX else { return false }
        for kind in LayerKind.allCases {
            guard let area = geometryStore.areas[kind], area.contains(point) else { continue }
            let layers = timeline.layers.filter { $0.kind == kind }
            var lowest = area.minY
            for layer in layers {
                guard let row = geometryStore.layerRows[layer.id] else { continue }
                lowest = max(lowest, row.maxY)
                if row.contains(point) {
                    return !layer.clips.contains { frame(of: $0, on: layer, pixelsPerSecond: pixelsPerSecond)?.contains(point) == true }
                }
            }
            // Under the last layer, which may be scrolled out of sight.
            return point.y > lowest
        }
        return false
    }

    /// The clips a lasso covers, with their layers.
    private func lassoHits(_ rect: CGRect, pixelsPerSecond: CGFloat) -> [(layerID: UUID, clip: TimelineClip)] {
        timeline.layers.flatMap { layer in
            layer.clips.compactMap { clip in
                frame(of: clip, on: layer, pixelsPerSecond: pixelsPerSecond).map { $0.intersects(rect) } == true ? (layer.id, clip) : nil
            }
        }
    }

    /// Watches for a press in empty track space, which begins a lasso, and
    /// follows it.
    func lassoMonitor(pixelsPerSecond: CGFloat) -> LassoMonitor {
        LassoMonitor(
            onDown: { point, flags in
                guard isEmptyTrackSpace(point, pixelsPerSecond: pixelsPerSecond) else { return false }
                lassoFading = false
                lasso = LassoDrag(start: point, current: point, kept: flags.contains(.shift) ? groupSelectionIncludingClip : [])
                return true
            },
            onDrag: { point in
                guard var drag = lasso else { return }
                drag.current = point
                lasso = drag
                if !drag.isClick {
                    groupSelection = drag.kept.union(lassoHits(drag.rect, pixelsPerSecond: pixelsPerSecond).map(\.clip.id))
                }
            },
            onUp: { point in
                guard var drag = lasso else { return }
                drag.current = point
                if drag.isClick {
                    lasso = nil
                    clearSelection()
                    return
                }
                // The rectangle fades rather than vanishing.
                lasso = drag
                fadeLasso()
                let hits = lassoHits(drag.rect, pixelsPerSecond: pixelsPerSecond)
                finishLasso(Set(hits.map(\.clip.id)).union(drag.kept), single: hits.count == 1 && drag.kept.isEmpty ? hits[0] : nil)
            }
        )
    }

    /// Lets the lasso go: its rectangle fades, then it is gone.
    private func fadeLasso() {
        guard let released = lasso else { return }
        withAnimation(Design.Motion.respecting(Design.Motion.fade)) { lassoFading = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if lasso == released {
                lasso = nil
                lassoFading = false
            }
        }
    }

    /// The clips picked with a lasso, and the clip selected on its own if
    /// there is one, for a lasso that adds to them.
    private var groupSelectionIncludingClip: Set<UUID> {
        var ids = groupSelection
        if let selection, selection.timelineID == timelineID, selection.transitionEdge == nil { ids.insert(selection.timelineClipID) }
        return ids
    }

    /// A lasso ended on `ids`: none leaves nothing selected, one is
    /// selected as a clip is, more are picked together.
    private func finishLasso(_ ids: Set<UUID>, single: (layerID: UUID, clip: TimelineClip)?) {
        if let single {
            groupSelection = []
            selectedLayerID = nil
            selectedSectionID = nil
            onSelectClip(single.layerID, single.clip)
        } else if ids.count < 2 {
            clearSelection()
        } else {
            pickTogether(ids)
        }
    }

    /// Selects `ids` together: no one clip is selected for the panels.
    func pickTogether(_ ids: Set<UUID>) {
        groupSelection = ids
        selectedLayerID = nil
        selectedSectionID = nil
        onSelectLayer()
    }

    /// Adds a clip to the clips picked together, or takes it out; a clip
    /// selected on its own joins them. The way to pick several clips
    /// without a lasso (VoiceOver's "Add to selection").
    func toggleInGroup(_ id: UUID) {
        var ids = groupSelectionIncludingClip
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        if ids.isEmpty { clearSelection() } else { pickTogether(ids) }
    }

    /// Selects every clip of the timeline together (⌘A).
    func selectAllClips() -> Bool {
        let ids = Set(timeline.layers.flatMap(\.clips).map(\.id))
        guard !ids.isEmpty else { return false }
        pickTogether(ids)
        return true
    }

    /// Nothing selected: no clip, no clips picked together, no layer, no
    /// section. A click in empty track space does this, and Escape.
    func clearSelection() {
        groupSelection = []
        selectedLayerID = nil
        selectedSectionID = nil
        onSelectLayer()
    }

    /// Whether anything is selected in this timeline for `clearSelection`
    /// to let go of.
    var hasAnythingSelected: Bool {
        !groupSelection.isEmpty || selectedLayerID != nil || selectedSectionID != nil || selection?.timelineID == timelineID
    }

    // MARK: Several clips at once

    /// Cut, copy, duplicate and the rest, for the clips picked together.
    func groupClipboard(_ command: ClipboardCommand) {
        let ids = groupSelection
        switch command {
        case .copy, .cut:
            guard let group = readProject().clipGroup(ids, in: timelineID) else { return }
            EditorClipboard.shared.copy(group: group)
            if command == .cut { deleteGroup() }
        case .paste:
            pasteGroup()
        case .duplicate:
            var copies: [(layerID: UUID, clipID: UUID)] = []
            onEditProject { copies = $0.duplicateClips(ids, in: timelineID) }
            if !copies.isEmpty { groupSelection = Set(copies.map(\.clipID)) }
        case .nest:
            nest(ids)
        }
    }

    /// Pastes the clips copied together at the playhead, picked together
    /// again, and leaves the playhead at their end.
    func pasteGroup() {
        guard let group = EditorClipboard.shared.group else { return }
        var placed: [(layerID: UUID, clipID: UUID)] = []
        onEditProject { placed = $0.paste(group, in: timelineID, at: playheadTime) }
        guard !placed.isEmpty else { return NSSound.beep() }
        pickTogether(Set(placed.map(\.clipID)))
        parkPlayhead(at: CMTimeAdd(playheadTime, CMTimeSubtract(group.end, group.start)))
    }

    func deleteGroup() {
        let ids = groupSelection
        onEditProject { $0.deleteClips(ids, in: timelineID) }
        groupSelection = []
    }

    /// Puts the clips in a timeline of their own, which takes their place
    /// as one clip, selected.
    func nest(_ ids: Set<UUID>) {
        var nested: (timelineID: UUID, layerID: UUID, clipID: UUID)?
        onEditProject { project in
            nested = project.nestClips(ids, in: timelineID, named: project.newNestedTimelineName())
        }
        guard let nested else { return NSSound.beep() }
        groupSelection = []
        if let clip = readProject().clipAndLayer(nested.clipID, in: timelineID)?.clip {
            selectedLayerID = nil
            selectedSectionID = nil
            onSelectClip(nested.layerID, clip)
        }
    }
}

extension EditingProject {
    /// "Nested 1", "Nested 2" and so on: the first not in use.
    func newNestedTimelineName() -> String {
        let names = Set(timelines.map(\.name))
        var number = 1
        while names.contains("Nested \(number)") { number += 1 }
        return "Nested \(number)"
    }
}
