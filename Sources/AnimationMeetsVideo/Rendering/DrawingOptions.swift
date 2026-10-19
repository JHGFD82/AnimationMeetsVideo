import Foundation
import os

/// What the viewer asks of drawing while it plays, shared with the
/// compositor and read as each frame is drawn, so it takes effect without
/// building the composition again. Export and renders draw without one, at
/// full quality.
final class DrawingOptions: @unchecked Sendable {
    private struct State {
        var isPlaying = false
        var isQuarterSize = false
        var motionBlurInPreview = true
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func update(isPlaying: Bool? = nil, isQuarterSize: Bool? = nil, motionBlurInPreview: Bool? = nil) {
        state.withLock { state in
            if let isPlaying { state.isPlaying = isPlaying }
            if let isQuarterSize { state.isQuarterSize = isQuarterSize }
            if let motionBlurInPreview { state.motionBlurInPreview = motionBlurInPreview }
        }
    }

    var motionBlurInPreview: Bool { state.withLock { $0.motionBlurInPreview } }

    /// Whether the viewer is playing, so the costliest looks draw less.
    var isPlaying: Bool { state.withLock { $0.isPlaying } }

    /// How many of the `wanted` moments across the shutter to draw: all of
    /// them for a paused frame, two while playing, none (one plain frame) at
    /// quarter size or when motion blur is off in the viewer.
    func motionBlurSamples(wanted: Int) -> Int {
        state.withLock { state in
            guard state.motionBlurInPreview else { return 1 }
            guard state.isPlaying else { return wanted }
            return state.isQuarterSize ? 1 : min(wanted, 2)
        }
    }
}
