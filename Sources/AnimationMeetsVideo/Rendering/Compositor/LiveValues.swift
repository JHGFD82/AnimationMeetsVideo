import Foundation

/// The values of a value drag held to one side of the project
/// (`ProjectState.hold`), for the compositor to draw the viewer's playing
/// frames with. What plays was built before the drag, with its values in
/// the instructions; while this holds clips, each frame the viewer draws
/// patches those clips' effects and anchor points in
/// (`DrawClip.withValues`), so a drag can be seen as it plays, as it is
/// when paused, without building the timeline again. Export never reads it.
/// The compositor reads the one its frames' `DrawingOptions` name: the
/// viewer's is `shared`, which the editor sets.
///
/// Only values: a drag that changes the project's structure, or a stretch
/// of the timeline that plays from a render, can't follow (see
/// `TimelineEditorSurface.drawHeld`).
final class LiveValues: @unchecked Sendable {
    static let shared = LiveValues()

    private let lock = NSLock()
    private var held: [UUID: TimelineClip]?

    /// Every clip of the project with the drag so far, by ID; nil once
    /// the drag's values are in what plays.
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
