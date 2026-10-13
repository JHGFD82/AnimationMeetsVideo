import CoreMedia
import SwiftUI

struct TimelineRuler: View {
    let duration: CMTime
    let frameRate: Double
    let pixelsPerSecond: CGFloat
    /// The slice of the ruler (in its own x coordinates) currently on screen.
    /// Only this slice is drawn, so a long timeline zoomed far in doesn't
    /// need a huge canvas or thousands of tick labels.
    let visibleX: ClosedRange<CGFloat>

    private let margin: CGFloat = 100

    // Needs real room for "NNf" text (~20pt), not just a tick mark —
    // 6pt was wide enough for a bare mark but produced an illegible smear
    // of overlapping frame-number labels once actually rendered.
    private var showsFrameTicks: Bool {
        pixelsPerSecond / max(frameRate, 1) >= 20
    }

    var body: some View {
        let totalSeconds = max(duration.seconds, 1.0 / max(frameRate, 1))
        let totalWidth = max(1, CGFloat(totalSeconds) * pixelsPerSecond)
        let lower = min(max(0, visibleX.lowerBound - margin), totalWidth)
        let upper = min(max(lower, visibleX.upperBound + margin), totalWidth)
        Canvas { context, _ in
            var context = context
            context.translateBy(x: -lower, y: 0)
            let seconds = Double(max(pixelsPerSecond, 0.01))
            let range = Double(lower) / seconds...Double(upper) / seconds
            if showsFrameTicks {
                drawFrameTicks(context: context, totalSeconds: totalSeconds, visibleSeconds: range)
            } else {
                drawSecondTicks(context: context, totalSeconds: totalSeconds, visibleSeconds: range)
            }
        }
        .frame(width: max(1, upper - lower))
        .offset(x: lower)
        .frame(width: totalWidth, alignment: .leading)
    }

    private func drawFrameTicks(context: GraphicsContext, totalSeconds: Double, visibleSeconds: ClosedRange<Double>) {
        let framesPerSecond = max(1, Int(frameRate.rounded()))
        let totalFrames = max(Int((totalSeconds * frameRate).rounded(.up)), 1)
        let firstFrame = max(0, Int((visibleSeconds.lowerBound * frameRate).rounded(.down)))
        let lastFrame = min(totalFrames, Int((visibleSeconds.upperBound * frameRate).rounded(.up)))
        guard firstFrame <= lastFrame else { return }
        for frame in firstFrame...lastFrame {
            let seconds = Double(frame) / frameRate
            let x = CGFloat(seconds) * pixelsPerSecond
            let isSecondBoundary = frame % framesPerSecond == 0
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: isSecondBoundary ? 11 : 5))
            context.stroke(path, with: .color(.secondary.opacity(isSecondBoundary ? 0.8 : 0.4)), lineWidth: 1)

            if isSecondBoundary {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                context.draw(
                    Text(time.compactTimecode(frameRate: frameRate)).font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: x + 2, y: 19),
                    anchor: .leading
                )
            } else {
                context.draw(
                    Text("\(frame % framesPerSecond)f").font(.system(size: 8)).foregroundStyle(.secondary),
                    at: CGPoint(x: x + 1, y: 18),
                    anchor: .leading
                )
            }
        }
    }

    private func drawSecondTicks(context: GraphicsContext, totalSeconds: Double, visibleSeconds: ClosedRange<Double>) {
        let interval = tickInterval(pixelsPerSecond: pixelsPerSecond)
        let lastIndex = Int(totalSeconds / interval) + 1
        let firstIndex = max(0, Int((visibleSeconds.lowerBound / interval).rounded(.down)))
        let endIndex = min(lastIndex, Int((visibleSeconds.upperBound / interval).rounded(.up)))
        guard firstIndex <= endIndex else { return }
        for index in firstIndex...endIndex {
            let seconds = Double(index) * interval
            let x = CGFloat(seconds) * pixelsPerSecond
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: 8))
            context.stroke(path, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            context.draw(
                Text(time.compactTimecode(frameRate: frameRate)).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: x + 2, y: 19),
                anchor: .leading
            )
        }
    }

    // Picks the smallest "nice" interval wide enough to fit a full
    // hh:mm:ss:ff label without overlapping its neighbor — depends on the
    // current zoom (pixelsPerSecond), not just total duration, so ticks
    // stay legible at any zoom level rather than just for long timelines.
    private func tickInterval(pixelsPerSecond: CGFloat) -> Double {
        let minimumLabelWidth: CGFloat = 76
        let minimumIntervalSeconds = Double(minimumLabelWidth / max(pixelsPerSecond, 0.01))
        let niceIntervals: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        return niceIntervals.first(where: { $0 >= minimumIntervalSeconds }) ?? 3600
    }
}

struct PlayheadLine: View {
    let time: CMTime
    let pixelsPerSecond: CGFloat
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 1.5, height: height)
            .offset(x: CGFloat(time.seconds) * pixelsPerSecond)
            .allowsHitTesting(false)
    }
}

/// Beat ticks in the ruler and faint lines down through the layers, for the
/// beats of the one layer chosen in the view options.
struct BeatMarkerOverlay: View {
    let markers: [CMTime]
    let pixelsPerSecond: CGFloat
    let rulerHeight: CGFloat
    let height: CGFloat
    let visibleX: ClosedRange<CGFloat>

    private let margin: CGFloat = 100

    var body: some View {
        let lower = max(0, visibleX.lowerBound - margin)
        let upper = max(lower + 1, visibleX.upperBound + margin)
        let first = markers.lowerBound(of: Double(lower / max(pixelsPerSecond, 0.01))) { $0.seconds }
        let last = markers.lowerBound(of: Double(upper / max(pixelsPerSecond, 0.01))) { $0.seconds }
        Canvas { context, _ in
            var context = context
            context.translateBy(x: -lower, y: 0)
            guard first < last else { return }
            var ticks = Path()
            var lines = Path()
            for index in first..<last {
                let x = CGFloat(markers[index].seconds) * pixelsPerSecond
                ticks.move(to: CGPoint(x: x, y: rulerHeight - 9))
                ticks.addLine(to: CGPoint(x: x, y: rulerHeight))
                lines.move(to: CGPoint(x: x, y: rulerHeight))
                lines.addLine(to: CGPoint(x: x, y: height))
            }
            context.stroke(lines, with: .color(.orange.opacity(0.22)), lineWidth: 1)
            context.stroke(ticks, with: .color(.orange), lineWidth: 1.5)
        }
        .frame(width: upper - lower, height: height)
        .offset(x: lower)
        .allowsHitTesting(false)
    }
}
