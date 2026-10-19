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
    var time: CMTime = .zero
}

/// Builds `content` from the parked playhead, and again when it moves,
/// without its parent doing either.
struct PlayheadReader<Content: View>: View {
    let playhead: PlayheadState
    @ViewBuilder let content: (CMTime) -> Content

    var body: some View { content(playhead.time) }
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
