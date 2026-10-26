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
        /// The most motion blur samples a playing frame draws, which
        /// `adapt` moves with how heavy frames are.
        var blurBudget = DrawingOptions.startingBlurBudget
        /// The most samples a clip has asked for while playing, which the
        /// budget doesn't grow past, so it never has far to come down.
        var largestBlurWanted = 0
        /// The meter's frame count when the budget last changed.
        var judgedAt = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The held drag the viewer's frames follow: the app's one, or a test's
    /// own, so tests drawing at once don't see each other's drags.
    let liveValues: LiveValues
    /// Clips' finished pictures kept for the viewer's other frames: the
    /// player's, the paused frame drawn again with new values, and the
    /// playhead's neighborhood drawn ahead (see `ClipPictureCache`).
    let pictures: ClipPictureCache

    init(liveValues: LiveValues = .shared, pictures: ClipPictureCache = ClipPictureCache()) {
        self.liveValues = liveValues
        self.pictures = pictures
    }

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
    /// them for a paused frame; while playing, as many as the budget
    /// allows (two to start, then as `adapt` finds frames have room for);
    /// none (one plain frame) at quarter size or when motion blur is off in
    /// the viewer.
    func motionBlurSamples(wanted: Int) -> Int {
        state.withLock { state in
            guard state.motionBlurInPreview else { return 1 }
            guard state.isPlaying else { return wanted }
            guard !state.isQuarterSize else { return 1 }
            state.largestBlurWanted = max(state.largestBlurWanted, wanted)
            return min(wanted, state.blurBudget)
        }
    }

    /// The budget playing starts with.
    static let startingBlurBudget = 2
    /// Frames drawn with a new budget before it is judged again: those
    /// already asked for were drawn with the old one, and the smoothed load
    /// takes a few to follow.
    static let settleFrames = 8

    /// Moves the motion blur budget by how heavy playing frames have lately
    /// been (`RenderMeter.load`). Frames taking over 80% of their time on
    /// screen halve it, down to one; frames that would still take under
    /// half of it with one more sample each raise it by one, up to the most
    /// a clip has asked for. Called by the compositor after each playing
    /// frame.
    func adapt(to meter: RenderMeter) {
        guard let load = meter.load else { return }
        state.withLock { state in
            guard load.frames - state.judgedAt >= Self.settleFrames else { return }
            let budget = state.blurBudget
            if load.share > 0.8, budget > 1 {
                state.blurBudget = max(1, budget / 2)
            } else if budget < state.largestBlurWanted, load.share * Double(budget + 1) / Double(budget) < 0.5 {
                state.blurBudget = budget + 1
            } else {
                return
            }
            state.judgedAt = load.frames
        }
    }
}
