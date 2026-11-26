import CoreGraphics
import CoreMedia
import Foundation

// The Waveform effect (see docs/waveform-effect.md): a sound's wave or
// spectrum drawn over the picture, along a line or round a ring, as lines,
// dots or bars, moving with the sound as it plays. Its settings are
// ordinary controls; what it listens to is the effect's `listensTo`, as
// Audio Keys' is its setup's; and the sound itself is read while drawing
// (`WaveformAudio`), from a description of what it hears made when the
// timeline is built (`WaveformSound`).

/// What a Waveform draws.
enum WaveformMode: String, CaseIterable, Identifiable, Sendable {
    /// The sound's samples over a window of time.
    case wave
    /// How loud each frequency is at the frame's time, low to high.
    case spectrum
    /// How loud the sound is, as a meter: a bar for the mix, or one a
    /// channel.
    case level
    /// The spectrum over the window before the frame's time, as a scrolling
    /// heat map: time along the shape, frequency up from it.
    case spectrogram

    var id: Self { self }

    var name: String {
        switch self {
        case .wave: "Wave"
        case .spectrum: "Spectrum"
        case .level: "Level"
        case .spectrogram: "Spectrogram"
        }
    }

    /// Whether it measures loudness in decibels, down to the Floor.
    var isMeasured: Bool { self != .wave }

    /// Whether its points are frequencies, spaced by the Scale.
    var hasFrequencies: Bool { self == .spectrum || self == .spectrogram }
}

/// How a Waveform spaces frequencies.
enum WaveformScale: String, CaseIterable, Identifiable, Sendable {
    /// By octave, as the ear hears them.
    case log
    /// By hertz, so the highs take most of the room.
    case linear

    var id: Self { self }

    var name: String {
        switch self {
        case .log: "Log"
        case .linear: "Linear"
        }
    }

    /// `count` frequencies from `low` to `high` hertz.
    func frequencies(_ count: Int, from low: Double, to high: Double) -> [Double] {
        guard count > 1 else { return [low] }
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            switch self {
            case .log: return low * pow(high / low, t)
            case .linear: return low + (high - low) * t
            }
        }
    }
}

/// What a Waveform is drawn along.
enum WaveformShape: String, CaseIterable, Identifiable, Sendable {
    /// From a start point to an end point.
    case line
    /// Round a center, from an angle through a sweep.
    case radial

    var id: Self { self }

    var name: String {
        switch self {
        case .line: "Line"
        case .radial: "Radial"
        }
    }
}

/// Which way a Waveform rises off its baseline.
enum WaveformSide: String, CaseIterable, Identifiable, Sendable {
    /// Up off a line, out of a ring.
    case one
    /// Down off a line, into a ring.
    case other
    /// Both ways, mirrored.
    case both

    var id: Self { self }

    var name: String {
        switch self {
        case .one: "Up or Out"
        case .other: "Down or In"
        case .both: "Mirrored"
        }
    }
}

/// The kinds of graph a Waveform draws, each a setting of its Mode, Draw,
/// Shape, Stereo and Fill to Baseline, picked at once from the top of its
/// inspector group (`WaveformGraphPicker`). The settings stay as they
/// are, to change one by one after.
enum WaveformGraph: String, CaseIterable, Identifiable, Sendable {
    /// The sound's wave as a line.
    case wave
    /// The wave as a line filled down to its baseline.
    case filled
    /// The wave's envelope filled, with no line: a mountain.
    case area
    /// The wave as dots.
    case dots
    /// The spectrum as bars.
    case bars
    /// The wave round a circle.
    case ring
    /// The spectrum as rays out of a ring.
    case rays
    /// The spectrum as dots flying out of a ring.
    case particles
    /// Left against right, as an oscilloscope draws stereo.
    case scope
    /// How loud it is, as a meter.
    case meter
    /// The spectrum over time, as a scrolling heat map.
    case spectrogram

    var id: Self { self }

    var name: String {
        switch self {
        case .wave: "Wave"
        case .filled: "Filled"
        case .area: "Area"
        case .dots: "Dots"
        case .bars: "Bars"
        case .ring: "Ring"
        case .rays: "Rays"
        case .particles: "Particles"
        case .scope: "Scope"
        case .meter: "Meter"
        case .spectrogram: "Spectrogram"
        }
    }

