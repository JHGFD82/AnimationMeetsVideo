import CoreMedia
import SwiftUI

/// Time ticks and labels across the top of the track area. Only the visible
/// slice is drawn, so a long timeline zoomed far in doesn't need a huge
/// canvas or thousands of tick labels. Time past the timeline's end (room
/// to drag clips into) is shaded.
struct TimelineRuler: View {
    let duration: CMTime
    let frameRate: Double
    let viewport: TimelineViewport

    private var pixelsPerSecond: CGFloat { viewport.pixelsPerSecond }

    // Needs real room for "NNf" text (~20pt), not just a tick mark —
    // 6pt was wide enough for a bare mark but produced an illegible smear
    // of overlapping frame-number labels once actually rendered.
    private var showsFrameTicks: Bool {
        pixelsPerSecond / max(frameRate, 1) >= 20
    }

    var body: some View {
        Canvas { context, size in
            let endX = viewport.x(atSeconds: duration.seconds)
            if endX < size.width {
                context.fill(
                    Path(CGRect(x: max(0, endX), y: 0, width: size.width - max(0, endX), height: size.height)),
                    with: .color(.primary.opacity(0.06))
                )
            }
            var context = context
            context.translateBy(x: -viewport.scrollX, y: 0)
            let visible = viewport.visibleSeconds
            let range = max(0, visible.lowerBound - 1)...min(viewport.contentSeconds, visible.upperBound + 1)
            if showsFrameTicks {
                drawFrameTicks(context: context, visibleSeconds: range)
            } else {
                drawSecondTicks(context: context, visibleSeconds: range)
            }
        }
        .frame(width: viewport.width)
        .clipped()
    }

    private func drawFrameTicks(context: GraphicsContext, visibleSeconds: ClosedRange<Double>) {
        let framesPerSecond = max(1, Int(frameRate.rounded()))
        let firstFrame = max(0, Int((visibleSeconds.lowerBound * frameRate).rounded(.down)))
        let lastFrame = Int((visibleSeconds.upperBound * frameRate).rounded(.up))
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

    private func drawSecondTicks(context: GraphicsContext, visibleSeconds: ClosedRange<Double>) {
        let interval = tickInterval(pixelsPerSecond: pixelsPerSecond)
        let firstIndex = max(0, Int((visibleSeconds.lowerBound / interval).rounded(.down)))
        let endIndex = Int((visibleSeconds.upperBound / interval).rounded(.up))
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

/// The handle at the top of the playhead, in the ruler: something clearly
/// grabbable for dragging through time.
struct PlayheadHead: View {
    let x: CGFloat

    static let width: CGFloat = 13
    static let height: CGFloat = 14

    var body: some View {
        PlayheadHeadShape()
            .fill(Color.red)
            .overlay(PlayheadHeadShape().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: Self.width, height: Self.height)
            .offset(x: x - Self.width / 2)
            .allowsHitTesting(false)
    }
}

/// A downward-pointing tab: square shoulders over a point at the playhead.
private struct PlayheadHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let shoulder = rect.height * 0.55
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulder))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: shoulder))
        path.closeSubpath()
        return path
    }
}

struct PlayheadLine: View {
    let x: CGFloat
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 1.5, height: height)
            .offset(x: x - 0.75)
            .allowsHitTesting(false)
    }
}

/// Beat ticks in the ruler and faint lines down through the layers, for the
/// beats of the one layer chosen in the view options.
struct BeatMarkerOverlay: View {
    let markers: [CMTime]
    let viewport: TimelineViewport
    let rulerHeight: CGFloat
    let height: CGFloat

    var body: some View {
        let visible = viewport.visibleSeconds
        let first = markers.lowerBound(of: visible.lowerBound - 1) { $0.seconds }
        let last = markers.lowerBound(of: visible.upperBound + 1) { $0.seconds }
        Canvas { context, _ in
            guard first < last else { return }
            var ticks = Path()
            var lines = Path()
            for index in first..<last {
                let x = viewport.x(atSeconds: markers[index].seconds)
                ticks.move(to: CGPoint(x: x, y: rulerHeight - 9))
                ticks.addLine(to: CGPoint(x: x, y: rulerHeight))
                lines.move(to: CGPoint(x: x, y: rulerHeight))
                lines.addLine(to: CGPoint(x: x, y: height))
            }
            context.stroke(lines, with: .color(.orange.opacity(0.22)), lineWidth: 1)
            context.stroke(ticks, with: .color(.orange), lineWidth: 1.5)
        }
        .frame(width: viewport.width, height: height)
        .clipped()
        .allowsHitTesting(false)
    }
}
