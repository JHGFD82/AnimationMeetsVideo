import CoreMedia
import SwiftUI

// The loop region in the Motion Designer: the same region as the
// timeline's, played through the same player, held to the designer's
// window while it is open. See docs/loop-region.md, "Motion Designer".
extension MotionDesignSession {
    /// Where a region may be drawn or moved here, and what the loop may
    /// play while the designer is open: its window.
    var loopLimits: CMTimeRange {
        let window = window
        return CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: 600),
            end: CMTime(seconds: window.end, preferredTimescale: 600)
        )
    }

    /// Holds the loop to the window, which follows the run.
    func narrowLoop() {
        playback.loop.narrow(to: loopLimits)
    }

    /// C: the region on or off, or with none, one over the run's clips,
    /// turned on, which shows the loop bar. Says which to VoiceOver. (The
    /// loop button shows or hides the bar, as the timeline's does.)
    func toggleLoop() {
        let loop = playback.loop
        if loop.region != nil {
            loop.toggle()
        } else if let made = timeline.resolvedLoop(from: run.span.start, to: run.span.end, within: loopLimits) {
            loop.draw(LoopRegion(start: made.start, end: made.end))
        } else {
            return
        }
        if loop.isOn { TimelineAreaLayout.showLoopRow() }
        AccessibilityNotification.Announcement(loop.isOn ? "Loop on" : "Loop off").post()
    }

    /// [ and ]: an end of the region to the playhead, within the window;
    /// with no region, one from the playhead to the window's end, or from
    /// its start to the playhead.
    func setLoopEdgeToPlayhead(_ edge: LoopRegion.Edge) {
        let time = timeline.snappedToFrame(CMTime(seconds: playhead, preferredTimescale: 600))
        playback.loop.setEdge(edge, to: time, on: timeline, within: loopLimits)
    }

    /// A region drawn in the designer's bar, which is on.
    func drawLoop(_ region: LoopRegion) {
        playback.loop.draw(region)
        TimelineAreaLayout.showLoopRow()
    }

    /// The region pressed in its bar: it alone is selected, for Delete.
    func selectLoop() {
        pickedPoints.set([])
        selectedPieceID = nil
        isLoopSelected = true
    }

    /// Delete with the region selected, and its menu's Delete Loop Region.
    func deleteLoop() {
        playback.loop.remove()
        isLoopSelected = false
    }
}
