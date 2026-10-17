import CoreMedia
import SwiftUI

/// The playhead drawn over the tracks. While playing it follows the player
/// itself, so only this view redraws on each tick rather than the whole
/// timeline; parked, it shows `parked`.
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
        let playing = playback.isPlaying
        let time = playing ? playback.currentTime : parked
        let x = viewport.x(atSeconds: time.seconds)
        // Checked here because this is the one view that sees every tick;
        // the page turn itself is a scroll of the whole timeline.
        let leftView = playing && onLeaveView != nil && (x < 0 || x > viewport.width)
        PlayheadRail(
            playheadX: x,
            isPlayheadVisible: (-1...(viewport.width + 1)).contains(x),
            snapX: snapX,
            height: height
        )
        .frame(width: viewport.width, height: height)
        .onChange(of: leftView) { _, left in
            if left { onLeaveView?(time) }
        }
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
