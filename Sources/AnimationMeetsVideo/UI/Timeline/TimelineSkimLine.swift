import SwiftUI

/// Where the pointer skims the timeline (`PlaybackModel.skimTime`): a
/// hairline in the playhead's colour, dimmed and without a head, so it
/// reads as a moment shown rather than the playhead. It reads the skim
/// itself, so following the pointer redraws only this line.
struct TimelineSkimLine: View {
    let playback: PlaybackModel
    let viewport: TimelineViewport
    let height: CGFloat

    var body: some View {
        if let time = playback.skimTime {
            Rectangle()
                .fill(Design.playhead.opacity(0.55))
                .frame(width: 1, height: height)
                .offset(x: viewport.x(atSeconds: time.seconds).rounded() - 0.5)
                .accessibilityHidden(true)
        }
    }
}
