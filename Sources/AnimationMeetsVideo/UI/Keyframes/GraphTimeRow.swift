import CoreMedia
import SwiftUI

/// A ruler along the top of a graph, in the timeline's time, lined up with
/// the plot under it: clicking or dragging along it moves the playhead
/// there, on a frame, whether or not the graphs skim. With the focus, the
/// left and right arrows move the playhead a frame (ten with Shift), and
/// VoiceOver adjusts it a frame at a time.
struct GraphTimeRow: View {
    let hud: KeyframeGraphHUDs
    let axis: ParameterTimeAxis
    let timeline: Timeline
    let layout: KeyframeGraphLayout

    static let height: CGFloat = 20

    @FocusState private var isFocused: Bool

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .overlay { GraphTimeRowHead(playback: hud.playback, parked: hud.playhead, axis: axis, layout: layout) }
        .frame(height: Self.height)
        .background(Color.black.opacity(isFocused ? 0.35 : 0.25))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
        // The arrows are the row's while it has the focus, so it says so.
        .overlay {
            Rectangle()
                .strokeBorder(Design.accent, lineWidth: 1)
                .opacity(isFocused ? 1 : 0)
                .decorative()
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { drag in
            isFocused = true
            seek(toX: drag.location.x)
        })
        .onContinuousHover { phase in
            if case .active = phase { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let steps = press.modifiers.contains(.shift) ? 10 : 1
            step(frames: press.key == .leftArrow ? -steps : steps)
            return .handled
        }
        .help("Drag to move the playhead; with the row clicked, ← → move it a frame")
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue(hud.playhead.timecode(frameRate: timeline.frameRate))
        .accessibilityHint("Adjust to move the playhead a frame")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(frames: 1)
            case .decrement: step(frames: -1)
            @unknown default: break
            }
        }
    }

    // MARK: Seeking

    /// Moves the playhead to the frame under `x`, within the plot.
    private func seek(toX x: CGFloat) {
        let clamped = x.clamped(between: layout.plot.minX, and: layout.plot.maxX)
        let key = CMTime(seconds: layout.seconds(atX: clamped), preferredTimescale: ParameterTimeAxis.timescale)
        hud.onSeek(timeline.snappedToFrame(CMTimeMaximum(.zero, axis.timelineTime(atKey: key))))
    }

    private func step(frames: Int) {
        let moved = CMTimeAdd(timeline.snappedToFrame(hud.playhead), CMTimeMultiply(timeline.frameDuration, multiplier: Int32(frames)))
        hud.onSeek(CMTimeMaximum(.zero, moved))
    }

    // MARK: Drawing

    /// Where timeline second `seconds` is across.
    private func x(_ seconds: Double) -> CGFloat {
        layout.x(axis.keyTime(atTimeline: CMTime(seconds: seconds, preferredTimescale: ParameterTimeAxis.timescale)).seconds)
    }

    /// A tick at each step far enough apart to label, with its timecode,
    /// and four between.
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let plot = layout.plot
        let key = { CMTime(seconds: $0, preferredTimescale: ParameterTimeAxis.timescale) }
        let start = axis.timelineTime(atKey: key(layout.times.lowerBound)).seconds
        let end = axis.timelineTime(atKey: key(layout.times.upperBound)).seconds
        guard end > start, plot.width > 0 else { return }
        let step = Self.step(seconds: end - start, width: plot.width, frame: timeline.frameDuration.seconds)
        let minor = step / 5
        let ticks = Color.white.opacity(0.25)
        var index = (start / minor).rounded(.down)
        while index * minor <= end {
            let seconds = index * minor
            let at = x(seconds)
            if at >= plot.minX - 0.5, at <= plot.maxX + 0.5 {
                let major = Int(index.rounded()) % 5 == 0
                let height: CGFloat = major ? 8 : 4
                context.fill(Path(CGRect(x: at - 0.5, y: size.height - height, width: 1, height: height)), with: .color(ticks))
                if major, seconds >= 0 {
                    let label = Text(CMTime(seconds: seconds, preferredTimescale: 600).timecode(frameRate: timeline.frameRate))
                        .font(Design.Typeface.micro)
                        .foregroundStyle(Design.textTertiary)
                    context.draw(label, at: CGPoint(x: at + 3, y: 2), anchor: .topLeading)
                }
            }
            index += 1
        }
    }

    /// The labelled step for `seconds` across `width` points: the shortest
    /// of a few round ones, frames up to minutes, at least 80 points apart.
    static func step(seconds: Double, width: CGFloat, frame: Double) -> Double {
        let perPoint = seconds / Double(width)
        let steps = [5, 10].map { Double($0) * frame } + [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        return steps.first { $0 / perPoint >= 80 } ?? steps[steps.count - 1]
    }
}

/// The playhead's head on the time row: parked, or while the player plays
/// where it is, so following it redraws only the head.
private struct GraphTimeRowHead: View {
    let playback: PlaybackModel?
    let parked: CMTime
    let axis: ParameterTimeAxis
    let layout: KeyframeGraphLayout

    var body: some View {
        let time = playback.map { $0.isPlaying ? $0.currentTime : parked } ?? parked
        let x = layout.x(axis.keyTime(atTimeline: time).seconds)
        Canvas { context, size in
            guard (layout.plot.minX...layout.plot.maxX).contains(x) else { return }
            var head = Path()
            head.move(to: CGPoint(x: x - 5, y: size.height - 9))
            head.addLine(to: CGPoint(x: x + 5, y: size.height - 9))
            head.addLine(to: CGPoint(x: x, y: size.height))
            head.closeSubpath()
            context.fill(head, with: .color(Design.playhead))
            context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(Design.playhead))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
