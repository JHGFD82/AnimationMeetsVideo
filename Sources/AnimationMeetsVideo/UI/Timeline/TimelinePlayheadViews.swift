import CoreMedia
import SwiftUI

/// The playhead drawn over the tracks. While playing it runs on the
/// player's own clock (`PlayheadRail.Following`), so following it redraws
/// nothing, not even this view; parked, it shows `parked`.
struct LivePlayheadRail: View {
    let playback: PlaybackModel
    let parked: CMTime
    let viewport: TimelineViewport
    /// Called with the playhead's time when it leaves the view while
    /// playing (including when playing starts with it out of view), so the
    /// timeline can page after it. Nil not to follow.
    let onLeaveView: ((CMTime) -> Void)?
    let snapX: CGFloat?
    let height: CGFloat

    var body: some View {
        let x = viewport.x(atSeconds: parked.seconds)
        PlayheadRail(
            playheadX: x,
            isPlayheadVisible: (-1...(viewport.width + 1)).contains(x),
            snapX: snapX,
            height: height,
            following: playback.isPlaying
                ? PlayheadRail.Following(
                    player: playback.player,
                    pixelsPerSecond: viewport.pixelsPerSecond,
                    originX: viewport.x(atSeconds: 0),
                    seconds: viewport.contentSeconds,
                    onLeaveView: onLeaveView
                )
                : nil
        )
        .frame(width: viewport.width, height: height)
    }
}

/// The playhead's timecode in the timeline's header, following the player
/// while it plays, like `LivePlayheadRail`.
struct PlayheadTimecode: View {
    let playback: PlaybackModel
    let parked: CMTime
    let frameRate: Double

    var body: some View {
        Text((playback.isPlaying ? playback.currentTime : parked).timecode(frameRate: frameRate))
            .font(Design.Typeface.numericSmall)
            .foregroundStyle(Design.textSecondary)
    }
}
