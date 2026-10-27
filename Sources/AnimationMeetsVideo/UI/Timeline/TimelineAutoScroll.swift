import Observation
import SwiftUI

/// Scrolls the timeline while a drag holds the pointer near the left or
/// right edge of the tracks, so a clip or an edge can be taken past what is
/// in view. The deeper into the edge, the faster it goes.
///
/// The drag keeps measuring its translation in window coordinates, which
/// scrolling doesn't change, so it adds `scrolled` (how far the tracks have
/// moved under it since it began) to find the time under the pointer. As
/// the pointer may hold still while the view scrolls, the drag also hands
/// over a closure to run again after each step.
///
/// Observable only to travel in the environment; nothing it holds redraws a
/// view.
@MainActor
@Observable
final class TimelineAutoScroll {
    /// How close to an edge, in points, the pointer starts scrolling.
    static let edgeWidth: CGFloat = 36
    /// The most it scrolls in one step, at the very edge or past it.
    static let maximumStep: CGFloat = 24

    /// Points scrolled since the drag began; positive toward later times.
    @ObservationIgnored private(set) var scrolled: CGFloat = 0

    /// Scrolls the tracks by a distance and returns how far they really
    /// moved, which is less at either end. Set by the timeline.
    @ObservationIgnored var scrollBy: (CGFloat) -> CGFloat = { _ in 0 }
    /// The visible part of the tracks across, in window coordinates. Set
    /// by the timeline.
    @ObservationIgnored var trackSpan: () -> ClosedRange<CGFloat> = { 0...0 }

    /// Each area's up-and-down scrolling, and the area under a point in
    /// window coordinates. Set by the timeline.
    @ObservationIgnored var areaScrollers: [LayerKind: EdgeAutoScroll] = [:]
    @ObservationIgnored var areaAt: (CGPoint) -> LayerKind? = { _ in nil }

    @ObservationIgnored private var pointerX: CGFloat?
    @ObservationIgnored private var onScroll: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Starts a drag: nothing scrolled yet.
    func begin() {
        end()
        scrolled = 0
    }

    /// The pointer is at `x` in window coordinates. Near an edge this keeps
    /// scrolling, calling `onScroll` after each step, until the pointer
    /// moves away or the drag ends.
    func track(pointerX x: CGFloat, onScroll: @escaping () -> Void) {
        pointerX = x
        self.onScroll = onScroll
        guard task == nil, step(at: x) != 0 else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let x = self.pointerX else { return }
                let wanted = self.step(at: x)
                guard wanted != 0 else { break }
                let moved = self.scrollBy(wanted)
                guard moved != 0 else { break }
                self.scrolled += moved
                self.onScroll?()
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.task = nil
        }
    }

    /// A drag moved with the pointer at `pointer` (window coordinates):
    /// near the top or bottom of the area under it, that area scrolls up or
    /// down (`EdgeAutoScroll`), calling `onScroll` after each step.
    func trackVertically(pointer: CGPoint, onScroll: (() -> Void)? = nil) {
        guard let kind = areaAt(pointer) else { return }
        trackVertically(in: kind, onScroll: onScroll)
    }

    /// The same, for a drag known to be over the area of `kind`.
    func trackVertically(in kind: LayerKind, onScroll: (() -> Void)? = nil) {
        guard let scroller = areaScrollers[kind] else { return }
        scroller.onScroll = onScroll
        scroller.dragMoved()
    }

    /// Ends the drag and stops scrolling.
    func end() {
        task?.cancel()
        task = nil
        pointerX = nil
        onScroll = nil
    }

    /// Lets go of what the timeline set, as it goes away. Its closures hold
    /// the timeline, whose state holds this, so kept they would keep both
    /// alive, and the project with them.
    func detach() {
        end()
        scrollBy = { _ in 0 }
        trackSpan = { 0...0 }
        areaScrollers = [:]
        areaAt = { _ in nil }
    }

    /// How far to scroll this step with the pointer at `x`: zero away from
    /// the edges, negative near the left.
    private func step(at x: CGFloat) -> CGFloat {
        let span = trackSpan()
        guard span.upperBound - span.lowerBound > Self.edgeWidth * 3 else { return 0 }
        let intoLeft = span.lowerBound + Self.edgeWidth - x
        let intoRight = x - (span.upperBound - Self.edgeWidth)
        if intoLeft > 0 { return -Self.maximumStep * min(1, intoLeft / Self.edgeWidth) }
        if intoRight > 0 { return Self.maximumStep * min(1, intoRight / Self.edgeWidth) }
        return 0
    }
}