    /// The choices it sets.
    private var settings: [(ControlKind, String)] {
        let fills = (ControlKind.waveFillsToBaseline, (self == .filled ? OnOff.on : .off).rawValue)
        func set(_ mode: WaveformMode, _ draw: WaveformDraw?, _ shape: WaveformShape?) -> [(ControlKind, String)] {
            [(.waveMode, mode.rawValue)] + (draw.map { [(.waveDraw, $0.rawValue)] } ?? []) + (shape.map { [(.waveShape, $0.rawValue)] } ?? [])
        }
        switch self {
        case .wave, .filled: return set(.wave, .lines, .line) + [fills]
        case .area: return set(.wave, .area, .line)
        case .dots: return set(.wave, .dots, .line)
        case .bars: return set(.spectrum, .bars, .line)
        case .ring: return set(.wave, .lines, .radial) + [fills]
        case .rays: return set(.spectrum, .rays, .radial)
        case .particles: return set(.spectrum, .particles, .radial)
        case .scope: return set(.wave, .lines, nil) + [(.waveStereo, WaveformStereo.xy.rawValue)]
        case .meter: return set(.level, nil, .line)
        case .spectrogram: return set(.spectrogram, nil, .line)
        }
    }

    /// The graph `effect` is set up as, if it is one of these.
    static func current(of effect: Effect) -> WaveformGraph? {
        allCases.first { $0.matches(effect) }
    }

    private func matches(_ effect: Effect) -> Bool {
        func picked(_ kind: ControlKind) -> String? { effect.control(kind)?.choice ?? kind.defaultChoice }
        // Only Scope draws left against right.
        guard (picked(.waveStereo) == WaveformStereo.xy.rawValue) == (self == .scope) else { return false }
        return settings.allSatisfy { picked($0.0) == $0.1 }
    }

    /// Sets `effect` up as this graph: its choices, and Stereo off X–Y for
    /// any other.
    func apply(to effect: inout Effect) {
        for (kind, choice) in settings {
            effect.changeControl(kind) { $0.choice = choice; $0.enabled = true }
        }
        if self != .scope, effect.choice(.waveStereo, as: WaveformStereo.self) == .xy {
            effect.changeControl(.waveStereo) { $0.choice = WaveformStereo.mixed.rawValue }
        }
        // A heat map of a few hundredths of a second shows nothing moving.
        if self == .spectrogram, let window = effect.control(.waveWindow)?.values(at: .zero).first, window < 500 {
            effect.changeControl(.waveWindow) { $0.number = AnimatedValue(ComponentValue(values: [3000])) }
        }
    }
}

/// How a Waveform's points are drawn.
enum WaveformDraw: String, CaseIterable, Identifiable, Sendable {
    /// The points joined by a line.
    case lines
    /// The space between the points and the baseline filled, with no line:
    /// a mountain.
    case area
    case dots
    case bars
    /// A thin line from the baseline to each point, in the Stroke.
    case rays
    /// Dots along the way from the baseline to each point, growing and
    /// fading in toward it.
    case particles

    var id: Self { self }

    var name: String {
        switch self {
        case .lines: "Lines"
        case .area: "Area"
        case .dots: "Dots"
        case .bars: "Bars"
        case .rays: "Rays"
        case .particles: "Particles"
        }
    }
}

/// How a Waveform shows two channels.
enum WaveformStereo: String, CaseIterable, Identifiable, Sendable {
    /// One wave of both channels.
    case mixed
    /// Left on one side of the baseline, right on the other.
    case split
    /// A wave for each channel along the same baseline.
    case two
    /// Left against right as a figure, as a vectorscope draws it.
    case xy

    var id: Self { self }

    var name: String {
        switch self {
        case .mixed: "Mixed"
        case .split: "Split"
        case .two: "Two"
        case .xy: "X–Y"
        }
    }
}

/// Where the frame's time is in a Waveform's window.
enum WaveformAlign: String, CaseIterable, Identifiable, Sendable {
    case start, middle, end

