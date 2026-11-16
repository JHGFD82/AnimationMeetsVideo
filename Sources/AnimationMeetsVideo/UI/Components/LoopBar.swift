import CoreMedia
import SwiftUI

/// The loop bar: a slim row under a ruler holding the loop region of the
/// timeline the player plays (`PlaybackLoop`). Drag across empty bar to
/// draw a region, drag its edges to resize it and its middle to move it,
/// click it to turn it on or off. Shared by every host, which says how
/// timeline time maps to x and what to snap to. See docs/loop-region.md,
/// "The shared view".
///
/// While a drag runs the bar draws a draft; the region itself changes
/// once, on release, so playback keeps looping the old range until then.
/// The region is the player's, not the project's, and changes as soon as
/// it is handed over, so no draft is kept past the release.
struct LoopBar: View {
    let region: LoopRegion?
    /// Gives the frames and the rules for where a region may be.
    let timeline: Timeline
    /// Where a region may be in this host.
    let limits: CMTimeRange
    /// Timeline time to x in the bar, and back. Not a zoom factor: a
    /// graph of a retimed clip isn't linear in timeline time.
    let x: (CMTime) -> CGFloat
    let time: (CGFloat) -> CMTime
    /// The snap target near a time; nil with snapping off or nothing near.
    let snap: (CMTime) -> CMTime?
    let onSnapIndicator: (CMTime?) -> Void
    /// A region drawn, in place of any there was (`PlaybackLoop.draw`).
    let onDraw: (LoopRegion) -> Void
    /// The region resized or moved (`PlaybackLoop.adjust`).
    let onAdjust: (LoopRegion) -> Void
    let onRemove: () -> Void
    let onToggle: () -> Void

    static let height: CGFloat = SectionLane.height
    /// How far a press moves before it is a drag rather than a click.
    static let dragDistance: CGFloat = 3

    /// What a drag in progress does.
    enum Part: Equatable {
        case draw
        case move
        case edge(LoopRegion.Edge)
    }

    /// Drawn in place of the region (or, drawing, over it) while a drag
    /// runs; nil before the pointer has moved, or once Escape cancelled.
    @State private var draft: LoopRegion?
    /// The drag under way, from when the pointer has moved far enough to
    /// be one until the button comes up, cancelled or not. A press that
    /// ends without one is a click.
    @State private var part: Part?
    @State private var escape = EscapableDrag()
    /// The timecode over the pointer while dragging; only the main
    /// timeline installs one.
    @Environment(DragTimecodeReadout.self) private var readout: DragTimecodeReadout?

    private let space = "loopBar"
    private let handleWidth: CGFloat = 6

