import Foundation

/// The project's values, for the compositor to draw the viewer's frames
/// with: every clip's effects and anchor point, as they are now. The
/// player's item was built with the values of the time it was built; each
/// frame the viewer draws patches the clips' values from here
/// (`DrawClip.withValues`), paused or playing, so an edit of values alone
/// (`StructureKey` unchanged) is seen without building anything. Export
/// never reads it. The compositor reads the one its frames'
/// `DrawingOptions` name: each player's own (`PlaybackModel.liveValues`).
///
/// Only values: a stretch of the timeline that plays from a render holds
/// the values it was made with and draws as it is (see
/// `PlaybackModel.playWithoutRenders`).
final class LiveValues: @unchecked Sendable {
    static let shared = LiveValues()

    private let lock = NSLock()
    private var held: [UUID: TimelineClip]?

    /// Every clip of the project by ID; nil to draw what was built.
    var clips: [UUID: TimelineClip]? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

extension LayeredInstruction {
    /// This stretch drawing the held drag's values, or as it is when there
    /// is none, or when a picture in it can't follow them.
    func followingHeldValues(_ live: [UUID: TimelineClip]?) -> LayeredInstruction {
        guard let live, options != nil else { return self }
        var patched: [DrawClip] = []
        for clip in clips {
            guard let drawn = clip.withValues(from: live) else { return self }
            patched.append(drawn)
        }
        return drawing(patched)
    }
}
