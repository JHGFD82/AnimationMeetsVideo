import Foundation
import Metal
import os

/// Counts the frames the compositor finishes and how long each took to
/// draw. The compositor records from its own queue; the viewer drains the
/// totals now and then to judge whether playback keeps up.
///
/// It also keeps how heavy playing frames have lately been (`load`): how
/// long each took to draw against how long it is on screen, smoothed over
/// the last few, which `DrawingOptions` draws less or more by.
final class RenderMeter: Sendable {
    struct Totals {
        var frames = 0
        var renderSeconds = 0.0

        var meanRenderSeconds: Double { frames > 0 ? renderSeconds / Double(frames) : 0 }
    }

    /// Recent playing frames' share of their time on screen spent drawing.
    struct Load: Equatable {
        /// Smoothed: 1 is a frame drawn in exactly the time it is shown.
        var share: Double
        /// Playing frames recorded so far, to count frames since a change.
        var frames: Int
    }

    /// How much each new frame counts in the smoothed load.
    static let loadWeight = 0.25

    private struct State {
        var totals = Totals()
        var load: Load?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A frame drawn in `renderSeconds`; `frameSeconds` is how long it is on
    /// screen, for a frame drawn while playing, nil otherwise.
    func record(renderSeconds: Double, frameSeconds: Double? = nil) {
        state.withLock {
            $0.totals.frames += 1
            $0.totals.renderSeconds += renderSeconds
            guard let frameSeconds, frameSeconds > 0 else { return }
            let share = renderSeconds / frameSeconds
            if let load = $0.load {
                $0.load = Load(share: load.share + (share - load.share) * Self.loadWeight, frames: load.frames + 1)
            } else {
                $0.load = Load(share: share, frames: 1)
            }
        }
    }

    /// The totals since the last drain, starting over from zero.
    func drain() -> Totals {
        state.withLock {
            let current = $0.totals
            $0.totals = Totals()
            return current
        }
    }

    /// How heavy playing frames have lately been; nil before any.
    var load: Load? { state.withLock { $0.load } }
}

enum MetalDevice {
    /// One GPU for all drawing, so contexts can share resources.
    static let shared = MTLCreateSystemDefaultDevice()
}