    /// Whether the region itself is being moved or resized.
    private var isAdjusting: Bool {
        switch part {
        case .move, .edge: true
        case .draw, nil: false
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .gesture(drawGesture)
                // The crosshair, as over the keyframe graph: here a drag
                // draws.
                .pointerStyle(.rectSelection)
            if let region {
                regionView(region, shown: isAdjusting ? draft ?? region : region)
                    // A region being drawn replaces it on release; until
                    // then it stays, dimmed, for Escape to bring back.
                    .opacity(part == .draw && draft != nil ? 0.35 : 1)
            }
            if part == .draw, let draft {
                chip(draft)
                    .offset(x: span(draft).min, y: 2)
                    .decorative()
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .clipped()
        .coordinateSpace(.named(space))
        .help("Loop: drag across the bar to draw a stretch that playback repeats; click it to turn it on or off")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loop")
    }

    // MARK: Drawing

    /// The region as drawn: the loop's tone when on, greyed when off, its
    /// glyph and length on it, cut off when it is too narrow.
    private func chip(_ shown: LoopRegion) -> some View {
        let bounds = span(shown)
        let tone = Design.loop
        let outline = shown.isOn ? tone : tone.greyed()
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                .fill(Design.clipFill(tone, selected: false, enabled: shown.isOn))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(outline.opacity(0.85), lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(Design.bevelEdge, lineWidth: 1)
                }
            HStack(spacing: 3) {
                Image(systemName: Design.Symbol.loop)
                    .font(.system(size: 9, weight: .semibold))
                Text(shown.duration.compactTimecode(frameRate: timeline.frameRate))
                    .font(Design.Typeface.numericMicro)
            }
            .foregroundStyle(Design.textOnColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Design.Space.tight)
            .accessibilityHidden(true)
        }
        .frame(width: max(2, bounds.max - bounds.min), height: Self.height - 4, alignment: .leading)
        .clipped()
    }

    /// `region` as the player has it, drawn as `shown` (the draft while
    /// it is moved or resized). The gestures measure from `region`, never
    /// from the draft, which would add each step to the last.
    private func regionView(_ region: LoopRegion, shown: LoopRegion) -> some View {
        let bounds = span(shown)
        let width = max(2, bounds.max - bounds.min)
        // A tiny region keeps a middle to grab for moving.
        let handle = min(handleWidth, max(2, width / 3))
        return chip(shown)
            .overlay(alignment: .topLeading) {
                // From the chip's left: a graph running backwards in
                // timeline time puts the start on the right.
                edgeHandle(region, edge: .start, width: handle)
                    .offset(x: x(shown.start) - bounds.min - handle / 2)
                edgeHandle(region, edge: .end, width: handle)
                    .offset(x: x(shown.end) - bounds.min - handle / 2)
            }
            .contentShape(Rectangle())
            // The move is the chip's own gesture, so an edge handle's (on
            // a view inside it) takes precedence instead of both running.
            .gesture(regionGesture(region, grabbed: .move))
            .contextMenu {
                Button(region.isOn ? "Turn Loop Off" : "Turn Loop On", action: onToggle)
                Divider()
                Button("Remove Loop Region", role: .destructive, action: onRemove)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loop region")
            .accessibilityValue(
                "\(region.isOn ? "On" : "Off"), from \(timecode(region.start)) to \(timecode(region.end))"
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggle() }
            .accessibilityActions {
                Button("Move start one frame earlier") { step(region, .edge(.start), by: -1) }
                Button("Move start one frame later") { step(region, .edge(.start), by: 1) }
                Button("Move end one frame earlier") { step(region, .edge(.end), by: -1) }
                Button("Move end one frame later") { step(region, .edge(.end), by: 1) }
                Button("Move region one frame earlier") { step(region, .move, by: -1) }
                Button("Move region one frame later") { step(region, .move, by: 1) }
                Button("Remove loop region", action: onRemove)
            }
            .offset(x: bounds.min, y: 2)
    }

    private func edgeHandle(_ region: LoopRegion, edge: LoopRegion.Edge, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width, height: Self.height - 4)
            .contentShape(Rectangle())
            .gesture(regionGesture(region, grabbed: .edge(edge)))
            .pointerStyle(.columnResize)
            .accessibilityHidden(true)
    }

    // MARK: Gestures

    /// Across empty bar: a new region from where the press went down to
    /// the pointer, either way, the press point snapped and then the
    /// moving end. Nothing is drawn until the pointer has moved
    /// `dragDistance`, nor while what is drawn is shorter than the minimum.
    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: Self.dragDistance, coordinateSpace: .named(space))
            .onChanged { value in
                part = .draw
                guard escape.follow(onEscape: cancelDrag) else { return }
                let anchor = snapped(time(value.startLocation.x))
                let target = snap(time(value.location.x))
                onSnapIndicator(target)
                let moving = target ?? time(value.location.x)
                draft = timeline.resolvedLoop(from: anchor, to: moving, within: limits)
                    .map { LoopRegion(start: $0.start, end: $0.end) }
                if let draft {
                    // The end that follows the pointer, and how far from the other.
                    let followsEnd = moving >= anchor
                    readout?.show(followsEnd ? draft.end : draft.start, from: followsEnd ? draft.start : draft.end)
                } else {
                    readout?.hide()
                }
            }
            .onEnded { _ in
                let drawn = draft
                let commits = escape.end()
                endDrag()
                if commits, let drawn { onDraw(drawn) }
            }
    }

    /// On the region (`.move`) or one of its edges. A press released
    /// within `dragDistance` of where it went down, anywhere on the
    /// region, is a click and turns it on or off: told on release, since
    /// toggling on mouse-down would toggle at the start of every drag.
    private func regionGesture(_ region: LoopRegion, grabbed: Part) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                if part == nil {
                    guard hypot(value.translation.width, value.translation.height) >= Self.dragDistance else { return }
                    part = grabbed
                }
                guard escape.follow(onEscape: cancelDrag) else { return }
                // Through the mapping from the pointer's x, not a
                // translation over a zoom.
                let moved = CMTimeSubtract(time(value.location.x), time(value.startLocation.x))
                if case .edge(let edge) = grabbed {
                    let original = edge == .start ? region.start : region.end
                    let proposed = CMTimeAdd(original, moved)
                    let target = snap(proposed)
                    onSnapIndicator(target)
                    let resized = timeline.resolvedLoopEdge(region, edge: edge, to: target ?? proposed, within: limits)
                    draft = resized
                    readout?.show(edge == .start ? resized.start : resized.end, from: original)
                } else {
                    let start = movedStart(of: region, by: moved)
                    let shifted = timeline.resolvedLoopMove(region, toStart: start, within: limits)
                    draft = shifted
                    readout?.show(shifted.start, from: region.start)
                }
            }
            .onEnded { _ in
                guard part != nil else {
                    onToggle()
                    return
                }
                let adjusted = draft
                let commits = escape.end()
                endDrag()
                if commits, let adjusted, adjusted != region { onAdjust(adjusted) }
            }
    }

    /// Where a moved region starts: whichever end is nearer a target
    /// snaps, as a section or a clip does.
    private func movedStart(of region: LoopRegion, by moved: CMTime) -> CMTime {
        let start = CMTimeAdd(region.start, moved)
        let end = CMTimeAdd(start, region.duration)
        let byStart = snap(start)
        let byEnd = snap(end)
        let startGap = byStart.map { abs(CMTimeSubtract($0, start).seconds) } ?? .infinity
        let endGap = byEnd.map { abs(CMTimeSubtract($0, end).seconds) } ?? .infinity
        if let byStart, startGap <= endGap {
            onSnapIndicator(byStart)
            return byStart
        }
        if let byEnd {
            onSnapIndicator(byEnd)
            return CMTimeSubtract(byEnd, region.duration)
        }
        onSnapIndicator(nil)
        return start
    }

    /// Escape during a drag: the region stays as it was, and the rest of
    /// the drag is ignored until the button comes up.
    private func cancelDrag() {
        readout?.hide()
        onSnapIndicator(nil)
        draft = nil
    }

    private func endDrag() {
        readout?.hide()
        onSnapIndicator(nil)
        draft = nil
        part = nil
    }

    // MARK: Without the pointer

    /// A drag a frame at a time, for VoiceOver.
    private func step(_ region: LoopRegion, _ part: Part, by frames: Int32) {
        let delta = CMTimeMultiply(timeline.frameDuration, multiplier: frames)
        let stepped: LoopRegion
        if case .edge(let edge) = part {
            let original = edge == .start ? region.start : region.end
            stepped = timeline.resolvedLoopEdge(region, edge: edge, to: CMTimeAdd(original, delta), within: limits)
        } else {
            stepped = timeline.resolvedLoopMove(region, toStart: CMTimeAdd(region.start, delta), within: limits)
        }
        if stepped != region { onAdjust(stepped) }
    }

    // MARK: Helpers

    /// Where a region is drawn: its ends' x, smaller first.
    private func span(_ region: LoopRegion) -> (min: CGFloat, max: CGFloat) {
        let a = x(region.start), b = x(region.end)
        return (Swift.min(a, b), Swift.max(a, b))
    }

    private func snapped(_ time: CMTime) -> CMTime {
        snap(time) ?? time
    }

    private func timecode(_ time: CMTime) -> String {
        time.timecode(frameRate: timeline.frameRate)
    }
}