    var id: Self { self }

    var name: String {
        switch self {
        case .start: "Start"
        case .middle: "Middle"
        case .end: "End"
        }
    }

    /// How much of the window lies before the frame's time.
    var before: Double {
        switch self {
        case .start: 0
        case .middle: 0.5
        case .end: 1
        }
    }
}

/// How a Waveform's bars end.
enum WaveformEnds: String, CaseIterable, Identifiable, Sendable {
    case square, round

    var id: Self { self }

    var name: String {
        switch self {
        case .square: "Square"
        case .round: "Round"
        }
    }
}

/// How a Waveform is colored.
enum WaveformColoring: String, CaseIterable, Identifiable, Sendable {
    /// In its Fill and Stroke, one color each or a gradient laid over it.
    case paint
    /// Each point, dot or bar in the color its Fill's gradient has at how
    /// far it reaches.
    case byLevel

    var id: Self { self }

    var name: String {
        switch self {
        case .paint: "Fill and Stroke"
        case .byLevel: "By Level"
        }
    }
}

/// A Waveform's settings at one moment, ready to draw.
struct WaveformSetup: Equatable, Sendable {
    var mode = WaveformMode.wave
    /// The frequencies shown in Spectrum, in hertz.
    var lowFrequency = 20.0
    var highFrequency = 20_000.0
    var scale = WaveformScale.log
    /// The quietest level shown, in decibels, in the measured modes.
    var floor = -80.0
    var shape = WaveformShape.line
    /// The line's ends, or the ring's center, in the frame's pixels.
    var start = CGPoint.zero
    var end = CGPoint.zero
    var center = CGPoint.zero
    var radius = 200.0
    /// Degrees, clockwise from straight up.
    var angle = 0.0
    var sweep = 360.0
    var side = WaveformSide.one
    var samples = 256
    /// Pixels between points along the shape, which then decides how many
    /// there are; 0 leaves it to `samples`.
    var spacing = 0.0
    /// Seconds of sound the points span, in Wave; the history shown, in
    /// Spectrogram.
    var window = 0.05
    var align = WaveformAlign.middle
    var draw = WaveformDraw.lines
    var smooth = true
    var fillsToBaseline = false
    var dotSize = 4.0
    /// A share of the spacing between points.
    var barWidth = 0.6
    var barEnds = WaveformEnds.square
    var stereo = WaveformStereo.mixed
    /// Pixels a full-scale sample reaches from the baseline.
    var height = 100.0
    /// Decibels before it.
    var gain = 0.0
    /// Seconds over which a point falls back, in Spectrum and Level.
    var release = 0.0
    /// Seconds over which a point rises, in Spectrum and Level.
    var attack = 0.0
    /// Seconds a peak's marker stays before it falls, in Spectrum and
    /// Level; 0 draws none.
    var peakHold = 0.0
    /// Seconds over which Wave's points are averaged with the moments
    /// before, so the line settles rather than jumps.
    var timeSmoothing = 0.0
    var coloring = WaveformColoring.paint
    var fill: [Double]?
    var fillGradient: GradientFill?
    var stroke: [Double]?
    var strokeGradient: GradientFill?
    var lineWidth = 3.0
    var rightColor = [0.4, 0.8, 1, 1]

