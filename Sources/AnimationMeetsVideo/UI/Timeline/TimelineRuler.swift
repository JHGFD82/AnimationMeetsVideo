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

    var body: some View {
        Canvas { context, size in
            let endX = viewport.x(atSeconds: duration.seconds)
            if endX < size.width {
                context.fill(
                    Path(CGRect(x: max(0, endX), y: 0, width: size.width - max(0, endX), height: size.height)),
                    with: .color(.primary.opacity(0.06))
                )
            }
            drawTicks(context: context, height: size.height)
        }
        .frame(width: viewport.width)
        .clipped()
    }

    private func drawTicks(context: GraphicsContext, height: CGFloat) {
        let frameDuration = Timeline.frameDuration(for: frameRate)
        let frameSeconds = frameDuration.seconds
        let ticks = RulerTicks(frameRate: frameRate, pixelsPerFrame: viewport.pixelsPerSecond * CGFloat(frameSeconds))
        let visible = viewport.visibleSeconds
        let step = ticks.framesPerTick
        // Start a label's width early, so one whose tick is just off the
        // left edge still shows the part of it that is on screen.
        let firstFrame = max(0, Int(((visible.lowerBound - Double(RulerTicks.minimumLabelSpacing / viewport.pixelsPerSecond)) / frameSeconds).rounded(.down)))
        let lastFrame = Int((min(visible.upperBound, viewport.contentSeconds) / frameSeconds).rounded(.up))
        var frame = firstFrame / step * step
        var landmarks = Path(), major = Path(), mid = Path(), minor = Path()
        while frame <= lastFrame {
            let x = viewport.x(atSeconds: Double(frame) * frameSeconds)
            switch ticks.level(ofFrame: frame) {
            case .label:
                let landmark = ticks.landmark(ofFrame: frame)
                if landmark == .none {
                    major.move(to: CGPoint(x: x, y: 0))
                    major.addLine(to: CGPoint(x: x, y: 12))
                } else {
                    landmarks.move(to: CGPoint(x: x, y: 0))
                    landmarks.addLine(to: CGPoint(x: x, y: height))
                }
                let time = CMTimeMultiply(frameDuration, multiplier: Int32(clamping: frame))
                let label = Text(time.compactTimecode(frameRate: frameRate))
                    .font(.caption2.monospacedDigit().weight(landmark.weight))
                    .foregroundStyle(landmark == .none ? Color.secondary : Color.primary)
                context.draw(label, at: CGPoint(x: x + 3, y: 18), anchor: .leading)
            case .mid:
                mid.move(to: CGPoint(x: x, y: 0))
                mid.addLine(to: CGPoint(x: x, y: 8))
            case .minor:
                minor.move(to: CGPoint(x: x, y: 0))
                minor.addLine(to: CGPoint(x: x, y: 4))
            }
            frame += step
        }
        context.stroke(minor, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
        context.stroke(mid, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
        context.stroke(major, with: .color(.secondary.opacity(0.85)), lineWidth: 1)
        context.stroke(landmarks, with: .color(.primary.opacity(0.8)), lineWidth: 1)
    }
}

/// How the ruler groups frames at a given zoom. Every step is a whole
/// number of frames that splits a second evenly — for 24 fps: 1, 2, 4, 6
/// (a quarter second), 8, 12 (a half) — and above a second, the usual 1, 2,
/// 5, 10, 15, 30 seconds and up. Labels go on the smallest step that leaves
/// room for them, with a mid tick halfway and minor ticks on the smallest
/// step that still leaves visible gaps.
///
/// When labels are closer than a second, a minute or an hour, the labels on
/// whole seconds, minutes or hours are landmarks: drawn brighter, heavier
/// and with a full-height tick, so the round numbers stand out among the
/// frames, seconds or minutes between them.
struct RulerTicks: Equatable {
    enum Level { case label, mid, minor }

    enum Landmark: Int, Comparable {
        case none, second, minute, hour

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var weight: Font.Weight {
            switch self {
            case .none: .regular
            case .second: .medium
            case .minute: .semibold
            case .hour: .bold
            }
        }
    }

    let framesPerLabel: Int
    let framesPerMidTick: Int?
    let framesPerTick: Int
    private let framesPerSecond: Int

    static let minimumLabelSpacing: CGFloat = 80
    static let minimumTickSpacing: CGFloat = 6

    init(frameRate: Double, pixelsPerFrame: CGFloat) {
        framesPerSecond = max(1, Int(frameRate.rounded()))
        let steps = Self.steps(framesPerSecond: framesPerSecond)
        let label = steps.first { CGFloat($0) * pixelsPerFrame >= Self.minimumLabelSpacing } ?? steps[steps.count - 1]
        let tick = steps.first { label % $0 == 0 && CGFloat($0) * pixelsPerFrame >= Self.minimumTickSpacing } ?? label
        framesPerLabel = label
        framesPerTick = tick
        let half = label / 2
        framesPerMidTick = label % 2 == 0 && half > tick && half % tick == 0 ? half : nil
    }

    /// Every step, in frames, smallest first.
    static func steps(framesPerSecond fps: Int) -> [Int] {
        let withinSecond = (1..<fps).filter { divisor in
            fps % divisor == 0 && (divisor <= 2 || (2...6).contains(fps / divisor))
        }
        let seconds = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 18_000, 36_000]
        return withinSecond + seconds.map { $0 * fps }
    }

    /// The largest round unit a labeled frame starts, if labels are finer
    /// than that unit. Counted in nominal frames, like the timecode.
    func landmark(ofFrame frame: Int) -> Landmark {
        let units: [(Landmark, Int)] = [(.hour, 3600), (.minute, 60), (.second, 1)]
        for (landmark, seconds) in units {
            let frames = seconds * framesPerSecond
            if framesPerLabel < frames, frame % frames == 0 { return landmark }
        }
        return .none
    }

    func level(ofFrame frame: Int) -> Level {
        if frame % framesPerLabel == 0 { return .label }
        if let framesPerMidTick, frame % framesPerMidTick == 0 { return .mid }
        return .minor
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
/// beats of the one layer chosen in the view options. Like the ruler's
/// ticks, beats are grouped when zoomed out: only every 2nd, 4th, 8th…
/// beat is drawn once they would crowd closer than `minimumSpacing`.
struct BeatMarkerOverlay: View {
    let markers: [CMTime]
    let viewport: TimelineViewport
    let rulerHeight: CGFloat
    let height: CGFloat

    static let minimumSpacing: CGFloat = 10

    /// How many beats each drawn one stands for: a power of two, counted
    /// from the first beat of the track so the same beats stay drawn while
    /// scrolling. Uses the average beat length, so a changing tempo thins
    /// evenly rather than by its fastest stretch.
    nonisolated static func beatsPerMarker(_ markers: [CMTime], pixelsPerSecond: CGFloat) -> Int {
        guard markers.count > 1, let first = markers.first, let last = markers.last else { return 1 }
        let averageSpacing = CGFloat((last.seconds - first.seconds) / Double(markers.count - 1)) * pixelsPerSecond
        guard averageSpacing > 0 else { return 1 }
        var stride = 1
        while CGFloat(stride) * averageSpacing < minimumSpacing, stride < markers.count {
            stride *= 2
        }
        return stride
    }

    /// The markers drawn at this zoom: every `beatsPerMarker`-th, counted
    /// from the first. Snapping uses only these, so it never catches on a
    /// beat that isn't shown.
    nonisolated static func drawnMarkers(_ markers: [CMTime], pixelsPerSecond: CGFloat) -> [CMTime] {
        let stride = beatsPerMarker(markers, pixelsPerSecond: pixelsPerSecond)
        guard stride > 1 else { return markers }
        return Swift.stride(from: 0, to: markers.count, by: stride).map { markers[$0] }
    }

    var body: some View {
        let visible = viewport.visibleSeconds
        let stride = Self.beatsPerMarker(markers, pixelsPerSecond: viewport.pixelsPerSecond)
        let first = markers.lowerBound(of: visible.lowerBound - 1) { $0.seconds }
        let last = markers.lowerBound(of: visible.upperBound + 1) { $0.seconds }
        Canvas { context, _ in
            var ticks = Path()
            var lines = Path()
            for index in Swift.stride(from: (first + stride - 1) / stride * stride, to: last, by: stride) {
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
