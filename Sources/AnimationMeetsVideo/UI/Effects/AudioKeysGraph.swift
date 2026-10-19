import AppKit
import SwiftUI

/// Audio Keys' spectrum and box (see docs/keyframing-effects.md, "Audio
/// Keys in detail"): what the effect hears at the playhead, frequency on a
/// log scale across and level up, with the box over it. The box's left and
/// right edges are the frequency range, its bottom and top the levels that
/// read 0 and 1, and a line across it how loud its range is now. Drag an
/// edge to move it, or inside to move the whole box. Shown in the effect's
/// editor (`AudioKeysEditor`), where the four values are also fields.
///
/// A drag is held to one side of the project (`ProjectState.hold`), with
/// the box drawn from the drag's own values, and written to the project
/// once, when the drag ends.
struct AudioKeysGraph: View {
    /// Each band's level at the playhead, or nil while the sound is read.
    let bands: [Double]?
    /// The box the project has; `frequencies` and `levels` are the drag's
    /// while one is held.
    let committedFrequencies: (low: Double, high: Double)
    let committedLevels: (floor: Double, ceiling: Double)
    /// How loud the box's range is now, in decibels, drawn across it.
    var level: Double?
    var isDimmed = false
    let onSetFrequencies: (Double, Double) -> Void
    let onSetLevels: (Double, Double) -> Void

    @Environment(\.projectHistory) private var history
    @Environment(ProjectState.self) private var projectState: ProjectState?
    @State private var drag: DragState?
    /// The box a drag has reached, which the project lags behind while the
    /// drag is held.
    @State private var dragged: (frequencies: (low: Double, high: Double), levels: (floor: Double, ceiling: Double))?

    init(
        bands: [Double]?, frequencies: (low: Double, high: Double), levels: (floor: Double, ceiling: Double),
        level: Double? = nil, isDimmed: Bool = false,
        onSetFrequencies: @escaping (Double, Double) -> Void, onSetLevels: @escaping (Double, Double) -> Void
    ) {
        self.bands = bands
        committedFrequencies = frequencies
        committedLevels = levels
        self.level = level
        self.isDimmed = isDimmed
        self.onSetFrequencies = onSetFrequencies
        self.onSetLevels = onSetLevels
    }

    private var frequencies: (low: Double, high: Double) { dragged?.frequencies ?? committedFrequencies }
    private var levels: (floor: Double, ceiling: Double) { dragged?.levels ?? committedLevels }

    /// The level at the bottom of the graph; quieter is drawn as nothing.
    static let lowest = -96.0

    private enum Part { case low, high, floor, ceiling, box }

    private struct DragState {
        var part: Part
        var frequencies: (low: Double, high: Double)
        var levels: (floor: Double, ceiling: Double)
    }

