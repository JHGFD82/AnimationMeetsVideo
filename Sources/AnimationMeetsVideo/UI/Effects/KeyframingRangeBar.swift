import CoreMedia
import SwiftUI

/// The range of the selected Keyframing effect, over the effects panel's
/// ruler: a band from where it starts writing to where it stops (the whole
/// clip with no range set), with a handle at each end to drag on the
/// timeline's frames. A drag is one undo step, held to one side of the
/// project (`ProjectState.hold`) and written to it when it ends. Each handle is also an
/// adjustable element, a frame a step, for VoiceOver and the keyboard; the
/// effect's Range menu does the same from its ⋯ menu.
struct KeyframingRangeBar: View {
    let geometry: ClipLaneGeometry
    /// The range in the clip's source time; nil is the whole clip.
    let range: CMTimeRange?
    /// Moves one end to a source time; the effect refuses one that would
    /// leave nothing between them.
    let onSet: (_ start: CMTime?, _ end: CMTime?) -> Void

    @Environment(\.projectHistory) private var history
    @Environment(ProjectState.self) private var projectState: ProjectState?
    @State private var dragging = false
    /// The end a drag has moved, and where, which the project lags behind
    /// while the drag is held.
    @State private var dragged: (isStart: Bool, time: CMTime)?

    private static let handleWidth: CGFloat = 7

    private var clip: TimelineClip { geometry.clip }
    private var start: CMTime { dragged.flatMap { $0.isStart ? $0.time : nil } ?? range?.start ?? clip.trimStart }
    private var end: CMTime { dragged.flatMap { $0.isStart ? nil : $0.time } ?? range?.end ?? clip.trimEnd }

    private func x(ofSource time: CMTime) -> CGFloat {
        CGFloat(geometry.lane(fromSource: time).seconds) * geometry.pixelsPerSecond
    }

    var body: some View {
        let a = x(ofSource: start), b = x(ofSource: end)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Design.generatedKeyframe.opacity(range == nil ? 0.12 : 0.25))
                .frame(width: max(abs(b - a), 1), height: PanelRuler.height)
                .offset(x: min(a, b))
                .allowsHitTesting(false)
            handle(at: a, isStart: true)
            handle(at: b, isStart: false)
        }
        .frame(width: geometry.width, height: PanelRuler.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    private func handle(at x: CGFloat, isStart: Bool) -> some View {
        let time = isStart ? start : end
        let name = isStart ? "Keyframing range start" : "Keyframing range end"
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Design.generatedKeyframe)
            .frame(width: Self.handleWidth, height: PanelRuler.height)
            .contentShape(Rectangle().inset(by: -3))
            .offset(x: x - Self.handleWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            history?.beginGesture()
                            projectState?.beginHold()
                        }
                        let moved = geometry.clampedSource(atTimeline: geometry.timelineTime(atX: value.location.x))
                        dragged = (isStart, moved)
                        if let projectState {
                            projectState.hold { set(isStart, to: moved) }
                        } else {
                            set(isStart, to: moved)
                        }
                    }
                    .onEnded { _ in
                        guard dragging else { return }
                        let last = dragged
                        projectState?.endHold()
                        dragged = nil
                        dragging = false
                        // The last end goes to the project once; a drag let
                        // go (see `ProjectState.letGo`) has written it already.
                        if let last { set(last.isStart, to: last.time) }
                        // After the last edit has reached the project.
                        Task { @MainActor in history?.endGesture() }
                    }
            )
            .pointerStyle(.frameResize(position: isStart ? .leading : .trailing))
            .help(isStart ? "Drag to where the effect starts writing keyframes" : "Drag to where it stops")
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityValue(clip.timelineTime(forSourceTime: time).timecode(frameRate: geometry.timeline.frameRate))
            .accessibilityAdjustableAction { direction in
                let frame = geometry.timeline.frameDuration
                let timeline = clip.timelineTime(forSourceTime: time)
                let moved = direction == .increment ? CMTimeAdd(timeline, frame) : CMTimeSubtract(timeline, frame)
                set(isStart, to: geometry.clampedSource(atTimeline: moved))
            }
    }

    private func set(_ isStart: Bool, to time: CMTime) {
        if isStart { onSet(time, nil) } else { onSet(nil, time) }
    }

    /// The bar's own coordinates, which the handles' drags are measured in.
    static let space = "KeyframingRangeBar"
}