    /// A Waveform effect's settings at source time `time`, with points
    /// measured from `center` (the middle of the frame). Nil for another
    /// kind, or one that is off.
    init?(_ effect: Effect, at time: CMTime, center frame: CGPoint) {
        guard effect.kind == .waveform, effect.enabled else { return nil }
        func control(_ kind: ControlKind) -> EffectControl? { effect.control(kind).flatMap { $0.enabled ? $0 : nil } }
        func values(_ kind: ControlKind) -> [Double] { control(kind)?.values(at: time) ?? kind.defaultValues }
        func single(_ kind: ControlKind) -> Double { values(kind).first ?? 0 }
        func point(_ kind: ControlKind) -> CGPoint {
            let v = values(kind)
            return v.count == 2 ? CGPoint(x: frame.x + v[0], y: frame.y + v[1]) : frame
        }
        func choice<Option: RawRepresentable>(_ kind: ControlKind, _ fallback: Option) -> Option where Option.RawValue == String {
            effect.choice(kind, as: Option.self) ?? fallback
        }
        mode = choice(.waveMode, .wave)
        scale = choice(.waveScale, .log)
        floor = min(single(.waveFloor), -1)
        let frequencies = values(.waveFrequencies)
        if frequencies.count == 2 { (lowFrequency, highFrequency) = (min(frequencies[0], frequencies[1]), max(frequencies[0], frequencies[1])) }
        shape = choice(.waveShape, .line)
        start = point(.waveStart)
        end = point(.waveEnd)
        center = point(.waveCenter)
        radius = max(single(.waveRadius), 0)
        angle = single(.waveAngle)
        sweep = single(.waveSweep).clamped(between: -360, and: 360)
        side = choice(.waveSide, .one)
        samples = Int(single(.waveSamples)).clamped(between: 2, and: 4096)
        spacing = max(single(.waveSpacing), 0)
        window = max(single(.waveWindow), 0.1) / 1000
        align = choice(.waveAlign, .middle)
        draw = choice(.waveDraw, .lines)
        smooth = effect.choice(.waveSmooth, as: OnOff.self) != .off
        fillsToBaseline = effect.choice(.waveFillsToBaseline, as: OnOff.self) == .on
        dotSize = max(single(.dotSize), 0)
        barWidth = (single(.barWidth) / 100).clamped(between: 0.01, and: 1)
        barEnds = choice(.barEnds, .square)
        stereo = choice(.waveStereo, .mixed)
        height = single(.waveHeight)
        gain = single(.waveGain)
        release = max(single(.waveRelease), 0) / 1000
        attack = max(single(.waveAttack), 0) / 1000
        peakHold = max(single(.wavePeakHold), 0) / 1000
        timeSmoothing = max(single(.waveTimeSmoothing), 0) / 1000
        coloring = choice(.waveColoring, .paint)
        if let fillControl = control(.fill) {
            if let gradient = fillControl.gradient(at: time), let style = fillControl.paint {
                fillGradient = GradientFill(gradient: gradient, style: style)
            }
            fill = fillControl.solidColor(at: time).map { $0.clamped(between: 0, and: 1) }
        }
        if let strokeControl = control(.stroke) {
            if let gradient = strokeControl.gradient(at: time), let style = strokeControl.paint {
                strokeGradient = GradientFill(gradient: gradient, style: style)
            }
            stroke = strokeControl.solidColor(at: time).map { $0.clamped(between: 0, and: 1) }
        }
        lineWidth = control(.strokeWidth) == nil ? 0 : max(single(.strokeWidth), 0)
        let right = values(.rightColor)
        if right.count == 4 { rightColor = right.map { $0.clamped(between: 0, and: 1) } }
    }

    /// What it draws, in words, for a render's key.
    var keyText: String {
        func n(_ value: Double) -> String { String(format: "%.4f", value) }
        func p(_ point: CGPoint) -> String { "\(n(point.x)),\(n(point.y))" }
        var text = "w \(mode.rawValue) \(n(lowFrequency))-\(n(highFrequency)) \(shape.rawValue) \(p(start)) \(p(end)) \(p(center))"
        text += " \(n(radius)) \(n(angle)) \(n(sweep)) \(side.rawValue) \(samples) \(n(window)) \(align.rawValue) \(draw.rawValue)"
        text += " \(smooth) \(fillsToBaseline) \(n(dotSize)) \(n(barWidth)) \(barEnds.rawValue) \(stereo.rawValue)"
        text += " \(n(height)) \(n(gain)) \(n(release)) \(coloring.rawValue) \(lineWidth)"
        text += " \(scale.rawValue) \(n(floor)) \(n(spacing)) \(n(attack)) \(n(peakHold)) \(n(timeSmoothing))"
        text += " f" + (fillGradient?.keyText ?? (fill ?? []).map(n).joined(separator: ","))
        text += " s" + (strokeGradient?.keyText ?? (stroke ?? []).map(n).joined(separator: ","))
        text += " r" + rightColor.map(n).joined(separator: ",")
        return text
    }
}

