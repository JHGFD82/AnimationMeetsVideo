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

/// Keeps the loop on only while its bar shows: hiding the bar (the
/// header's loop button, or Loop row in the view options) turns the loop
/// off, and showing it turns it on again. A region found on while the bar
/// is hidden, as a project opened that way has, is turned off. Turning
/// the loop on from C or the menu shows the bar first
/// (`TimelineView.showLoopRow`). A view of its own, so the timeline's
/// body doesn't read the loop.
struct TimelineLoopVisibility: View {
    let loop: PlaybackLoop
    let isShown: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: isShown) { _, shown in
                guard let region = loop.region, region.isOn != shown else { return }
                loop.toggle()
                AccessibilityNotification.Announcement(shown ? "Loop on" : "Loop off").post()
            }
            .onChange(of: loop.isOn, initial: true) { _, on in
                if on, !isShown { loop.toggle() }
            }
    }
}

// The loop region in the main timeline: its bar, C and the Timeline
// menu's items. The header's loop button shows or hides the bar, which
// turns the loop on or off with it (`TimelineLoopVisibility`). See
// docs/loop-region.md.
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
            onRemove: { deleteLoop() },
            onToggle: { toggleLoop() },
            isSelected: isLoopSelected,
            onSelect: { selectLoop() }
        )
    }

    /// The region pressed in its bar: it becomes the selection, for
    /// Delete, and nothing else stays selected, as for a section.
    func selectLoop() {
        isLoopSelected = true
        selectedSectionID = nil
        selectedLayerID = nil
        groupSelection = []
        host.dispatch(.selectLayer)
    }

    /// Delete with the region selected, its menu's Delete Loop Region and
    /// the Timeline menu's.
    func deleteLoop() {
        playback.loop.remove()
        isLoopSelected = false
    }

    /// Shows the loop bar, which a loop turned on needs: hidden, it would
    /// be turned off again (`TimelineLoopVisibility`).
    func showLoopRow() {
        if !areaLayout.showsLoop { areaLayout.showsLoop = true }
    }

    /// C and Loop Playback: turns the region on or off, or with none,
    /// makes one over the selected clips, else the whole timeline, and
    /// turns it on. Turned on, the bar shows. Says which to VoiceOver,
    /// since nothing else does.
    func toggleLoop() {
        let loop = playback.loop
        if loop.region != nil {
            loop.toggle()
        } else if let made = timeline.defaultLoop(over: menuSelection.clips) {
            loop.draw(made)
        } else {
            return
        }
        if loop.isOn { showLoopRow() }
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
        if loop.isOn { showLoopRow() }
    }
}
