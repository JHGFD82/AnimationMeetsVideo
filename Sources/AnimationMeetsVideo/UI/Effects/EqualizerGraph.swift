import CoreMedia
import AppKit
import SwiftUI

/// Where frequencies and gains sit on an EQ graph: frequency on a log
/// scale from 20 Hz to 20 kHz across, gain from −24 to +24 dB up.
struct EqualizerGraphLayout {
    let plot: CGRect

    static let decibels = 24.0
    /// The three decades from 20 Hz to 20 kHz.
    private static let decades = 3.0

    func x(_ frequency: Double) -> CGFloat {
        plot.minX + CGFloat(log10(max(frequency, 1) / Equalizer.frequencies.lowerBound) / Self.decades) * plot.width
    }

    func frequency(atX x: CGFloat) -> Double {
        let fraction = Double((x - plot.minX) / max(plot.width, 1))
        return Equalizer.frequencies.lowerBound * pow(10, fraction * Self.decades)
    }

    func y(_ decibels: Double) -> CGFloat {
        plot.midY - CGFloat(decibels / Self.decibels) * plot.height / 2
    }

    func gain(atY y: CGFloat) -> Double {
        Double((plot.midY - y) / max(plot.height / 2, 1)) * Self.decibels
    }

    /// "50", "1k", "10k".
    static func frequencyLabel(_ frequency: Double) -> String {
        frequency >= 1000 ? "\(NumericExpression.format(frequency / 1000, maxFractionDigits: 1))k" : NumericExpression.format(frequency, maxFractionDigits: 0)
    }
}

/// What an EQ's graph shows behind its curves.
enum EqualizerSpectrumMode: String, CaseIterable, Identifiable {
    case post, pre, off

    var id: Self { self }

    var name: String {
        switch self {
        case .post: "After EQ"
        case .pre: "Before EQ"
        case .off: "Off"
        }
    }
}

/// An EQ effect's bands on a graph (see docs/equalizer.md, "The graph"):
/// each band's curve faintly in its color, the whole EQ's in bold, and a
/// dot per band to drag. Drag a dot to move its frequency and gain,
/// ⌥-drag or scroll over it to change its Q, ⇧-drag to move along one axis only; dragging a
/// band that's off turns it on, and double-clicking one switches it on or
/// off. The curves come from the same coefficients the sound is filtered
/// with, so what is drawn is what is heard. Behind them is the spectrum of
/// the sound at the playhead while it plays (`EqualizerSpectrum`), after
/// the EQ or before it, and while paused the clip's own sound there, read
/// from its file (`readPaused`).
///
/// With a band picked (clicked, or reached with Tab), the arrow keys move
/// its frequency and gain and ⌥ with up and down changes its Q; VoiceOver
/// reaches each band as an element of its own with the same actions.
///
/// A drag of a dot is held to one side of the project (`ProjectState.hold`),
/// with the graph drawn from its own copy of the effect, and written to the
/// project once, when the drag ends.
struct EqualizerGraph: View {
    /// The effect the project has; `effect` is the drag's while one is held.
    let committed: Effect
    /// The clip's source time at the playhead, where edits land.
    let time: CMTime
    var isDimmed = false
    /// Changes the control of one band, or the output, of the effect.
    let onEdit: (ControlKind, (inout EffectControl) -> Void) -> Void
    var onExpand: (() -> Void)?
    /// Reads the spectrum at the playhead from the clip's file, for when
    /// nothing is playing; nil for a clip without a file of its own.
    var readPaused: PausedReader?

    typealias Reading = (decibels: [Float], binWidth: Double)
    typealias PausedReader = (_ pre: Bool, _ effect: Effect, _ time: CMTime) async -> Reading?

    @Environment(\.projectHistory) private var history
    @Environment(ProjectState.self) private var projectState: ProjectState?
    /// The effect as a held drag has changed it.
    @State private var heldEffect: Effect?
    /// The edits of the drag's latest step, which the project gets when it ends.
    @State private var stepEdits: [(kind: ControlKind, change: (inout EffectControl) -> Void)] = []
    @AppStorage(Preferences.equalizerSpectrum) private var spectrumMode = EqualizerSpectrumMode.post
    @State private var spectrum = SpectrumBallistics()
    @State private var picked: EqualizerBand?
    @State private var drag: DragState?
    @FocusState private var isFocused: Bool
    /// The spectrum read from the file while paused, and where.
    @State private var paused: PausedReading?
    /// Ends a scroll's undo step once scrolling stops.
    @State private var scrollEnd: Task<Void, Never>?

