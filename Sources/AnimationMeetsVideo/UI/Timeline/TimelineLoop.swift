import CoreMedia
import SwiftUI

/// The loop bar under the ruler. Reads the loop in its own body, so
/// turning the loop on or off doesn't rebuild the whole timeline
/// (`TimelineView` is `Equatable` and doesn't read it).
struct TimelineLoopLane: View {
    let parent: TimelineView
    let width: CGFloat

    var body: some View {
        let model = parent.viewportModel
        parent.loopBar(viewport: parent.viewport(width: width))
            .frame(width: width, height: LoopBar.height)
            .rubberBandStretch(model.zoomBand)
            .rubberBandScroll(model.scrollBand, length: model.trackAreaWidth)
            .clipped()
    }
}

// The loop region in the main timeline: its bar, C and the Timeline
// menu's items. The header's loop button shows or hides the bar, as the
// sections button does its row. See docs/loop-region.md.
extension TimelineView {
    func loopBar(viewport: TimelineViewport) -> some View {
        let tolerance = snapTolerance(viewport)
        let loop = playback.loop
        return LoopBar(
            region: loop.region,
            timeline: timeline,
            limits: CMTimeRange(start: .zero, end: timeline.duration),
            x: { viewport.x(atSeconds: $0.seconds) },
            time: { CMTime(seconds: max(0, viewport.seconds(atX: $0)), preferredTimescale: 600) },
            snap: { [liveSnap] time in liveSnap.targets?.nearest(to: time, within: tolerance) },
            onSnapIndicator: { viewportModel.snapIndicator = $0 },
            onDraw: { loop.draw($0) },
            onAdjust: { loop.adjust(to: $0) },
            onRemove: { loop.remove() },
            onToggle: { toggleLoop() }
        )
    }

    /// C and Loop Playback: turns the region on or off, or with none,
    /// makes one over the selected clips, else the whole timeline, and
    /// turns it on. Says which to VoiceOver, since nothing else does.
    func toggleLoop() {
        let loop = playback.loop
        if loop.region != nil {
            loop.toggle()
        } else if let made = timeline.defaultLoop(over: menuSelection.clips) {
            loop.draw(made)
        } else {
            return
        }
        AccessibilityNotification.Announcement(loop.isOn ? "Loop on" : "Loop off").post()
    }

    /// Set Loop Start to Playhead.
    func setLoopStartToPlayhead() {
        setLoop(timeline.loopSettingStart(of: playback.loop.region, to: timeline.snappedToFrame(livePlayheadTime)))
    }

    /// Set Loop End to Playhead.
    func setLoopEndToPlayhead() {
        setLoop(timeline.loopSettingEnd(of: playback.loop.region, to: timeline.snappedToFrame(livePlayheadTime)))
    }

    /// A region made, or the one there adjusted, by the menu.
    private func setLoop(_ region: LoopRegion?) {
        guard let region else { return }
        let loop = playback.loop
        if loop.region == nil { loop.draw(region) } else { loop.adjust(to: region) }
    }
}
