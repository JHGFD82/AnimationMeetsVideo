import CoreMedia
import Observation
import SwiftUI

/// The parked playhead, where it rests while the player isn't playing.
/// The editor's surface owns it but doesn't read it as it builds its body:
/// each step of the playhead would then build everything the surface does
/// again, the timeline, the panels and the viewer. The views that show it
/// read it themselves, through `PlayheadReader` or in an action.
@MainActor
@Observable
final class PlayheadState {
    var time: CMTime
    /// The player's time while it plays, nil otherwise; set by the surface
    /// that owns the player. Not observed: it is read as an action runs.
    @ObservationIgnored var liveTime: (() -> CMTime?)?

    init(time: CMTime = .zero) {
        self.time = time
    }

    /// Where the playhead is as an action runs: the player's time while it
    /// plays, which `time` doesn't follow, else where it is parked. A
    /// keyframe made from the stopwatch while playing goes where playing
    /// is, not where it started.
    var actionTime: CMTime { liveTime?() ?? time }
}

/// How a row finds the playhead, in the time it works in (the timeline's, on
/// a frame; a clip's source time for a clip's rows). A row reads it while it
/// draws a value that is animated, which makes it follow the playhead, and
/// when it acts, never as its parent is built: a row showing a fixed value
/// isn't redrawn by the playhead, and still adds a keyframe where it is.
@MainActor
struct PlayheadTime {
    private let read: () -> CMTime
    private let readCurrent: () -> CMTime

    init(_ playhead: PlayheadState, in convert: @escaping (CMTime) -> CMTime = { $0 }) {
        read = { convert(playhead.time) }
        readCurrent = { convert(playhead.actionTime) }
    }

    /// A playhead that stays at `time`.
    init(fixed time: CMTime) {
        read = { time }
        readCurrent = { time }
    }

    /// Where the playhead is as an action runs, which follows the player
    /// while it plays (see `PlayheadState.actionTime`); `now` is where it
    /// is parked.
    var current: CMTime { readCurrent() }

    /// Where the playhead is now. Reading it as a body is built makes the
    /// view follow the playhead.
    var now: CMTime { read() }

    /// The playhead for a value that may be `animated`: a fixed value
    /// doesn't depend on it.
    func shown(animated: Bool) -> CMTime { animated ? read() : .zero }
}

/// Builds `content` from the parked playhead, and again when it moves,
/// without its parent doing either.
struct PlayheadReader<Content: View>: View {
    let playhead: PlayheadState
    @ViewBuilder let content: (CMTime) -> Content

    var body: some View { content(playhead.time) }
}

/// Builds `content` from where the playhead is for a row (see `PlayheadTime`),
/// and again when it moves, without its parent doing either.
struct PlayheadTimeReader<Content: View>: View {
    let playhead: PlayheadTime
    @ViewBuilder let content: (CMTime) -> Content

    var body: some View { content(playhead.now) }
}

/// Follows the playhead and the player's time for the editor's surface,
/// which reads neither as it builds its body.
struct PlayheadFollower: View {
    let playhead: PlayheadState
    let playback: PlaybackModel
    /// The parked playhead moved, and where it is.
    let onMove: (CMTime) -> Void
    /// The player's time moved while the tape scrubber has it.
    let onTapeScrub: (CMTime) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: playhead.time, initial: true) { _, time in onMove(time) }
            .onChange(of: playback.currentTime) { _, time in
                if playback.isTapeScrubbing { onTapeScrub(time) }
            }
            .accessibilityHidden(true)
    }
}
