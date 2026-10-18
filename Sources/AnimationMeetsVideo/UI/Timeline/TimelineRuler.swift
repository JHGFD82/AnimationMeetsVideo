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
            // Past the end of the timeline is still droppable, so it is
            // shaded rather than ruled off: darker, like a recess, not a
            // disabled area.
            let endX = viewport.x(atSeconds: duration.seconds)
            if endX < size.width {
                context.fill(
                    Path(CGRect(x: max(0, endX), y: 0, width: size.width - max(0, endX), height: size.height)),
                    with: .color(.black.opacity(0.22))
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
                    .font(Design.Typeface.numericMicro.weight(landmark.weight))
                    .foregroundStyle(landmark == .none ? Design.textTertiary : Design.textPrimary)
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
        context.stroke(minor, with: .color(Design.textTertiary.opacity(0.45)), lineWidth: 1)
        context.stroke(mid, with: .color(Design.textTertiary.opacity(0.7)), lineWidth: 1)
        context.stroke(major, with: .color(Design.textSecondary), lineWidth: 1)
        context.stroke(landmarks, with: .color(Design.textPrimary.opacity(0.75)), lineWidth: 1)
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

// The playhead's line and head used to be SwiftUI shapes here. They move on
// every playback tick and every pixel of a drag, so they are Core Animation
// layers now — see `PlayheadRail`.

/// Beat ticks in the ruler and faint lines down through the layers, for the
/// beats of the one layer chosen in the view options. Confirmed beats are
/// solid, with taller ticks on downbeats; detected beats nobody has
/// confirmed are dimmer and dashed. Like the ruler's ticks, beats are
/// grouped when zoomed out, once they would crowd closer than
/// `minimumSpacing`: confirmed beats show only downbeats, then every 2nd,
/// 4th… measure, and detected beats, which have no measures, every 2nd,
/// 4th… beat.
struct BeatMarkerOverlay: View {
    let markers: [BeatMarker]
    let viewport: TimelineViewport
    let rulerHeight: CGFloat
    let height: CGFloat

    nonisolated static let minimumSpacing: CGFloat = 10

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

    /// The markers drawn at this zoom, in time order. Snapping uses only
    /// these, so it never catches on a beat that isn't shown.
    nonisolated static func drawnMarkers(_ markers: [BeatMarker], pixelsPerSecond: CGFloat) -> [BeatMarker] {
        let confirmed = markers.filter(\.isConfirmed)
        let detected = markers.filter { !$0.isConfirmed }
        let drawn = measuresThinned(confirmed, pixelsPerSecond: pixelsPerSecond)
            + everyNth(detected, beatsPerMarker(detected.map(\.time), pixelsPerSecond: pixelsPerSecond))
        guard !confirmed.isEmpty, !detected.isEmpty else { return drawn }
        return drawn.sorted { CMTimeCompare($0.time, $1.time) < 0 }
    }

    /// Every beat while there is room, then only downbeats, then the
    /// downbeats of every 2nd, 4th… measure, counted from the first.
    private nonisolated static func measuresThinned(_ beats: [BeatMarker], pixelsPerSecond: CGFloat) -> [BeatMarker] {
        guard beatsPerMarker(beats.map(\.time), pixelsPerSecond: pixelsPerSecond) > 1 else { return beats }
        let downbeats = beats.filter(\.isDownbeat)
        return everyNth(downbeats, beatsPerMarker(downbeats.map(\.time), pixelsPerSecond: pixelsPerSecond))
    }

    private nonisolated static func everyNth(_ beats: [BeatMarker], _ stride: Int) -> [BeatMarker] {
        guard stride > 1 else { return beats }
        return Swift.stride(from: 0, to: beats.count, by: stride).map { beats[$0] }
    }

    var body: some View {
        let visible = viewport.visibleSeconds
        let drawn = Self.drawnMarkers(markers, pixelsPerSecond: viewport.pixelsPerSecond)
        let first = drawn.lowerBound(of: visible.lowerBound - 1) { $0.time.seconds }
        let last = drawn.lowerBound(of: visible.upperBound + 1) { $0.time.seconds }
        Canvas { context, _ in
            var ticks = Path(), downbeatTicks = Path(), detectedTicks = Path()
            var lines = Path(), downbeatLines = Path(), detectedLines = Path()
            for marker in drawn[first..<max(first, last)] {
                let x = viewport.x(atSeconds: marker.time.seconds)
                let tickLength: CGFloat = marker.isDownbeat ? 14 : 9
                func add(tick: inout Path, line: inout Path) {
                    tick.move(to: CGPoint(x: x, y: rulerHeight - tickLength))
                    tick.addLine(to: CGPoint(x: x, y: rulerHeight))
                    line.move(to: CGPoint(x: x, y: rulerHeight))
                    line.addLine(to: CGPoint(x: x, y: height))
                }
                if !marker.isConfirmed {
                    add(tick: &detectedTicks, line: &detectedLines)
                } else if marker.isDownbeat {
                    add(tick: &downbeatTicks, line: &downbeatLines)
                } else {
                    add(tick: &ticks, line: &lines)
                }
            }
            context.stroke(detectedLines, with: .color(Design.beat.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.stroke(detectedTicks, with: .color(Design.beat.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            context.stroke(lines, with: .color(Design.beat.opacity(0.2)), lineWidth: 1)
            context.stroke(ticks, with: .color(Design.beat), lineWidth: 1.5)
            context.stroke(downbeatLines, with: .color(Design.beat.opacity(0.35)), lineWidth: 1)
            context.stroke(downbeatTicks, with: .color(Design.beat), lineWidth: 2)
        }
        .frame(width: viewport.width, height: height)
        .clipped()
        .allowsHitTesting(false)
    }
}