    var body: some View {
        GeometryReader { proxy in
            let plot = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 2, dy: 4)
            Canvas { context, _ in
                draw(in: &context, plot: plot)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(plot: plot))
        }
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .opacity(isDimmed ? 0.5 : 1)
        .help("Drag the box's edges to choose the frequencies it listens to and the levels that read as nothing and as full; drag inside to move it")
        .accessibilityElement()
        .accessibilityLabel("Audio Keys box")
        .accessibilityValue(description)
        .accessibilityHint("Adjust to move the frequencies up or down")
        .accessibilityAdjustableAction { direction in
            let factor = direction == .increment ? pow(2, 1.0 / 3) : pow(2, -1.0 / 3)
            setFrequencies(frequencies.low * factor, frequencies.high * factor)
        }
        .accessibilityAction(named: "Raise levels") { setLevels(levels.floor + 3, levels.ceiling + 3) }
        .accessibilityAction(named: "Lower levels") { setLevels(levels.floor - 3, levels.ceiling - 3) }
    }

    private var description: String {
        let hertz = { (value: Double) in EqualizerGraphLayout.frequencyLabel(value) + " Hz" }
        let level = { (value: Double) in NumericExpression.format(value, maxFractionDigits: 1) + " dB" }
        return "\(hertz(frequencies.low)) to \(hertz(frequencies.high)), \(level(levels.floor)) to \(level(levels.ceiling))"
    }

    // MARK: Layout

    private func x(_ frequency: Double, _ plot: CGRect) -> CGFloat {
        let span = log(Spectrogram.highestFrequency / Spectrogram.lowestFrequency)
        return plot.minX + CGFloat(log(max(frequency, 1) / Spectrogram.lowestFrequency) / span) * plot.width
    }

    private func frequency(atX x: CGFloat, _ plot: CGRect) -> Double {
        let fraction = Double((x - plot.minX) / max(plot.width, 1))
        return Spectrogram.lowestFrequency * pow(Spectrogram.highestFrequency / Spectrogram.lowestFrequency, fraction)
    }

    private func y(_ decibels: Double, _ plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat((decibels - Self.lowest) / -Self.lowest) * plot.height
    }

    private func decibels(atY y: CGFloat, _ plot: CGRect) -> Double {
        Self.lowest + Double((plot.maxY - y) / max(plot.height, 1)) * -Self.lowest
    }

    private func box(_ plot: CGRect) -> CGRect {
        let left = x(frequencies.low, plot), right = x(frequencies.high, plot)
        let top = y(levels.ceiling, plot), bottom = y(levels.floor, plot)
        return CGRect(x: min(left, right), y: min(top, bottom), width: abs(right - left), height: abs(bottom - top))
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, plot: CGRect) {
        // Decades and every 24 dB.
        for frequency in [100.0, 1000, 10_000] {
            let gridX = x(frequency, plot)
            context.stroke(Path { $0.move(to: CGPoint(x: gridX, y: plot.minY)); $0.addLine(to: CGPoint(x: gridX, y: plot.maxY)) },
                           with: .color(.white.opacity(0.08)), lineWidth: 1)
        }
        for level in stride(from: -24.0, to: Self.lowest, by: -24) {
            let gridY = y(level, plot)
            context.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: gridY)); $0.addLine(to: CGPoint(x: plot.maxX, y: gridY)) },
                           with: .color(.white.opacity(0.08)), lineWidth: 1)
        }
        if let bands {
            for (band, level) in bands.enumerated() where level > Self.lowest {
                let left = x(Spectrogram.edge(band), plot), right = x(Spectrogram.edge(band + 1), plot)
                let top = y(min(level, 0), plot)
                context.fill(Path(CGRect(x: left + 0.5, y: top, width: max(right - left - 1, 1), height: plot.maxY - top)),
                             with: .color(Design.textSecondary.opacity(0.45)))
            }
        } else {
            context.draw(Text("Reading the sound…").font(Design.Typeface.micro).foregroundStyle(Design.textTertiary),
                         at: CGPoint(x: plot.midX, y: plot.midY))
        }
        let rect = box(plot)
        context.fill(Path(rect), with: .color(Design.generatedKeyframe.opacity(0.18)))
        if let level, level > Self.lowest {
            // Up to the top of the box, where it reads as full.
            let levelY = max(y(min(level, 0), plot), rect.minY)
            if levelY < rect.maxY {
                context.fill(Path(CGRect(x: rect.minX, y: levelY, width: rect.width, height: rect.maxY - levelY)),
                             with: .color(Design.generatedKeyframe.opacity(0.35)))
            }
        }
        context.stroke(Path(rect), with: .color(Design.generatedKeyframe), lineWidth: 1.5)
    }

    // MARK: Editing

    /// The part of the box nearest `point`: an edge within a few points,
    /// or the box itself.
    private func part(at point: CGPoint, _ plot: CGRect) -> Part? {
        let rect = box(plot), reach: CGFloat = 6
        let withinY = point.y >= rect.minY - reach && point.y <= rect.maxY + reach
        let withinX = point.x >= rect.minX - reach && point.x <= rect.maxX + reach
        if withinY, abs(point.x - x(frequencies.low, plot)) <= reach { return .low }
        if withinY, abs(point.x - x(frequencies.high, plot)) <= reach { return .high }
        if withinX, abs(point.y - y(levels.ceiling, plot)) <= reach { return .ceiling }
        if withinX, abs(point.y - y(levels.floor, plot)) <= reach { return .floor }
        return rect.contains(point) ? .box : nil
    }

    private func dragGesture(plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil {
                    guard let part = part(at: value.startLocation, plot) else { return }
                    history?.beginGesture()
                    projectState?.beginHold()
                    drag = DragState(part: part, frequencies: frequencies, levels: levels)
                    dragged = (frequencies, levels)
                }
                guard let drag else { return }
                if let projectState {
                    projectState.hold { move(drag, to: value, plot: plot) }
                } else {
                    move(drag, to: value, plot: plot)
                }
            }
            .onEnded { _ in
                guard let started = drag else { return }
                let last = dragged
                projectState?.endHold()
                dragged = nil
                drag = nil
                // The drag's last box goes to the project once; a drag let
                // go (see `ProjectState.letGo`) has written it already.
                if let last {
                    if last.frequencies != started.frequencies { onSetFrequencies(last.frequencies.low, last.frequencies.high) }
                    if last.levels != started.levels { onSetLevels(last.levels.floor, last.levels.ceiling) }
                }
                // After the last edit has reached the project.
                Task { @MainActor in history?.endGesture() }
            }
    }

    private func move(_ drag: DragState, to value: DragGesture.Value, plot: CGRect) {
        let point = value.location
        switch drag.part {
        case .low: setFrequencies(frequency(atX: point.x, plot), drag.frequencies.high)
        case .high: setFrequencies(drag.frequencies.low, frequency(atX: point.x, plot))
        case .floor: setLevels(decibels(atY: point.y, plot), drag.levels.ceiling)
        case .ceiling: setLevels(drag.levels.floor, decibels(atY: point.y, plot))
        case .box:
            // Moved by the same ratio of frequency and the same
            // number of decibels at both edges.
            let ratio = frequency(atX: x(drag.frequencies.low, plot) + value.translation.width, plot) / drag.frequencies.low
            let shift = decibels(atY: y(drag.levels.floor, plot) + value.translation.height, plot) - drag.levels.floor
            setFrequencies(drag.frequencies.low * ratio, drag.frequencies.high * ratio)
            setLevels(drag.levels.floor + shift, drag.levels.ceiling + shift)
        }
    }

    private func setFrequencies(_ low: Double, _ high: Double) {
        let kind = ControlKind.frequencyRange
        let a = kind.clamped(min(low, high)), b = kind.clamped(max(low, high))
        let high = max(b, min(a * 1.01, Spectrogram.highestFrequency))
        if dragged != nil { dragged?.frequencies = (a, high) }
        onSetFrequencies(a, high)
    }

    private func setLevels(_ floor: Double, _ ceiling: Double) {
        let kind = ControlKind.levelRange
        let a = kind.clamped(min(floor, ceiling)), b = kind.clamped(max(floor, ceiling))
        let ceiling = max(b, min(a + 1, 0))
        if dragged != nil { dragged?.levels = (a, ceiling) }
        onSetLevels(a, ceiling)
    }
}