    private struct PausedReading {
        var time: CMTime
        var pre: Bool
        var reading: Reading
    }

    /// What a paused reading depends on: reading again when any of it
    /// changes, once it has held still a moment.
    private struct PausedRequest: Equatable {
        var time: CMTime
        var mode: EqualizerSpectrumMode
        var effect: Effect
    }

    init(
        effect: Effect, time: CMTime, isDimmed: Bool = false,
        onEdit: @escaping (ControlKind, (inout EffectControl) -> Void) -> Void,
        onExpand: (() -> Void)? = nil, readPaused: PausedReader? = nil
    ) {
        committed = effect
        self.time = time
        self.isDimmed = isDimmed
        self.onEdit = onEdit
        self.onExpand = onExpand
        self.readPaused = readPaused
    }

    private var effect: Effect { heldEffect ?? committed }

    /// The height it takes in the effects panel.
    static let panelHeight: CGFloat = 150

    private struct DragState {
        var band: EqualizerBand
        var start: [Double]
        var startPoint: CGPoint
    }

    /// One color per band, around the wheel so neighbors tell apart.
    static func color(of band: EqualizerBand) -> Color {
        Color(hue: Double(band.rawValue) / Double(EqualizerBand.allCases.count) * 0.85, saturation: 0.6, brightness: 0.95)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = EqualizerGraphLayout(plot: CGRect(
                x: 28, y: 6, width: max(proxy.size.width - 34, 10), height: max(proxy.size.height - 20, 10)
            ))
            ZStack(alignment: .topTrailing) {
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: spectrumMode == .off)) { frame in
                    Canvas { context, _ in
                        if spectrumMode != .off {
                            let pre = spectrumMode == .pre
                            let reading = EqualizerSpectrum.shared.levels(of: effect.id, pre: pre, at: time.seconds)
                                ?? paused.flatMap { $0.time == time && $0.pre == pre ? $0.reading : nil }
                            spectrum.update(reading, now: frame.date.timeIntervalSinceReferenceDate)
                            drawSpectrum(in: &context, layout: layout)
                        }
                        draw(in: &context, layout: layout)
                    }
                }
                    .contentShape(Rectangle())
                    .background(ScrollWheelMonitor { deltaY, location in scroll(deltaY, at: location, layout: layout) })
                    .gesture(dragGesture(layout))
                    .onTapGesture(count: 2, coordinateSpace: .local) { location in
                        guard let band = self.band(near: location, layout: layout) else { return }
                        picked = band
                        onEdit(band.controlKind) { $0.enabled.toggle() }
                    }
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        picked = self.band(near: location, layout: layout)
                        isFocused = true
                    }
                    .accessibilityHidden(true)
                ForEach(bands, id: \.self) { band in
                    accessibleNode(band, layout: layout)
                }
                HStack(spacing: Design.Space.step) {
                    Menu {
                        Picker("Spectrum", selection: $spectrumMode) {
                            ForEach(EqualizerSpectrumMode.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("What the spectrum behind the curves shows: the sound after the EQ, before it, or nothing")
                    .accessibilityLabel("Spectrum")
                    .accessibilityValue(spectrumMode.name)
                    if let onExpand {
                        Button(action: onExpand) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(.plain)
                        .help("Show the EQ larger")
                        .accessibilityLabel("Show the EQ larger")
                    }
                }
                .font(Design.Typeface.glyphSmall)
                .foregroundStyle(Design.textSecondary)
                .padding(6)
            }
        }
        .task(id: PausedRequest(time: time, mode: spectrumMode, effect: effect)) { await readPausedSpectrum() }
        .onAppear { EqualizerSpectrum.shared.watch(effect.id) }
        .onDisappear { EqualizerSpectrum.shared.unwatch(effect.id) }
        .opacity(isDimmed ? 0.55 : 1)
        .background(Color.black.opacity(0.18))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .tab]) { press in
            handle(press.key, modifiers: press.modifiers) ? .handled : .ignored
        }
    }

    // MARK: Bands

    /// The bands the effect still has (a deleted band's control is gone).
    private var bands: [EqualizerBand] {
        EqualizerBand.allCases.filter { effect.control($0.controlKind) != nil }
    }

    private func values(of band: EqualizerBand) -> [Double] {
        let values = effect.control(band.controlKind)?.values(at: time) ?? []
        return values.count == band.defaultValues.count ? values : band.defaultValues
    }

    private func isOn(_ band: EqualizerBand) -> Bool {
        effect.control(band.controlKind)?.enabled ?? false
    }

    /// Where a band's dot is: at its frequency and gain (a cut's on 0 dB).
    private func point(of band: EqualizerBand, layout: EqualizerGraphLayout) -> CGPoint {
        let values = values(of: band)
        let gain = band.gainIndex.map { values[$0] } ?? 0
        return CGPoint(x: layout.x(values[EqualizerBand.frequencyIndex]), y: layout.y(gain))
    }

    /// The band whose dot is nearest `location`, within reach of a click.
    private func band(near location: CGPoint, layout: EqualizerGraphLayout) -> EqualizerBand? {
        let reach: CGFloat = 12
        return bands
            .map { ($0, hypot(point(of: $0, layout: layout).x - location.x, point(of: $0, layout: layout).y - location.y)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: Editing

    private func dragGesture(_ layout: EqualizerGraphLayout) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil {
                    guard let band = self.band(near: value.startLocation, layout: layout) else { return }
                    history?.beginGesture()
                    drag = DragState(band: band, start: values(of: band), startPoint: point(of: band, layout: layout))
                    picked = band
                    // Switching a band on is a change of its own, made before the drag is held.
                    if !isOn(band) { onEdit(band.controlKind) { $0.enabled = true } }
                    heldEffect = projectState == nil ? nil : effect.changing(band.controlKind) { $0.enabled = true }
                    projectState?.beginHold()
                }
                guard let drag else { return }
                let modifiers = NSEvent.modifierFlags
                if let projectState {
                    stepEdits = []
                    projectState.hold { move(drag, by: value.translation, layout: layout, modifiers: modifiers) }
                } else {
                    move(drag, by: value.translation, layout: layout, modifiers: modifiers)
                }
            }
            .onEnded { _ in
                guard drag != nil else { return }
                let edits = stepEdits
                projectState?.endHold()
                heldEffect = nil
                stepEdits = []
                drag = nil
                // The drag's last step goes to the project once; a drag let
                // go (see `ProjectState.letGo`) has written it already.
                for edit in edits { onEdit(edit.kind, edit.change) }
                // After the last edit has reached the project.
                Task { @MainActor in history?.endGesture() }
            }
    }

    /// An edit a drag makes: to the project, and while the drag is held to
    /// the copy of the effect the graph draws.
    private func dragEdit(_ kind: ControlKind, _ change: @escaping (inout EffectControl) -> Void) {
        if heldEffect != nil {
            heldEffect = heldEffect?.changing(kind, change)
            stepEdits.append((kind, change))
        }
        onEdit(kind, change)
    }

    /// Sets the dragged band from where the drag has taken it: frequency
    /// and gain from the dot's new place, or with ⌥ its Q, an octave wider
    /// or narrower every 40 points up or down.
    private func move(_ drag: DragState, by translation: CGSize, layout: EqualizerGraphLayout, modifiers: NSEvent.ModifierFlags) {
        let band = drag.band
        var dx = translation.width, dy = translation.height
        if modifiers.contains(.option) {
            let q = drag.start[band.qIndex] * pow(2, Double(-dy) / 40)
            let time = time
            dragEdit(band.controlKind) { $0.setComponent(band.qIndex, to: q, at: time) }
            return
        }
        if modifiers.contains(.shift) {
            if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
        }
        let frequency = layout.frequency(atX: drag.startPoint.x + dx)
        let gain = layout.gain(atY: drag.startPoint.y + dy)
        let time = time
        dragEdit(band.controlKind) { control in
            control.setComponent(EqualizerBand.frequencyIndex, to: frequency, at: time)
            if let index = band.gainIndex { control.setComponent(index, to: gain, at: time) }
        }
    }

    /// Scrolling over a band's dot changes its Q: an octave narrower per
    /// 120 points up. A scroll is one undo, ending when it stops.
    private func scroll(_ deltaY: CGFloat, at location: CGPoint, layout: EqualizerGraphLayout) -> Bool {
        guard drag == nil, let band = self.band(near: location, layout: layout) else { return false }
        if scrollEnd == nil { history?.beginGesture() }
        scrollEnd?.cancel()
        scrollEnd = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            history?.endGesture()
            scrollEnd = nil
        }
        picked = band
        let q = values(of: band)[band.qIndex] * pow(2, Double(deltaY) / 120)
        onEdit(band.controlKind) { control in
            control.enabled = true
            control.setComponent(band.qIndex, to: q, at: time)
        }
        return true
    }

    /// While nothing plays, the spectrum at the playhead from the clip's
    /// file, once the playhead and settings have held still for 200 ms.
    private func readPausedSpectrum() async {
        guard spectrumMode != .off, let readPaused else { return }
        try? await Task.sleep(for: .milliseconds(200))
        let pre = spectrumMode == .pre
        // Playing: the taps' recordings cover it.
        guard !Task.isCancelled, EqualizerSpectrum.shared.levels(of: effect.id, pre: pre, at: time.seconds) == nil else { return }
        let reading = await readPaused(pre, effect, time)
        guard !Task.isCancelled else { return }
        paused = reading.map { PausedReading(time: time, pre: pre, reading: $0) }
    }

    /// A twelfth of an octave, 0.5 dB, or a sixth of an octave of Q per press.
    private func nudge(_ band: EqualizerBand, frequency: Double = 0, gain: Double = 0, q: Double = 0) {
        let values = values(of: band)
        onEdit(band.controlKind) { control in
            if frequency != 0 {
                control.setComponent(EqualizerBand.frequencyIndex, to: values[EqualizerBand.frequencyIndex] * pow(2, frequency / 12), at: time)
            }
            if gain != 0, let index = band.gainIndex { control.setComponent(index, to: values[index] + gain * 0.5, at: time) }
            if q != 0 { control.setComponent(band.qIndex, to: values[band.qIndex] * pow(2, q / 6), at: time) }
        }
    }

    private func handle(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        if key == .tab {
            let all = bands
            guard !all.isEmpty else { return false }
            let step = modifiers.contains(.shift) ? -1 : 1
            let index = picked.flatMap { all.firstIndex(of: $0) }.map { ($0 + step + all.count) % all.count } ?? 0
            picked = all[index]
            return true
        }
        guard let band = picked else { return false }
        switch key {
        case .leftArrow: nudge(band, frequency: -1)
        case .rightArrow: nudge(band, frequency: 1)
        case .upArrow: modifiers.contains(.option) ? nudge(band, q: 1) : nudge(band, gain: 1)
        case .downArrow: modifiers.contains(.option) ? nudge(band, q: -1) : nudge(band, gain: -1)
        default: return false
        }
        return true
    }

    // MARK: Accessibility

    private func description(of band: EqualizerBand) -> String {
        let values = values(of: band)
        var parts = [band.name, isOn(band) ? "on" : "off", "\(NumericExpression.format(values[0], maxFractionDigits: 0)) hertz"]
        if let index = band.gainIndex { parts.append("\(NumericExpression.format(values[index], maxFractionDigits: 1)) decibels") }
        parts.append("Q \(NumericExpression.format(values[band.qIndex], maxFractionDigits: 2))")
        return parts.joined(separator: ", ")
    }

    /// An element over the band's dot, for VoiceOver: adjusting it raises
    /// or lowers the gain (a cut's frequency), and actions move the rest.
    private func accessibleNode(_ band: EqualizerBand, layout: EqualizerGraphLayout) -> some View {
        let point = point(of: band, layout: layout)
        return Color.clear
            .frame(width: 16, height: 16)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(band.name)
            .accessibilityValue(description(of: band))
            .accessibilityAdjustableAction { direction in
                let step: Double = direction == .increment ? 1 : -1
                if band.hasGain { nudge(band, gain: step) } else { nudge(band, frequency: step) }
            }
            .accessibilityAction(named: isOn(band) ? "Switch off" : "Switch on") {
                onEdit(band.controlKind) { $0.enabled.toggle() }
            }
            .accessibilityAction(named: "Raise frequency") { nudge(band, frequency: 1) }
            .accessibilityAction(named: "Lower frequency") { nudge(band, frequency: -1) }
            .accessibilityAction(named: "Narrower") { nudge(band, q: 1) }
            .accessibilityAction(named: "Wider") { nudge(band, q: -1) }
    }

    // MARK: Drawing

    /// The spectrum from its floor at the bottom to 0 dBFS at the top, each
    /// point the loudest bin under it.
    private func drawSpectrum(in context: inout GraphicsContext, layout: EqualizerGraphLayout) {
        let levels = spectrum.decibels, width = spectrum.binWidth
        guard !levels.isEmpty, width > 0 else { return }
        let plot = layout.plot
        let floor = SpectrumBallistics.floor
        func y(_ decibels: Float) -> CGFloat {
            plot.maxY - CGFloat((max(decibels, floor) - floor) / -floor) * plot.height
        }
        let step: CGFloat = 2
        var path = Path()
        path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        var x = plot.minX
        while x <= plot.maxX {
            let last = levels.count - 1
            let low = min(max(1, Int(layout.frequency(atX: x) / width)), last)
            let high = max(low, min(Int(layout.frequency(atX: x + step) / width), last))
            let loudest = levels[low...high].max() ?? floor
            path.addLine(to: CGPoint(x: x, y: y(loudest)))
            x += step
        }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.closeSubpath()
        var clipped = context
        clipped.clip(to: Path(plot))
        clipped.fill(path, with: .color(Design.accent.opacity(0.18)))
    }

    private func draw(in context: inout GraphicsContext, layout: EqualizerGraphLayout) {
        let plot = layout.plot
        let grid = Color.white.opacity(0.08)
        for frequency in [50.0, 100, 200, 500, 1000, 2000, 5000, 10_000] {
            let x = layout.x(frequency)
            context.fill(Path(CGRect(x: x, y: plot.minY, width: 0.5, height: plot.height)), with: .color(grid))
            context.draw(
                Text(EqualizerGraphLayout.frequencyLabel(frequency)).font(Design.Typeface.numericScale).foregroundStyle(Design.textTertiary),
                at: CGPoint(x: x, y: plot.maxY + 2), anchor: .top
            )
        }
        for decibels in [-24.0, -12, 0, 12, 24] {
            let y = layout.y(decibels)
            context.fill(Path(CGRect(x: plot.minX, y: y, width: plot.width, height: decibels == 0 ? 1 : 0.5)),
                         with: .color(decibels == 0 ? Color.white.opacity(0.2) : grid))
            context.draw(
                Text(NumericExpression.format(decibels, maxFractionDigits: 0)).font(Design.Typeface.numericScale).foregroundStyle(Design.textTertiary),
                at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing
            )
        }

        let settings = Equalizer.settings(of: effect, at: time)
        var plotted = context
        plotted.clip(to: Path(plot))
        let steps = max(Int(plot.width / 2), 64)
        func curve(_ response: (Double) -> Double) -> Path {
            Path { path in
                for step in 0...steps {
                    let x = plot.minX + plot.width * CGFloat(step) / CGFloat(steps)
                    let decibels = min(max(response(layout.frequency(atX: x)), -60), 60)
                    let point = CGPoint(x: x, y: layout.y(decibels))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
        }
        for setting in settings.bands {
            let line = curve { Equalizer.response(of: setting, at: $0) }
            var filled = line
            filled.addLine(to: CGPoint(x: plot.maxX, y: layout.y(0)))
            filled.addLine(to: CGPoint(x: plot.minX, y: layout.y(0)))
            filled.closeSubpath()
            let color = Self.color(of: setting.band)
            plotted.fill(filled, with: .color(color.opacity(0.1)))
            plotted.stroke(line, with: .color(color.opacity(0.55)), lineWidth: 1)
        }
        plotted.stroke(curve { Equalizer.response(of: settings, at: $0) }, with: .color(Design.textPrimary), lineWidth: 2)

        for band in bands {
            let center = point(of: band, layout: layout)
            let color = Self.color(of: band)
            let dot = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            if isOn(band) {
                context.fill(dot, with: .color(color))
            } else {
                context.stroke(dot, with: .color(color.opacity(0.6)), lineWidth: 1)
            }
            if band == picked || band == drag?.band {
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)),
                               with: .color(isFocused ? Design.accent : Design.textSecondary), lineWidth: 1.5)
            }
        }
    }
}

extension Effect {
    /// The effect with `change` made to its control of `kind`, if it has one.
    func changing(_ kind: ControlKind, _ change: (inout EffectControl) -> Void) -> Effect {
        var copy = self
        if let index = copy.controls.firstIndex(where: { $0.kind == kind }) { change(&copy.controls[index]) }
        return copy
    }
}
