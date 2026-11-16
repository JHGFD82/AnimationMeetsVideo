import CoreMedia
import SwiftUI

/// The loop bar under a graph's time row: the loop region of the timeline,
/// which the graph plays through the editor's player, laid across the
/// plot. Times go through the graph's time axis, so over a retimed clip's
/// parameter the bar follows its source time as the time row does (and
/// runs backwards for a reversed clip). See docs/loop-region.md, "Graph
/// editors and the Keyframe Designer".
struct GraphLoopBar: View {
    let hud: KeyframeGraphHUDs
    let playback: PlaybackModel
    let axis: ParameterTimeAxis
    let timeline: Timeline
    let layout: KeyframeGraphLayout
    /// The graph's keyframes, in its own time, which the region snaps to.
    let keyframes: [CMTime]
    /// The region pressed: the graph lets go of its keyframes.
    let onSelect: () -> Void

    /// The graph editors have no snapping of their own: they follow the
    /// timeline's.
    @AppStorage(Preferences.snapping) private var snapping = true

    /// How far a time snaps, as on the timeline: 8 points.
    private static let snapDistance: CGFloat = 8

    /// Where a region may be over a parameter: its clip, or the whole
    /// timeline for a layer's, cut to the timeline.
    static func limits(clip: TimelineClip?, timeline: Timeline) -> CMTimeRange {
        let whole = CMTimeRange(start: .zero, end: timeline.duration)
        guard let clip else { return whole }
        let start = CMTimeMinimum(clip.startOffset, clip.endOffset), end = CMTimeMaximum(clip.startOffset, clip.endOffset)
        return CMTimeRangeGetIntersection(whole, otherRange: CMTimeRange(start: start, end: end))
    }

    var body: some View {
        let loop = playback.loop
        let plot = layout.plot
        let limits = Self.limits(clip: axis.clip, timeline: timeline)
        let targets = snapping ? snapTargets() : []
        HStack(spacing: 0) {
            Color.clear.frame(width: max(0, plot.minX))
            LoopBar(
                region: loop.region,
                timeline: timeline,
                limits: limits,
                // From the plot's left edge, which the bar starts at.
                x: { x(of: $0) - plot.minX },
                time: { time(atX: $0 + plot.minX) },
                snap: { time in nearest(to: time, among: targets) },
                onSnapIndicator: { _ in },
                onDraw: { region in
                    loop.draw(region)
                    TimelineAreaLayout.showLoopRow()
                },
                onAdjust: { loop.adjust(to: $0) },
                onRemove: { hud.deleteLoop() },
                onToggle: { hud.toggleLoop(over: limits, timeline: timeline) },
                isSelected: hud.isLoopSelected,
                onSelect: {
                    onSelect()
                    hud.isLoopSelected = true
                },
                onSetColor: { loop.setColor($0) },
                onPickColor: { loop.pickColor() }
            )
            .frame(width: max(0, plot.width))
            Spacer(minLength: 0)
        }
        .frame(height: LoopBar.height)
    }

    /// Where timeline time `time` is across the graph.
    private func x(of time: CMTime) -> CGFloat {
        layout.x(axis.keyTime(atTimeline: time).seconds)
    }

    /// The timeline's frame under `x`, held inside the plot.
    private func time(atX x: CGFloat) -> CMTime {
        let held = x.clamped(between: layout.plot.minX, and: layout.plot.maxX)
        let key = CMTime(seconds: layout.seconds(atX: held), preferredTimescale: ParameterTimeAxis.timescale)
        return timeline.snappedToFrame(axis.timelineTime(atKey: key))
    }

    /// The timeline's start, clip and section edges, the playhead, and the
    /// graph's keyframes, in timeline time.
    private func snapTargets() -> [CMTime] {
        let edges = hud.project.snapTargets(in: timeline.id, playhead: nil, markers: []).targets.map(\.time)
        return edges + [hud.playhead] + keyframes.map { axis.timelineTime(atKey: $0) }
    }

    /// The target nearest `time` on screen, within `snapDistance` points:
    /// measured in x, since the graph's time needn't run evenly with the
    /// timeline's.
    private func nearest(to time: CMTime, among targets: [CMTime]) -> CMTime? {
        let at = x(of: time)
        let best = targets.min { abs(x(of: $0) - at) < abs(x(of: $1) - at) }
        guard let best, abs(x(of: best) - at) <= Self.snapDistance else { return nil }
        return best
    }
}

/// Shows or hides the loop bar over the graphs, as the timeline's loop
/// button does its row: one setting for every loop bar, and the loop is on
/// only while they show (`TimelineLoopVisibility`).
struct GraphLoopToggle: View {
    @AppStorage(Preferences.timelineAreaLayout) private var areaLayout = TimelineAreaLayout()

    var body: some View {
        Toggle(isOn: $areaLayout.showsLoop) { Image(systemName: Design.Symbol.loop) }
            .toggleStyle(.icon)
            .help(areaLayout.showsLoop ? "Hide the loop row and turn the loop off" : "Show the loop row and turn the loop on")
            .accessibilityLabel("Loop row")
    }
}
