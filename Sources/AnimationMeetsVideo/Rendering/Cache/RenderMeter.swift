import Foundation
import Metal
import os

/// Counts the frames the compositor finishes and how long each took to
/// draw. The compositor records from its own queue; the viewer drains the
/// totals now and then to judge whether playback keeps up.
final class RenderMeter: Sendable {
    struct Totals {
        var frames = 0
        var renderSeconds = 0.0

        var meanRenderSeconds: Double { frames > 0 ? renderSeconds / Double(frames) : 0 }
    }

    private let totals = OSAllocatedUnfairLock(initialState: Totals())

    func record(renderSeconds: Double) {
        totals.withLock {
            $0.frames += 1
            $0.renderSeconds += renderSeconds
        }
    }

    /// The totals since the last drain, starting over from zero.
    func drain() -> Totals {
        totals.withLock {
            let current = $0
            $0 = Totals()
            return current
        }
    }
}

enum MetalDevice {
    /// One GPU for all drawing, so contexts can share resources.
    static let shared = MTLCreateSystemDefaultDevice()
}
