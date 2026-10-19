import CoreMedia
import SwiftUI

/// Maps the selected clip's trimmed range onto the effects panel's lanes,
/// which all show the same stretch of time: from the clip's start to its
/// end. Keyframes count in the clip's source time, so a keyframe's place in
/// the lane is how far it is past the trim start.
struct ClipLaneGeometry {
    let clip: TimelineClip
    let timeline: Timeline
    /// The width of every lane.
    let width: CGFloat

    var duration: Double { max(clip.placedDuration.seconds, 0.001) }
    var pixelsPerSecond: CGFloat { width / CGFloat(duration) }

    /// A source time as a time in the lane (0 at the clip's start), where it
    /// plays, which differs from its distance from the trim start when the
    /// clip is retimed.
    func lane(fromSource time: CMTime) -> CMTime {
        CMTimeSubtract(clip.timelineTime(forSourceTime: time), clip.startOffset)
    }

    func source(fromLane time: CMTime) -> CMTime {
        clip.sourceTime(atTimelineTime: CMTimeAdd(clip.startOffset, time))
    }

    /// A timeline time as a time in the lane.
    func lane(fromTimeline time: CMTime) -> CMTime {
        CMTimeSubtract(time, clip.startOffset)
    }

    func timeline(fromLane time: CMTime) -> CMTime {
        CMTimeAdd(clip.startOffset, time)
    }

    /// The x of a timeline time in a lane, nil when it is outside the clip.
    func x(ofTimeline time: CMTime) -> CGFloat? {
        let seconds = lane(fromTimeline: time).seconds
        guard seconds >= 0, seconds <= duration else { return nil }
        return CGFloat(seconds) * pixelsPerSecond
    }

    /// The timeline time at a lane's x, on the timeline's frames and within
    /// the clip.
    func timelineTime(atX x: CGFloat) -> CMTime {
        let seconds = min(max(Double(x / pixelsPerSecond), 0), duration)
        let raw = timeline(fromLane: CMTime(seconds: seconds, preferredTimescale: 48_000))
        return CMTimeMinimum(CMTimeMaximum(timeline.snappedToFrame(raw), clip.startOffset), clip.endOffset)
    }

    /// The clip's source time at `time` in the timeline, held inside the
    /// clip so edits made with the playhead elsewhere land on its edge.
    func clampedSource(atTimeline time: CMTime) -> CMTime {
        clip.sourceTime(atTimelineTime: CMTimeMinimum(CMTimeMaximum(time, clip.startOffset), clip.endOffset))
    }
}

/// A control's keyframes in a lane of the effects panel: the same diamonds
/// and interactions as the timeline's lanes. Times going in and out of the
/// callbacks are source times.
struct ParameterLane: View {
    /// The keyframes, with source times.
    let marks: [KeyframeMark]
    let geometry: ClipLaneGeometry
    /// The playhead, on a frame, in the timeline's time.
    let playhead: CMTime
    let height: CGFloat
    let onSeek: (CMTime) -> Void
    let onMove: (CMTime, CMTime) -> Void
    let onDelete: (CMTime) -> Void
    let onEase: (CMTime, KeyframeEase.Preset) -> Void

    var body: some View {
        let clip = geometry.clip
        let inside = marks.filter { $0.time >= clip.trimStart && $0.time <= clip.trimEnd }
        let before = marks.filter { $0.time < clip.trimStart }.count
        let after = marks.filter { $0.time > clip.trimEnd }.count
        KeyframeLane(
            marks: inside.map {
                KeyframeMark(time: geometry.lane(fromSource: $0.time), easedIn: $0.easedIn, easedOut: $0.easedOut, isGenerated: $0.isGenerated)
            },
            currentTime: geometry.lane(fromTimeline: playhead),
            pixelsPerSecond: geometry.pixelsPerSecond,
            width: geometry.width,
            height: height,
            snap: { lane in
                geometry.lane(fromTimeline: geometry.timeline.snappedToFrame(geometry.timeline(fromLane: lane)))
            },
            onSeek: { lane in onSeek(geometry.timeline(fromLane: lane)) },
            onMove: { from, to in onMove(geometry.source(fromLane: from), geometry.source(fromLane: to)) },
            onDelete: { onDelete(geometry.source(fromLane: $0)) },
            onEase: { time, preset in onEase(geometry.source(fromLane: time), preset) }
        )
        .overlay(alignment: .leading) { hiddenCount(before, systemImage: "chevron.left") }
        .overlay(alignment: .trailing) { hiddenCount(after, systemImage: "chevron.right") }
    }

    /// Keyframes outside the trimmed range are kept but don't play; this
    /// marks that some are there.
    @ViewBuilder
    private func hiddenCount(_ count: Int, systemImage: String) -> some View {
        if count > 0 {
            HStack(spacing: 1) {
                Image(systemName: systemImage)
                Text("\(count)")
            }
            .font(Design.Typeface.glyphTiny)
            .foregroundStyle(Design.textTertiary)
            .padding(.horizontal, 3)
            .allowsHitTesting(false)
            .help("\(count) keyframe\(count == 1 ? "" : "s") outside the trimmed clip, kept but not played")
        }
    }
}

/// The ruler over the effects panel's lanes. Pressing or dragging on it
/// moves the timeline's playhead.
struct PanelRuler: View {
    let geometry: ClipLaneGeometry
    let onSeek: (CMTime) -> Void

    static let height: CGFloat = 18

    /// Steps the ticks are spaced by, in seconds.
    private static let steps: [Double] = [0.04, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    var body: some View {
        Canvas { context, size in
            let pps = Double(geometry.pixelsPerSecond)
            let step = Self.steps.first { $0 * pps >= 56 } ?? Self.steps.last!
            var seconds = 0.0
            while seconds <= geometry.duration + 1e-9 {
                let x = CGFloat(seconds * pps)
                context.fill(Path(CGRect(x: x, y: size.height - 5, width: 1, height: 5)), with: .color(Design.textTertiary))
                let label = CMTime(seconds: seconds, preferredTimescale: 600)
                    .compactTimecode(frameRate: geometry.timeline.frameRate)
                context.draw(
                    Text(label).font(Design.Typeface.numericMicro).foregroundStyle(Design.textTertiary),
                    at: CGPoint(x: x + 3, y: size.height / 2 - 1), anchor: .leading
                )
                seconds += step
            }
        }
        .frame(width: geometry.width, height: Self.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onSeek(geometry.timelineTime(atX: value.location.x)) }
        )
        .help("Drag to move the playhead")
    }
}

/// The playhead's line down the effects panel's lanes: at `parked`, or
/// while the player plays, where it is, so that following it redraws only
/// this line (as the timeline's `LivePlayheadRail` does).
struct LanePlayheadLine: View {
    let playback: PlaybackModel?
    let parked: CMTime
    let geometry: ClipLaneGeometry

    var body: some View {
        let time = playback.map { $0.isPlaying ? $0.currentTime : parked } ?? parked
        if let x = geometry.x(ofTimeline: time) {
            Rectangle()
                .fill(Design.playhead)
                .frame(width: 1)
                .offset(x: EffectsPanelMetrics.labelWidth + EffectsPanelMetrics.laneInset + x)
        }
    }
}
