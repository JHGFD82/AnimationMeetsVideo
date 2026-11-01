import SwiftUI

extension EnvironmentValues {
    /// Where each timeline was left in this window (see
    /// `TimelineViewMemory`); the editor surface always sets one.
    @Entry var timelineViewMemory: TimelineViewMemory?
}

// Each timeline comes back zoomed and scrolled as it was left: sideways
// (the viewport) and down each area of layers. See docs/timeline.md,
// "Each timeline keeps its place".
extension TimelineView {
    /// Keeps how `timelineID` is zoomed and scrolled now.
    func parkViewport(of timelineID: UUID) {
        Self.park(timelineID, viewport: viewportModel, scrollers: areaScrollers, in: viewMemory)
    }

    /// Shows `timelineID` zoomed and scrolled as it was left, or fitted
    /// and at the top of each area the first time, unless a clip focused
    /// there (Find All) is to be shown instead; and has saving read it
    /// from here while it is shown.
    func showParkedViewport(of timelineID: UUID) {
        let parked = viewMemory?.parked(timelineID)
        viewportModel.show(parked)
        let focusing = focus.map { $0.timelineID == timelineID && $0.id != shownFocusID } ?? false
        if !focusing {
            let offsets = parked?.areaOffsets.mapValues { CGFloat($0) } ?? [:]
            restoreAreaOffsets(Dictionary(uniqueKeysWithValues: LayerKind.allCases.map { ($0, offsets[$0] ?? 0) }))
        }
        viewMemory?.register("timeline") { [viewportModel, areaScrollers, viewMemory] in
            Self.park(timelineID, viewport: viewportModel, scrollers: areaScrollers, in: viewMemory)
        }
    }

    private static func park(
        _ timelineID: UUID, viewport: TimelineViewportModel, scrollers: [LayerKind: EdgeAutoScroll], in memory: TimelineViewMemory?
    ) {
        guard let memory else { return }
        var offsets: [LayerKind: Double] = [:]
        for kind in LayerKind.allCases {
            // An area still on its way back keeps where it was left.
            if let target = viewport.restoringAreaOffsets[kind] {
                offsets[kind] = Double(target)
            } else if let offset = scrollers[kind]?.offset, offset.isFinite {
                offsets[kind] = Double(max(0, offset))
            }
        }
        let zoom = viewport.zoomedPixelsPerSecond.map(Double.init)
        let scroll = Double(viewport.scrollX)
        memory.update(timelineID) { parked in
            parked.zoomedPixelsPerSecond = zoom
            parked.scrollX = scroll.isFinite ? scroll : 0
            parked.areaOffsets = offsets
        }
    }

    /// Scrolls the areas back to `offsets`, once their layers are laid
    /// out tall enough to: tried each frame for half a second, and given
    /// up when another timeline is shown first.
    func restoreAreaOffsets(_ offsets: [LayerKind: CGFloat]) {
        let shown = viewportModel.shown
        let scrollers = areaScrollers
        viewportModel.restoringAreaOffsets = offsets
        Task { @MainActor [viewportModel] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(16))
                guard viewportModel.shown == shown else { return }
                for (kind, offset) in viewportModel.restoringAreaOffsets where scrollers[kind]?.scroll(toOffset: offset) ?? true {
                    viewportModel.restoringAreaOffsets[kind] = nil
                }
                if viewportModel.restoringAreaOffsets.isEmpty { return }
            }
            if viewportModel.shown == shown { viewportModel.restoringAreaOffsets = [:] }
        }
    }
}