/// A Waveform's settings at one moment and the time it draws the sound at,
/// in its clip's timeline.
struct WaveformStep: Equatable, Sendable {
    var effectID: UUID
    var setup: WaveformSetup
    /// Seconds of the timeline the clip is in.
    var time: Double

    var keyText: String {
        setup.keyText + String(format: " @%.6f", time)
    }
}

/// What a Waveform hears, made when the timeline is built: each clip with
/// sound from a file in what it listens to, with where it plays and how
/// loud, so drawing needs nothing from the project.
struct WaveformSound: @unchecked Sendable {
    struct Source {
        var url: URL
        var clip: TimelineClip
        var asset: MediaClip
        /// The volume of the Sound or Music layer it is on, if it is on one.
        var layerVolume: AnimatedValue<Double>?
    }

    var sources: [Source]
    /// What it hears, for a render's key: the files and every clip's
    /// placement and volume.
    var fingerprint: UInt64

    /// The files it reads.
    var urls: [URL] { Array(Set(sources.map(\.url))) }
}

extension EditingProject {
    /// What each Waveform effect of `clip` hears in `timeline`, by effect.
    /// Empty for a clip with none.
    func waveformSounds(for clip: TimelineClip, in timeline: Timeline) -> [UUID: WaveformSound] {
        var sounds: [UUID: WaveformSound] = [:]
        for effect in clip.effects where effect.kind == .waveform {
            let heard = heardClips(effect.listensTo ?? .mix, in: timeline)
            var prints = KeyframingPrint()
            let sources = heard.map { heard in
                prints.add(heard.url.path)
                for time in [heard.clip.startOffset, heard.clip.trimStart, heard.clip.trimEnd] { prints.add(time) }
                prints.add(heard.clip.time.speed)
                prints.add(heard.clip.volume)
                if heard.layer.kind.isAudio { prints.add(heard.layer.volume) }
                return WaveformSound.Source(
                    url: heard.url, clip: heard.clip, asset: heard.asset, layerVolume: heard.layer.kind.isAudio ? heard.layer.volume : nil
                )
            }
            sounds[effect.id] = WaveformSound(sources: sources, fingerprint: prints.value)
        }
        return sounds
    }
}

extension Effect {
    /// Whether the inspector lists a setting of a Waveform as it is set
    /// now: those of its shape, its mode and how it draws, and the right
    /// channel's color only with Stereo set to Two. Every setting of any
    /// other effect.
    func waveformShows(_ control: ControlKind) -> Bool {
        guard kind == .waveform else { return true }
        let shape = choice(.waveShape, as: WaveformShape.self) ?? .line
        let mode = choice(.waveMode, as: WaveformMode.self) ?? .wave
        // Level is drawn as meters, Spectrogram as a heat map, whatever
        // Draw says.
        let draw: WaveformDraw? = switch mode {
        case .wave, .spectrum: choice(.waveDraw, as: WaveformDraw.self) ?? .lines
        case .level: .bars
        case .spectrogram: nil
        }
        switch control {
        case .waveStart, .waveEnd: return shape == .line
        case .waveCenter, .waveRadius, .waveAngle, .waveSweep: return shape == .radial
        case .waveWindow: return mode == .wave || mode == .spectrogram
        case .waveAlign, .waveTimeSmoothing: return mode == .wave
        case .waveFrequencies, .waveScale: return mode.hasFrequencies
        case .waveFloor: return mode.isMeasured
        case .waveRelease, .waveAttack, .wavePeakHold: return mode == .spectrum || mode == .level
        case .waveSamples: return mode != .level
        case .waveSpacing: return mode == .wave || mode == .spectrum
        case .waveDraw: return mode == .wave || mode == .spectrum
        case .waveColoring: return mode != .spectrogram
        case .waveSmooth: return draw == .lines || draw == .area
        case .waveFillsToBaseline: return draw == .lines
        case .dotSize: return draw == .dots || draw == .particles
        case .barWidth, .barEnds: return draw == .bars
        case .rightColor: return mode != .spectrogram && [.split, .two].contains(choice(.waveStereo, as: WaveformStereo.self) ?? .mixed)
        default: return true
        }
    }
}
