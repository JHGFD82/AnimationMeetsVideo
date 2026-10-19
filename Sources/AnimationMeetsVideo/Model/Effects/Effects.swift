import CoreGraphics
import CoreMedia
import Foundation

// The model behind effect stacks (see docs/effects.md). A visual clip holds
// an ordered list of effects, each an ordered list of controls, and the
// renderer applies them top to bottom. Everything starts as a no-op: a
// control at its default changes nothing.

/// How a Blending step combines the clip with what it is blended against.
enum BlendMode: String, CaseIterable, Identifiable, Sendable {
    case normal, darken, multiply, colorBurn, linearBurn
    case lighten, screen, colorDodge, add
    case overlay, softLight, hardLight
    case difference, exclusion, subtract, divide
    case hue, saturation, color, luminosity

    var id: Self { self }

    var name: String {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .linearBurn: "Linear Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .add: "Add"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .subtract: "Subtract"
        case .divide: "Divide"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }
}

/// A group of effects in the library.
enum EffectCategory: String, CaseIterable, Identifiable, Sendable {
    case foundations
    case shapes
    case mattes
    /// Remaps the picture's colors (see docs/psychedelic-effects.md).
    case recolor
    /// Effects that draw nothing and write keyframes onto other controls
    /// instead (see docs/keyframing-effects.md).
    case keyframing
    case sound

    var id: Self { self }

    var name: String {
        switch self {
        case .foundations: "Foundations"
        case .shapes: "Shapes"
        case .mattes: "Mattes"
        case .recolor: "Color"
        case .keyframing: "Keyframing"
        case .sound: "Sound"
        }
    }
}

/// What a Matte takes from its picture to cut the clip with.
enum MatteMode: String, CaseIterable, Identifiable, Sendable {
    /// The clip shows where the picture is opaque.
    case alpha
    /// The clip shows where the picture is bright.
    case luma
    case invertedAlpha
    case invertedLuma

    var id: Self { self }

    var name: String {
        switch self {
        case .alpha: "Alpha"
        case .luma: "Luma"
        case .invertedAlpha: "Inverted Alpha"
        case .invertedLuma: "Inverted Luma"
        }
    }

    var usesLuma: Bool { self == .luma || self == .invertedLuma }
    var isInverted: Bool { self == .invertedAlpha || self == .invertedLuma }
}

/// A picture an effect takes besides the clip's: it comes from the browser,
/// not the timeline, so it takes up no layer and belongs to the clip, as
/// part of the effect's step. See docs/effects.md, "Inputs".
struct EffectInput: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case asset(UUID)
        case timeline(UUID)
    }

    var source: Source
    /// Where in the input it is when the clip starts. A moving input plays
    /// from the start of the clip.
    var offset = CMTime.zero
    /// Whether it plays again from its start at its end, rather than holding
    /// its last frame.
    var loops = false
}

/// The kinds of effect the library offers. Sound effects (see
/// docs/audio.md, "Sound effects") go in a clip's `audioEffects` and play
/// through the EQ's own filters or Apple's Audio Units; the rest change
/// its picture.
enum EffectKind: String, CaseIterable, Identifiable, Sendable {
    case transform
    case blending
    case color
    case matte
    /// Color looks (see docs/psychedelic-effects.md): each remaps every
    /// pixel's color on its own, and nothing moves.
    case hueCycle, cosinePalette, gradientMap, solarize, posterize, channelMixer, falseColor, neonEdges
    /// Shapes draw over the picture handed down to them (see
    /// docs/graphic-layers.md, "Shapes").
    case rectangle
    case ellipse
    case polygon
    case star
    /// Strokes the outline of the shapes above it in the stack, strokes and
    /// all, so a stroke can have a stroke of its own.
    case stroke
    case equalizer
    case compressor
    case limiter
    case voiceIsolation
    /// Keyframing effects (see docs/keyframing-effects.md): each writes
    /// keyframes onto a control below it, and draws nothing.
    case audioKeys
    case beatKeys
    case wiggler
    case oscillator
    case smoother
    case looper
    case timeStep
    case overshoot

    var id: Self { self }

    var name: String {
        switch self {
        case .transform: "Transform"
        case .blending: "Blending"
        case .color: "Color"
        case .matte: "Matte"
        case .hueCycle: "Hue Cycle"
        case .cosinePalette: "Cosine Palette"
        case .gradientMap: "Gradient Map"
        case .solarize: "Solarize"
        case .posterize: "Posterize"
        case .channelMixer: "Channel Mixer"
        case .falseColor: "False Color"
        case .neonEdges: "Neon Edges"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .polygon: "Polygon"
        case .star: "Star"
        case .stroke: "Stroke"
        case .equalizer: "EQ"
        case .compressor: "Compressor"
        case .limiter: "Limiter"
        case .voiceIsolation: "Voice Isolation"
        case .audioKeys: "Audio Keys"
        case .beatKeys: "Beat Keys"
        case .wiggler: "Wiggler"
        case .oscillator: "Oscillator"
        case .smoother: "Smoother"
        case .looper: "Looper"
        case .timeStep: "Time Step"
        case .overshoot: "Overshoot"
        }
    }

    var category: EffectCategory {
        switch self {
        case .transform, .blending, .color: .foundations
        case .rectangle, .ellipse, .polygon, .star, .stroke: .shapes
        case .matte: .mattes
        case .hueCycle, .cosinePalette, .gradientMap, .solarize, .posterize, .channelMixer, .falseColor, .neonEdges: .recolor
        case .equalizer, .compressor, .limiter, .voiceIsolation: .sound
        case .audioKeys, .beatKeys, .wiggler, .oscillator, .smoother, .looper, .timeStep, .overshoot: .keyframing
        }
    }

    /// Whether it works on the clip's sound rather than its picture.
    var isAudio: Bool { category == .sound }

    /// Whether it writes keyframes onto another control rather than
    /// changing the picture or the sound.
    var isKeyframing: Bool { category == .keyframing }

    /// For a Keyframing effect: whether it reshapes the target's own
    /// keyframes, rather than making a signal combined with them.
    var reshapesTarget: Bool {
        switch self {
        case .smoother, .looper, .timeStep, .overshoot: true
        default: false
        }
    }

    /// Whether it is one of the shapes, or strokes them.
    var isShape: Bool { category == .shapes }

    /// Whether it draws a shape of its own, rather than stroking others.
    var drawsShape: Bool { isShape && self != .stroke }

    var systemImage: String {
        switch self {
        case .transform: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .blending: "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .color: "slider.horizontal.3"
        case .matte: "circle.dashed.inset.filled"
        case .hueCycle: "paintpalette"
        case .cosinePalette: "rainbow"
        case .gradientMap: "slider.horizontal.below.rectangle"
        case .solarize: "sun.max.trianglebadge.exclamationmark"
        case .posterize: "square.stack.3d.down.forward"
        case .channelMixer: "circle.grid.cross"
        case .falseColor: "thermometer.sun"
        case .neonEdges: "scribble"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .polygon: "hexagon"
        case .star: "star"
        case .stroke: "circle.dashed"
        case .equalizer: "slider.vertical.3"
        case .compressor: "arrow.down.right.and.arrow.up.left"
        case .limiter: "line.horizontal.star.fill.line.horizontal"
        case .voiceIsolation: "person.wave.2"
        case .audioKeys: "waveform.badge.magnifyingglass"
        case .beatKeys: "metronome"
        case .wiggler: "scribble.variable"
        case .oscillator: "waveform.path"
        case .smoother: "point.topleft.down.to.point.bottomright.curvepath"
        case .looper: "repeat"
        case .timeStep: "stairs"
        case .overshoot: "arrowshape.bounce.right"
        }
    }

    /// Whether the effect takes a picture dragged from the browser.
    var takesInput: Bool { self == .matte }

    /// Whether the picture it makes depends on the size it is drawn at, so a
    /// nested timeline holding it can't have its move pushed into its
    /// layers (a blur whose radius is in pixels, say). Effects that work on
    /// single pixels, or move them, don't, and shapes are drawn at the size
    /// they end up.
    var dependsOnPixelSize: Bool {
        switch self {
        case .transform, .blending, .color, .matte, .rectangle, .ellipse, .polygon, .star, .stroke,
             .equalizer, .compressor, .limiter, .voiceIsolation: false
        case .audioKeys, .beatKeys, .wiggler, .oscillator, .smoother, .looper, .timeStep, .overshoot: false
        case .hueCycle, .cosinePalette, .gradientMap, .solarize, .posterize, .channelMixer, .falseColor: false
        // Its edges are found between neighboring pixels.
        case .neonEdges: true
        }
    }

    /// Whether it is one of the looks of docs/psychedelic-effects.md,
    /// which are drawn as a `.look` step.
    var isLook: Bool { category == .recolor }

    /// How a shape is filled and stroked, after what shapes it.
    static let paintControls: [ControlKind] = [.fill, .stroke, .strokeWidth, .strokeEdge, .strokeJoin, .strokeCap, .dash]

    /// The controls a new effect of this kind lists, in order.
    var controlKinds: [ControlKind] {
        switch self {
        case .transform: [.position, .scale, .rotation, .opacity]
        case .blending: [.mode, .amount]
        case .color: [.exposure, .contrast, .saturation, .temperature, .tint, .lift, .gamma, .gain]
        case .matte: [.matteMode, .amount]
        case .rectangle: [.shapeSize, .cornerRadius, .shapePosition] + Self.paintControls
        case .ellipse: [.shapeSize, .shapePosition] + Self.paintControls
        case .polygon: [.points, .radius, .cornerRadius, .shapeRotation, .shapePosition] + Self.paintControls
        case .star: [.points, .radius, .innerRadius, .cornerRadius, .shapeRotation, .shapePosition] + Self.paintControls
        case .stroke: [.stroke, .strokeWidth, .strokeEdge, .strokeJoin, .strokeCap, .dash]
        case .equalizer: Equalizer.controlKinds
        case .compressor: [.threshold, .headroom, .attack, .release, .makeup]
        case .limiter: [.drive, .limiterRelease]
        case .voiceIsolation: [.isolation]
        case .audioKeys: [.frequencyRange, .levelRange, .keyAttack, .keyRelease, .outputRange, .keyCurve, .tolerance]
        case .beatKeys: [.beatSelection, .everyBeats, .beatOffset, .accent, .beatShape, .peak, .decay, .tolerance]
        case .wiggler: [.wiggleFrequency, .magnitude, .wiggleType, .octaves, .wiggleDimensions, .seed, .tolerance]
        case .oscillator: [.wave, .oscillatorFrequency, .amplitude, .phase, .fade, .tolerance]
        case .smoother: [.smoothing, .tolerance]
        case .looper: [.loopMode, .loopSide, .tolerance]
        case .timeStep: [.hold]
        case .overshoot: [.stiffness, .damping, .mass, .tolerance]
        case .hueCycle: [.hueSpeed, .hueSpread, .saturationBoost, .amount]
        case .cosinePalette: [.palette, .cycleSpeed, .paletteBias, .paletteAmplitude, .paletteFrequency, .palettePhase, .amount]
        case .gradientMap: [.shadowColor, .midtoneColor, .highlightColor, .repeats, .scrollSpeed, .amount]
        case .solarize: [.solarizeLevel, .folds, .solarizeChannels, .amount]
        case .posterize: [.levels, .amount]
        case .channelMixer: [.mixRed, .mixGreen, .mixBlue, .mixOffset, .amount]
        case .falseColor: [.falseColorLook, .shadowColor, .highlightColor, .amount]
        case .neonEdges: [.edgeWidth, .glow, .edgeColoring, .edgeColor, .amount]
        }
    }
}

/// One control of an effect. Each is a step of its own.
enum ControlKind: String, CaseIterable, Identifiable, Sendable {
    case position, scale, rotation, opacity
    case mode, amount
    case exposure, contrast, saturation, temperature, tint, lift, gamma, gain
    case matteMode
    case shapeSize, cornerRadius, shapePosition, fill, stroke, strokeWidth
    case strokeEdge, strokeJoin, strokeCap, dash
    case points, radius, innerRadius, shapeRotation
    /// The EQ's bands (see `EqualizerBand`), its cuts' slopes and its
    /// output gain.
    case eqLowCut, eqLowCutSlope, eqLowShelf, eqBell1, eqBell2, eqBell3, eqBell4
    case eqHighShelf, eqHighCut, eqHighCutSlope, eqOutput
    case threshold, headroom, attack, release, makeup
    case drive, limiterRelease
    case isolation
    /// Keyframing effects' settings (see `EffectKind.isKeyframing`).
    case beatSelection, everyBeats, beatOffset, accent, beatShape, peak, decay
    case wiggleFrequency, magnitude, wiggleType, octaves, wiggleDimensions, seed
    case wave, oscillatorFrequency, amplitude, phase, fade
    case smoothing, loopMode, loopSide, hold, stiffness, damping, mass
    case frequencyRange, levelRange, keyAttack, keyRelease, outputRange, keyCurve
    case tolerance
    /// The Color looks' settings (see `EffectKind.isLook`).
    case hueSpeed, hueSpread, saturationBoost
    case palette, cycleSpeed, paletteBias, paletteAmplitude, paletteFrequency, palettePhase
    case shadowColor, midtoneColor, highlightColor, repeats, scrollSpeed
    case solarizeLevel, folds, solarizeChannels, levels
    case mixRed, mixGreen, mixBlue, mixOffset
    case falseColorLook, edgeWidth, glow, edgeColoring, edgeColor

    var id: Self { self }

    var name: String {
        switch self {
        case .position: "Position"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        case .mode: "Mode"
        case .matteMode: "Take"
        case .amount: "Amount"
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .lift: "Lift"
        case .gamma: "Gamma"
        case .gain: "Gain"
        case .shapeSize: "Size"
        case .cornerRadius: "Corners"
        case .shapePosition: "Position"
        case .fill: "Fill"
        case .stroke: "Stroke"
        case .strokeWidth: "Stroke Width"
        case .strokeEdge: "Edge"
        case .strokeJoin: "Join"
        case .strokeCap: "Cap"
        case .dash: "Dash"
        case .points: "Points"
        case .radius: "Radius"
        case .innerRadius: "Inner Radius"
        case .shapeRotation: "Rotation"
        case .eqLowCut, .eqLowShelf, .eqBell1, .eqBell2, .eqBell3, .eqBell4, .eqHighShelf, .eqHighCut:
            EqualizerBand(controlKind: self)?.name ?? ""
        case .eqLowCutSlope: "Low Slope"
        case .eqHighCutSlope: "High Slope"
        case .eqOutput: "Output"
        case .threshold: "Threshold"
        case .headroom: "Headroom"
        case .attack: "Attack"
        case .release, .limiterRelease: "Release"
        case .makeup: "Makeup"
        case .drive: "Drive"
        case .isolation: "Isolation"
        case .beatSelection: "Beats"
        case .everyBeats: "Every"
        case .beatOffset: "Offset"
        case .accent: "Accent"
        case .beatShape: "Shape"
        case .peak: "Peak"
        case .decay: "Decay"
        case .wiggleFrequency, .oscillatorFrequency: "Frequency"
        case .magnitude: "Magnitude"
        case .wiggleType: "Type"
        case .octaves: "Octaves"
        case .wiggleDimensions: "Dimensions"
        case .seed: "Seed"
        case .wave: "Wave"
        case .amplitude: "Amplitude"
        case .phase: "Phase"
        case .fade: "Fade"
        case .smoothing: "Strength"
        case .loopMode: "Mode"
        case .loopSide: "Repeat"
        case .hold: "Hold"
        case .stiffness: "Stiffness"
        case .damping: "Damping"
        case .mass: "Mass"
        case .frequencyRange: "Frequencies"
        case .levelRange: "Levels"
        case .keyAttack: "Attack"
        case .keyRelease: "Release"
        case .outputRange: "Output"
        case .keyCurve: "Curve"
        case .tolerance: "Tolerance"
        case .hueSpeed, .cycleSpeed, .scrollSpeed: "Speed"
        case .hueSpread: "Spread"
        case .saturationBoost: "Saturation"
        case .palette: "Palette"
        case .paletteBias: "Bias"
        case .paletteAmplitude: "Amplitude"
        case .paletteFrequency: "Frequency"
        case .palettePhase: "Phase"
        case .shadowColor: "Shadows"
        case .midtoneColor: "Midtones"
        case .highlightColor: "Highlights"
        case .repeats: "Repeat"
        case .solarizeLevel: "Threshold"
        case .folds: "Folds"
        case .solarizeChannels: "Channels"
        case .levels: "Levels"
        case .mixRed: "Red From"
        case .mixGreen: "Green From"
        case .mixBlue: "Blue From"
        case .mixOffset: "Offset"
        case .falseColorLook: "Look"
        case .edgeWidth: "Width"
        case .glow: "Glow"
        case .edgeColoring: "Coloring"
        case .edgeColor: "Color"
        }
    }

    /// The effect kind that lists the control; for one every shape lists,
    /// the rectangle.
    var effectKind: EffectKind {
        switch self {
        case .position, .scale, .rotation, .opacity: .transform
        case .mode: .blending
        case .amount: .blending
        case .matteMode: .matte
        case .exposure, .contrast, .saturation, .temperature, .tint, .lift, .gamma, .gain: .color
        case .shapeSize, .cornerRadius, .shapePosition, .fill, .stroke, .strokeWidth: .rectangle
        case .strokeEdge, .strokeJoin, .strokeCap, .dash: .rectangle
        case .points, .radius, .shapeRotation: .polygon
        case .innerRadius: .star
        case .eqLowCut, .eqLowCutSlope, .eqLowShelf, .eqBell1, .eqBell2, .eqBell3, .eqBell4,
             .eqHighShelf, .eqHighCut, .eqHighCutSlope, .eqOutput: .equalizer
        case .threshold, .headroom, .attack, .release, .makeup: .compressor
        case .drive, .limiterRelease: .limiter
        case .isolation: .voiceIsolation
        case .beatSelection, .everyBeats, .beatOffset, .accent, .beatShape, .peak, .decay: .beatKeys
        case .wiggleFrequency, .magnitude, .wiggleType, .octaves, .wiggleDimensions, .seed, .tolerance: .wiggler
        case .wave, .oscillatorFrequency, .amplitude, .phase, .fade: .oscillator
        case .smoothing: .smoother
        case .loopMode, .loopSide: .looper
        case .hold: .timeStep
        case .stiffness, .damping, .mass: .overshoot
        case .frequencyRange, .levelRange, .keyAttack, .keyRelease, .outputRange, .keyCurve: .audioKeys
        case .hueSpeed, .hueSpread, .saturationBoost: .hueCycle
        case .palette, .cycleSpeed, .paletteBias, .paletteAmplitude, .paletteFrequency, .palettePhase: .cosinePalette
        case .shadowColor, .midtoneColor, .highlightColor, .repeats, .scrollSpeed: .gradientMap
        case .solarizeLevel, .folds, .solarizeChannels: .solarize
        case .levels: .posterize
        case .mixRed, .mixGreen, .mixBlue, .mixOffset: .channelMixer
        case .falseColorLook: .falseColor
        case .edgeWidth, .glow, .edgeColoring, .edgeColor: .neonEdges
        }
    }

    /// Whether the control changes nothing at its default, so it can be
    /// shown dimmed there. A compressor's, limiter's or voice isolation's
    /// controls always matter: at their defaults they still work. So do a
    /// shape's, which draw it.
    var hasNeutralDefault: Bool {
        switch effectKind {
        case .compressor, .limiter, .voiceIsolation: false
        // A Keyframing effect's settings are what it makes keyframes from,
        // and a look's what it looks like.
        case _ where effectKind.isKeyframing || effectKind.isLook: false
        default: !effectKind.isShape
        }
    }

    /// Whether the control is a choice from a list rather than numbers.
    var isChoice: Bool { !choiceOptions.isEmpty }

    /// What a choice offers, as raw values and names; empty for numbers.
    var choiceOptions: [(id: String, name: String)] {
        switch self {
        case .mode: BlendMode.allCases.map { ($0.rawValue, $0.name) }
        case .matteMode: MatteMode.allCases.map { ($0.rawValue, $0.name) }
        case .strokeEdge: StrokeEdge.allCases.map { ($0.rawValue, $0.name) }
        case .strokeJoin: StrokeJoin.allCases.map { ($0.rawValue, $0.name) }
        case .strokeCap: StrokeCap.allCases.map { ($0.rawValue, $0.name) }
        case .eqLowCutSlope, .eqHighCutSlope: EqualizerSlope.allCases.map { ($0.rawValue, $0.name) }
        case .beatSelection: BeatSelection.allCases.map { ($0.rawValue, $0.name) }
        case .beatShape: BeatShape.allCases.map { ($0.rawValue, $0.name) }
        case .wiggleType: WiggleType.allCases.map { ($0.rawValue, $0.name) }
        case .wiggleDimensions: WiggleDimensions.allCases.map { ($0.rawValue, $0.name) }
        case .wave: OscillatorWave.allCases.map { ($0.rawValue, $0.name) }
        case .loopMode: LoopMode.allCases.map { ($0.rawValue, $0.name) }
        case .loopSide: LoopSide.allCases.map { ($0.rawValue, $0.name) }
        case .keyCurve: KeyCurve.allCases.map { ($0.rawValue, $0.name) }
        case .palette: PaletteLook.allCases.map { ($0.rawValue, $0.name) }
        case .solarizeChannels: SolarizeChannels.allCases.map { ($0.rawValue, $0.name) }
        case .falseColorLook: FalseColorLook.allCases.map { ($0.rawValue, $0.name) }
        case .edgeColoring: EdgeColoring.allCases.map { ($0.rawValue, $0.name) }
        default: []
        }
    }

    /// What a new choice control picks.
    var defaultChoice: String? {
        switch self {
        case .mode: BlendMode.normal.rawValue
        case .matteMode: MatteMode.alpha.rawValue
        case .strokeEdge: StrokeEdge.center.rawValue
        case .strokeJoin: StrokeJoin.miter.rawValue
        case .strokeCap: StrokeCap.butt.rawValue
        case .eqLowCutSlope, .eqHighCutSlope: EqualizerSlope.db12.rawValue
        case .beatSelection: BeatSelection.every.rawValue
        case .beatShape: BeatShape.pulse.rawValue
        case .wiggleType: WiggleType.smooth.rawValue
        case .wiggleDimensions: WiggleDimensions.independent.rawValue
        case .wave: OscillatorWave.sine.rawValue
        case .loopMode: LoopMode.cycle.rawValue
        case .loopSide: LoopSide.after.rawValue
        case .keyCurve: KeyCurve.linear.rawValue
        case .palette: PaletteLook.rainbow.rawValue
        case .solarizeChannels: SolarizeChannels.luminance.rawValue
        case .falseColorLook: FalseColorLook.thermal.rawValue
        case .edgeColoring: EdgeColoring.byAngle.rawValue
        default: nil
        }
    }

    /// Whether its two axes can be linked, so editing one changes the other
    /// in proportion.
    var isLinkable: Bool { self == .scale || self == .shapeSize }

    /// Whether a new control's axes are linked: a scale's are, a shape's
    /// size, whose width is usually set on its own, isn't.
    var linksByDefault: Bool { self == .scale }

    /// Whether the control is a color: red, green, blue and alpha, 0...1,
    /// as the timeline's encoded values (as a transition's dip color is).
    var isColor: Bool {
        switch self {
        case .fill, .stroke, .shadowColor, .midtoneColor, .highlightColor, .edgeColor: true
        default: false
        }
    }

    /// The names of its components, for a graph's legend.
    var componentNames: [String] {
        switch self {
        case .position: ["Δx", "Δy"]
        case .scale: ["x", "y"]
        case .mode, .matteMode: []
        case .lift, .gamma, .gain: ["All", "Red", "Green", "Blue"]
        case .shapeSize: ["Width", "Height"]
        case .shapePosition: ["Δx", "Δy"]
        case .fill, .stroke: ["Red", "Green", "Blue", "Alpha"]
        case .dash: ["Dash", "Gap"]
        case .strokeEdge, .strokeJoin, .strokeCap, .eqLowCutSlope, .eqHighCutSlope: []
        case _ where isChoice: []
        case .frequencyRange, .levelRange: ["Low", "High"]
        case .outputRange: ["From", "To"]
        case .paletteBias, .paletteAmplitude, .paletteFrequency, .palettePhase, .mixRed, .mixGreen, .mixBlue, .mixOffset:
            ["Red", "Green", "Blue"]
        case _ where isColor: ["Red", "Green", "Blue", "Alpha"]
        default: EqualizerBand(controlKind: self)?.componentNames ?? [name]
        }
    }

    /// What the control holds while it changes nothing.
    var defaultValues: [Double] {
        switch self {
        case .position: [0, 0]
        case .scale: [100, 100]
        case .rotation, .exposure, .temperature, .tint: [0]
        case .opacity, .amount, .contrast, .saturation: [100]
        case .lift: [0, 0, 0, 0]
        case .gamma, .gain: [1, 1, 1, 1]
        case .mode, .matteMode: []
        case .shapeSize: [640, 360]
        case .cornerRadius, .strokeWidth: [0]
        case .shapePosition: [0, 0]
        case .fill: [1, 1, 1, 1]
        case .stroke: [0, 0, 0, 1]
        case .strokeEdge, .strokeJoin, .strokeCap: []
        case .dash: [0, 0]
        case .points: [5]
        case .radius: [180]
        case .innerRadius: [90]
        case .shapeRotation: [0]
        case .eqLowCut, .eqLowShelf, .eqBell1, .eqBell2, .eqBell3, .eqBell4, .eqHighShelf, .eqHighCut:
            EqualizerBand(controlKind: self)?.defaultValues ?? []
        case .eqLowCutSlope, .eqHighCutSlope: []
        case .eqOutput, .makeup, .drive: [0]
        case .threshold: [-20]
        case .headroom: [5]
        case .attack: [10]
        case .release: [100]
        case .limiterRelease: [5]
        case .isolation: [100]
        case .beatSelection, .beatShape, .wiggleType, .wiggleDimensions, .wave, .loopMode, .loopSide, .keyCurve: []
        // A kick drum's range, and a gate and ceiling for a typical mix.
        case .frequencyRange: [40, 120]
        case .levelRange: [-50, -10]
        case .keyAttack: [0]
        case .keyRelease: [200]
        case .outputRange: [0, 10]
        case .everyBeats: [1]
        case .beatOffset: [0]
        case .accent: [50]
        case .peak, .magnitude, .amplitude: [10]
        case .decay: [250]
        case .wiggleFrequency: [2]
        case .octaves, .seed, .oscillatorFrequency: [1]
        case .phase, .fade: [0]
        case .smoothing: [5]
        case .hold: [2]
        case .stiffness: [200]
        case .damping: [8]
        case .mass: [1]
        case .tolerance: [0.5]
        case .palette, .solarizeChannels, .falseColorLook, .edgeColoring: []
        case .hueSpeed: [0.25]
        case .hueSpread, .saturationBoost, .cycleSpeed, .scrollSpeed: [0]
        case .paletteBias: PaletteLook.rainbow.vectors.bias
        case .paletteAmplitude: PaletteLook.rainbow.vectors.amplitude
        case .paletteFrequency: PaletteLook.rainbow.vectors.frequency
        case .palettePhase: PaletteLook.rainbow.vectors.phase
        // A lava gradient, and a navy-to-amber duotone.
        case .shadowColor: [0.08, 0.02, 0.18, 1]
        case .midtoneColor: [0.9, 0.25, 0.05, 1]
        case .highlightColor: [1, 0.92, 0.55, 1]
        case .repeats, .folds: [1]
        case .solarizeLevel: [50]
        case .levels: [6]
        case .mixRed: [1, 0, 0]
        case .mixGreen: [0, 1, 0]
        case .mixBlue: [0, 0, 1]
        case .mixOffset: [0, 0, 0]
        case .edgeWidth: [2]
        case .glow: [50]
        case .edgeColor: [0.2, 1, 0.9, 1]
        }
    }

    var unit: String {
        switch self {
        case .position, .shapeSize, .cornerRadius, .shapePosition, .strokeWidth, .dash, .radius, .innerRadius: " px"
        case .fill, .stroke, .strokeEdge, .strokeJoin, .strokeCap, .points: ""
        case .shapeRotation: "°"
        case .scale, .opacity, .amount, .contrast, .saturation, .isolation: "%"
        case .rotation: "°"
        case .exposure: " stops"
        case .mode, .matteMode, .temperature, .tint, .lift, .gamma, .gain: ""
        // A band's components each have a unit of their own (see
        // `unit(ofComponent:)`).
        case .eqLowCut, .eqLowShelf, .eqBell1, .eqBell2, .eqBell3, .eqBell4, .eqHighShelf, .eqHighCut: ""
        case .eqLowCutSlope, .eqHighCutSlope: ""
        case .eqOutput, .threshold, .headroom, .makeup, .drive: " dB"
        case .attack, .release, .limiterRelease, .decay: " ms"
        // A Keyframing effect's amounts are in its target's units.
        case .beatSelection, .beatShape, .wiggleType, .wiggleDimensions, .wave, .loopMode, .loopSide, .keyCurve: ""
        case .frequencyRange: " Hz"
        case .levelRange: " dB"
        case .keyAttack, .keyRelease: " ms"
        case .outputRange: ""
        case .peak, .magnitude, .amplitude, .octaves, .seed, .stiffness, .damping, .mass: ""
        case .everyBeats, .beatOffset: " beats"
        case .accent, .tolerance: "%"
        case .wiggleFrequency: "/s"
        case .oscillatorFrequency: " Hz"
        case .phase: "°"
        case .fade: " s"
        case .smoothing, .hold: " frames"
        case .palette, .solarizeChannels, .falseColorLook, .edgeColoring: ""
        case .hueSpeed: " turns/s"
        case .cycleSpeed, .scrollSpeed: " /s"
        case .hueSpread: "°"
        case .saturationBoost, .solarizeLevel, .glow: "%"
        case .paletteBias, .paletteAmplitude, .paletteFrequency, .palettePhase: ""
        case .shadowColor, .midtoneColor, .highlightColor, .edgeColor: ""
        case .repeats, .folds, .levels: ""
        case .mixRed, .mixGreen, .mixBlue, .mixOffset: ""
        case .edgeWidth: " px"
        }
    }

    /// How far one point of dragging a value moves it: a pixel, a percent,
    /// a degree, a tenth of a stop.
    var dragStep: Double {
        switch self {
        case .exposure: 0.1
        case .lift, .gamma, .gain, .fill, .stroke: 0.01
        case .headroom, .eqOutput: 0.1
        case .wiggleFrequency, .oscillatorFrequency, .fade, .tolerance, .mass, .edgeWidth: 0.1
        case .hueSpeed, .cycleSpeed, .scrollSpeed: 0.01
        case .paletteBias, .paletteAmplitude, .paletteFrequency, .palettePhase: 0.01
        case .shadowColor, .midtoneColor, .highlightColor, .edgeColor: 0.01
        case .mixRed, .mixGreen, .mixBlue, .mixOffset: 0.01
        default: 1
        }
    }

    /// What a component is limited to, if anything.
    var range: ClosedRange<Double>? {
        switch self {
        case .opacity, .amount: 0...100
        case .exposure: -20...20
        case .contrast, .saturation: 0...1000
        case .temperature, .tint: -100...100
        case .lift: -1...1
        case .gamma: 0.01...10
        case .gain: 0...10
        case .position, .scale, .rotation, .mode, .matteMode, .shapePosition, .shapeRotation: nil
        case .strokeEdge, .strokeJoin, .strokeCap: nil
        case .dash: 0...10_000
        case .points: 3...100
        case .radius, .innerRadius: 0...50_000
        case .shapeSize: 0...100_000
        case .cornerRadius: 0...50_000
        case .strokeWidth: 0...10_000
        case .fill, .stroke: 0...1
        // A band's components each have a range of their own (see
        // `range(ofComponent:)`).
        case .eqLowCut, .eqLowShelf, .eqBell1, .eqBell2, .eqBell3, .eqBell4, .eqHighShelf, .eqHighCut: nil
        case .eqLowCutSlope, .eqHighCutSlope: nil
        case .eqOutput: Equalizer.gains
        case .threshold: -60...0
        case .headroom: 0.1...40
        case .attack: 1...300
        case .release: 10...3000
        case .makeup: -20...40
        case .drive: 0...24
        case .limiterRelease: 1...40
        case .isolation: 0...100
        case .beatSelection, .beatShape, .wiggleType, .wiggleDimensions, .wave, .loopMode, .loopSide, .keyCurve: nil
        case .peak, .magnitude, .amplitude, .phase, .outputRange: nil
        case .frequencyRange: Spectrogram.lowestFrequency...Spectrogram.highestFrequency
        case .levelRange: Spectrogram.floor...0
        case .keyAttack: 0...2000
        case .keyRelease: 0...5000
        case .everyBeats: 1...64
        case .beatOffset: 0...63
        case .accent: 0...1000
        case .decay: 0...10_000
        case .wiggleFrequency, .oscillatorFrequency: 0...60
        case .octaves: 1...8
        case .seed: 0...100_000
        case .fade: 0...60
        case .smoothing: 1...240
        case .hold: 1...120
        case .stiffness: 1...10_000
        case .damping: 0...1000
        case .mass: 0.01...100
        case .tolerance: 0...50
        case .palette, .solarizeChannels, .falseColorLook, .edgeColoring: nil
        case .hueSpeed, .cycleSpeed, .scrollSpeed: -20...20
        case .hueSpread: -1080...1080
        case .saturationBoost: -100...400
        case .paletteBias, .paletteAmplitude, .palettePhase: -2...2
        case .paletteFrequency: 0...8
        case .shadowColor, .midtoneColor, .highlightColor, .edgeColor: 0...1
        case .repeats: 1...32
        case .folds: 1...16
        case .solarizeLevel: 1...99
        case .levels: 2...64
        case .mixRed, .mixGreen, .mixBlue: -4...4
        case .mixOffset: -1...1
        case .edgeWidth: 0.5...50
        case .glow: 0...200
        }
    }

    /// Whether the control counts something, so it holds whole numbers.
    var isWhole: Bool {
        switch self {
        case .points, .everyBeats, .beatOffset, .octaves, .seed, .smoothing, .hold, .repeats, .folds, .levels: true
        default: false
        }
    }

    /// A component limited to what the control allows; a count is whole.
    func clamped(_ component: Double) -> Double {
        let whole = isWhole ? component.rounded() : component
        guard let range else { return whole }
        return min(max(whole, range.lowerBound), range.upperBound)
    }

    /// A shown value with its unit.
    func label(_ shown: Double) -> String {
        NumericExpression.format(shown, maxFractionDigits: dragStep < 1 ? 2 : 1) + unit
    }

    // MARK: Components

    /// Whether a new control of this kind is on: an EQ's bands start off,
    /// to be switched on as they're needed.
    var startsEnabled: Bool { EqualizerBand(controlKind: self) == nil }

    /// The unit of one component. Most controls' components share one; an
    /// EQ band's frequency, gain and Q each have their own.
    func unit(ofComponent index: Int) -> String {
        EqualizerBand(controlKind: self)?.unit(ofComponent: index) ?? unit
    }

    /// What one component is limited to, if anything.
    func range(ofComponent index: Int) -> ClosedRange<Double>? {
        EqualizerBand(controlKind: self)?.range(ofComponent: index) ?? range
    }

    /// How far one point of dragging one component moves it.
    func dragStep(ofComponent index: Int) -> Double {
        EqualizerBand(controlKind: self)?.dragStep(ofComponent: index) ?? dragStep
    }

    /// One component limited to what the control allows there.
    func clamped(_ component: Double, index: Int) -> Double {
        guard EqualizerBand(controlKind: self) != nil, let range = range(ofComponent: index) else { return clamped(component) }
        return min(max(component, range.lowerBound), range.upperBound)
    }

    /// One component's shown value with its unit.
    func label(_ shown: Double, component index: Int) -> String {
        NumericExpression.format(shown, maxFractionDigits: dragStep(ofComponent: index) < 1 ? 2 : 1) + unit(ofComponent: index)
    }
}

/// One control of an effect: a single value or keyframes (in the clip's
/// source time), or for a choice the option picked.
struct EffectControl: Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: ControlKind
    var enabled = true
    /// The control's numbers, keyframed or not. Unused by choices.
    var number: AnimatedValue<ComponentValue>
    /// The option picked, for a choice: a raw value of one of its
    /// `choiceOptions`.
    var choice: String?
    /// Whether editing one axis of a scale or a size changes the other in
    /// proportion.
    var linked = true
    /// For a rectangle's Corners: rounded with continuous curvature, the
    /// corner easing into the edge as an app icon's does, instead of a
    /// circular arc meeting it abruptly. Found in the control's menu.
    var squircle = false

    init(id: UUID = UUID(), kind: ControlKind, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        linked = kind.linksByDefault
        number = AnimatedValue(ComponentValue(values: kind.defaultValues))
        choice = kind.defaultChoice
    }

    var isAnimated: Bool { number.isAnimated }

    var blendMode: BlendMode {
        get { choice.flatMap(BlendMode.init(rawValue:)) ?? .normal }
        set { choice = newValue.rawValue }
    }

    var matteMode: MatteMode {
        get { choice.flatMap(MatteMode.init(rawValue:)) ?? .alpha }
        set { choice = newValue.rawValue }
    }

    /// True when the control changes nothing: it is off, or it holds its
    /// default throughout.
    var isNoOp: Bool {
        guard enabled else { return true }
        guard kind.hasNeutralDefault else { return false }
        if let band = EqualizerBand(controlKind: kind) {
            // A cut always cuts; a shelf or bell does nothing at 0 dB,
            // wherever it is.
            guard let gain = band.gainIndex else { return false }
            let values = number.isAnimated ? number.keyframes.map(\.value.values) : [number.value.values]
            return values.allSatisfy { !$0.indices.contains(gain) || $0[gain] == 0 }
        }
        if kind == .mode { return blendMode == .normal }
        if kind == .matteMode { return false }
        let defaults = ComponentValue(values: kind.defaultValues)
        if number.isAnimated { return number.keyframes.allSatisfy { $0.value == defaults } }
        return number.value == defaults
    }

    /// Whether it holds what a new control of its kind does: not animated,
    /// at its default value or option, and not a squircle. Whether it is on
    /// doesn't count.
    var isAtDefault: Bool {
        let fresh = EffectControl(kind: kind)
        return !number.isAnimated && number.value == fresh.number.value && choice == fresh.choice && !squircle
    }

    /// The control's components at `source time`.
    func values(at time: CMTime) -> [Double] {
        number.value(at: time).values
    }

    mutating func reset() {
        let fresh = EffectControl(id: id, kind: kind, enabled: enabled)
        number = fresh.number
        choice = fresh.choice
        squircle = fresh.squircle
    }

    /// Sets one component at `time` (a keyframe when animated). Linked
    /// scale keeps its proportion; limits apply.
    mutating func setComponent(_ index: Int, to newValue: Double, at time: CMTime) {
        guard newValue.isFinite, !kind.isChoice else { return }
        var values = number.value(at: time).values
        guard values.indices.contains(index) else { return }
        let old = values
        values[index] = kind.clamped(newValue, index: index)
        if kind.isLinkable, linked, values.count == 2 {
            let other = 1 - index
            values[other] = old[index] != 0 ? old[other] * newValue / old[index] : newValue
        }
        number.set(ComponentValue(values: values), at: time)
    }

    /// The control's keyframe span, nil when not animated.
    var animatedRange: ClosedRange<CMTime>? { number.animatedRange }
}

/// One effect in a clip's stack.
struct Effect: Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: EffectKind
    /// What the person renamed it to, or the number that tells it from
    /// others of its kind ("Transform 2"). Nil shows the kind's name.
    var name: String?
    var enabled = true
    /// Transform: whether Position moves the anchor along with the picture.
    var movesAnchor = true
    /// Blending: the effect whose input picture is blended with, or nil for
    /// the backdrop.
    var against: UUID?
    /// For an effect that takes one: the picture dropped on it.
    var input: EffectInput?
    /// For a Keyframing effect: what it writes to and how (nil for every
    /// other kind).
    var keyframing: KeyframingSetup?
    /// What pasting or applying a preset couldn't bring over, until each is
    /// marked resolved (see docs/effects.md, "Paste changes").
    var pasteChanges: [PasteChange] = []
    var controls: [EffectControl]

    init(id: UUID = UUID(), kind: EffectKind, name: String? = nil, controls: [EffectControl]? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.controls = controls ?? kind.controlKinds.map { EffectControl(kind: $0, enabled: $0.startsEnabled) }
        keyframing = kind.isKeyframing ? KeyframingSetup() : nil
        if kind == .audioKeys { keyframing?.audioSource = .mix }
    }

    var displayName: String { name ?? kind.name }

    /// The value of a choice control, or nil if the effect lacks it.
    func choice<Option: RawRepresentable>(_ kind: ControlKind, as type: Option.Type = Option.self) -> Option?
    where Option.RawValue == String {
        control(kind).flatMap { $0.choice }.flatMap(Option.init(rawValue:))
    }

    func control(_ kind: ControlKind) -> EffectControl? {
        controls.first { $0.kind == kind }
    }

    func controlIndex(_ id: UUID) -> Int? {
        controls.firstIndex { $0.id == id }
    }

    /// True when nothing in the effect changes the picture, or for a
    /// sound effect the sound.
    var isNoOp: Bool {
        guard enabled else { return true }
        // It wrote its keyframes onto another control, which draws them.
        if kind.isKeyframing { return true }
        // A look always changes the picture, unless it is mixed in at none.
        if kind.isLook {
            guard let amount = control(.amount), amount.enabled else { return false }
            return !amount.number.isAnimated && amount.number.value.values.first == 0
        }
        if kind == .matte {
            // Without a picture to cut with, or at 0%, nothing changes.
            guard input != nil else { return true }
            guard let amount = control(.amount) else { return false }
            return amount.enabled && !amount.number.isAnimated && amount.number.value.values.first == 0
        }
        if kind == .blending {
            // Without a mode there is nothing to blend, and at 0% the blend
            // isn't applied.
            guard let mode = control(.mode), !mode.isNoOp else { return true }
            guard let amount = control(.amount) else { return false }
            return amount.enabled && !amount.number.isAnimated && amount.number.value.values.first == 0
        }
        return controls.allSatisfy(\.isNoOp)
    }

    /// The controls of the kind it doesn't list now, which were deleted.
    var missingControlKinds: [ControlKind] {
        kind.controlKinds.filter { control($0) == nil }
    }

    /// A new effect of `kind` named for the stack it joins: the first of its
    /// kind keeps the plain name, later ones are numbered.
    static func make(_ kind: EffectKind, among stack: [Effect]) -> Effect {
        var effect = Effect(kind: kind)
        let taken = Set(stack.filter { $0.kind == kind }.map(\.displayName))
        if taken.contains(kind.name) {
            var number = 2
            while taken.contains("\(kind.name) \(number)") { number += 1 }
            effect.name = "\(kind.name) \(number)"
        }
        return effect
    }

    /// Back to a new effect's controls, all at their defaults, keeping its
    /// ID and name.
    mutating func reset() {
        let setup = keyframing
        self = Effect(id: id, kind: kind, name: name)
        keyframing = setup
    }

    /// Deletes a control. Without it the effect does nothing for it.
    mutating func removeControl(_ id: UUID) {
        controls.removeAll { $0.id == id }
    }

    /// Moves a control to `index` among the effect's controls.
    mutating func moveControl(_ id: UUID, toIndex index: Int) {
        guard let from = controlIndex(id) else { return }
        let control = controls.remove(at: from)
        controls.insert(control, at: min(max(index, 0), controls.count))
    }

    /// Puts back a control that was deleted, at the end.
    mutating func addControl(_ kind: ControlKind) {
        guard self.kind.controlKinds.contains(kind), control(kind) == nil else { return }
        controls.append(EffectControl(kind: kind, enabled: kind.startsEnabled))
    }

    /// A copy with new IDs for the effect and its controls.
    func duplicated(named name: String? = nil) -> Effect {
        var copy = self
        copy.id = UUID()
        copy.controls = controls.map { control in
            var control = control
            control.id = UUID()
            return control
        }
        if let name { copy.name = name }
        return copy
    }

    /// Whether it changes over time by itself, without keyframes: a Hue
    /// Cycle that turns, a palette that cycles. Its clip is drawn afresh
    /// at every frame then.
    var changesOnItsOwn: Bool {
        guard enabled, !isNoOp else { return false }
        let moving: ControlKind? = switch kind {
        case .hueCycle: .hueSpeed
        case .cosinePalette: .cycleSpeed
        case .gradientMap: .scrollSpeed
        default: nil
        }
        guard let moving, let control = control(moving), control.enabled else { return false }
        return control.number.isAnimated ? control.number.keyframes.contains { $0.value.values.first != 0 } : control.number.value.values.first != 0
    }

    /// The span of time in which any enabled control is between keyframes.
    var animatedRanges: [ClosedRange<CMTime>] {
        guard enabled, !kind.isKeyframing else { return [] }
        return controls.compactMap { $0.enabled ? $0.animatedRange : nil }
    }
}

extension Array where Element == Effect {
    func index(of id: UUID) -> Int? {
        firstIndex { $0.id == id }
    }

    /// The effects above `index`, which a Blending step there may blend
    /// against.
    func effectsAbove(_ index: Int) -> [Effect] {
        Array(prefix(index))
    }

    /// Whether the Blending effect at `index` can read the picture it is
    /// set to blend against: that effect is in the stack above it.
    func againstIsReachable(at index: Int) -> Bool {
        guard let target = self[index].against else { return true }
        return effectsAbove(index).contains { $0.id == target }
    }
}

// MARK: - Clips

extension TimelineClip {
    /// The list effects of `kind` go in: the picture's stack, or the
    /// sound's.
    static func stack(for kind: EffectKind) -> WritableKeyPath<TimelineClip, [Effect]> {
        kind.isAudio ? \.audioEffects : \.effects
    }

    /// The list holding the effect with ID `id`, if the clip has it.
    func stack(holding id: UUID) -> WritableKeyPath<TimelineClip, [Effect]>? {
        if effects.contains(where: { $0.id == id }) { return \.effects }
        if audioEffects.contains(where: { $0.id == id }) { return \.audioEffects }
        return nil
    }

    /// The effect with ID `id`, in either list.
    func effect(id: UUID) -> Effect? {
        stack(holding: id).flatMap { self[keyPath: $0].first { $0.id == id } }
    }

    /// The span of time in which something in the clip's stack, or its
    /// anchor point, is between keyframes, in the clip's source time.
    var animatedSourceRanges: [ClosedRange<CMTime>] {
        effects.flatMap(\.animatedRanges) + [anchorPoint.animatedRange].compactMap { $0 }
    }
}

// MARK: - Editing

extension EditingProject {
    /// Applies `change` to the clip with ID `clipID` in the timeline,
    /// wherever it sits.
    mutating func editClip(_ clipID: UUID, in timelineID: UUID, _ change: (inout TimelineClip) -> Void) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }) else { return }
        for lIndex in timelines[tIndex].layers.indices {
            if let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == clipID }) {
                change(&timelines[tIndex].layers[lIndex].clips[cIndex])
                return
            }
        }
    }

    /// The clip with ID `clipID` in the timeline, and the layer it is on.
    func clipAndLayer(_ clipID: UUID, in timelineID: UUID) -> (clip: TimelineClip, layer: TimelineLayer)? {
        guard let timeline = timeline(id: timelineID) else { return nil }
        for layer in timeline.layers {
            if let clip = layer.clips.first(where: { $0.id == clipID }) { return (clip, layer) }
        }
        return nil
    }

    /// Whether the clip has pictures, so it has an effect stack and an
    /// anchor point. Audio-only clips have neither.
    func hasEffectStack(_ clip: TimelineClip) -> Bool {
        playsVideo(clip)
    }
}

extension EditingProject {
    /// What a parameter's graph editor is titled: "Video 1 · Volume" or
    /// "Interview · Transform 2 · Position".
    func parameterTitle(of key: ParameterKey) -> String {
        guard let timeline = timeline(id: key.timelineID) else { return key.parameter.name }
        switch key.parameter {
        case .layerVolume(let layerID), .layerPan(let layerID):
            guard let layer = timeline.layer(id: layerID) else { return key.parameter.name }
            return "\(displayName(of: layer, in: timeline)) · \(key.parameter.name)"
        case .clipVolume(let clipID), .clipPan(let clipID), .anchorPoint(let clipID), .speed(let clipID):
            return "\(clipName(clipID, in: key.timelineID)) · \(key.parameter.name)"
        case .control(_, let clipID, let effectID, _):
            let effect = clipAndLayer(clipID, in: key.timelineID)?.clip.effect(id: effectID)
            return [clipName(clipID, in: key.timelineID), effect?.displayName, key.parameter.name]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// The name of what a clip plays.
    func clipName(_ clipID: UUID, in timelineID: UUID) -> String {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip else { return "Clip" }
        return resolvedInfo(for: clip.source)?.name ?? "Clip"
    }
}

// MARK: - Editing stacks

extension EditingProject {
    /// Adds a new effect of `kind` to a clip's stack, at `index` or at the
    /// end (a Keyframing effect at the top): a sound effect to its sound's.
    /// Clips with no pictures take no picture effects, and clips with no
    /// sound no sound effects. A Keyframing effect writes to the first
    /// control below it that no other one does. Returns the effect's ID.
    @discardableResult
    mutating func addEffect(_ kind: EffectKind, toClip clipID: UUID, in timelineID: UUID, at index: Int? = nil) -> UUID? {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip,
              kind.isAudio ? playsAudio(clip) : hasEffectStack(clip)
        else { return nil }
        let stack = TimelineClip.stack(for: kind)
        var effect = Effect.make(kind, among: clip[keyPath: stack])
        if let frame = timeline(id: timelineID)?.frameSize { effect.sizeShape(to: frame) }
        let count = clip[keyPath: stack].count
        let at = min(max(index ?? (kind.isKeyframing ? 0 : count), 0), count)
        var placed = clip
        placed[keyPath: stack].insert(effect, at: at)
        if kind.isKeyframing {
            // The first that no other Keyframing effect writes to, since two
            // on one control would undo each other.
            let taken = Set(placed.effects.compactMap { $0.keyframing?.target })
            let targets = keyframingTargets(forEffectAt: at, in: placed)
            effect.keyframing?.target = targets.first { !taken.contains($0) } ?? targets.first
        }
        editClip(clipID, in: timelineID) { clip in
            clip[keyPath: stack].insert(effect, at: at)
        }
        if kind.isKeyframing { regenerateKeyframes(ofEffect: effect.id, onClip: clipID, in: timelineID) }
        return effect.id
    }

    /// Applies `change` to one effect of a clip. A Keyframing effect then
    /// makes its keyframes again; one pointed somewhere else leaves what it
    /// wrote on its old target as plain keyframes.
    mutating func editEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID, _ change: (inout Effect) -> Void) {
        var before: Effect?
        var after: Effect?
        editClip(clipID, in: timelineID) { clip in
            guard let stack = clip.stack(holding: effectID), let index = clip[keyPath: stack].index(of: effectID) else { return }
            before = clip[keyPath: stack][index]
            change(&clip[keyPath: stack][index])
            after = clip[keyPath: stack][index]
            if let old = before?.keyframing?.target, old != after?.keyframing?.target {
                clip.releaseKeyframes(of: effectID, on: old)
            }
        }
        if let after, after.kind.isKeyframing, after != before {
            regenerateKeyframes(ofEffect: effectID, onClip: clipID, in: timelineID)
        }
    }

    /// Removes an effect. A Keyframing effect takes what it wrote with it,
    /// putting its target back as it was.
    mutating func removeEffect(_ effectID: UUID, fromClip clipID: UUID, in timelineID: UUID) {
        restoreKeyframingBase(ofEffect: effectID, onClip: clipID, in: timelineID)
        editClip(clipID, in: timelineID) { clip in
            guard let stack = clip.stack(holding: effectID) else { return }
            clip[keyPath: stack].removeAll { $0.id == effectID }
        }
    }

    /// Moves an effect to `index` in its stack (0 is the top).
    mutating func moveEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID, toIndex index: Int) {
        editClip(clipID, in: timelineID) { clip in
            guard let stack = clip.stack(holding: effectID), let from = clip[keyPath: stack].index(of: effectID) else { return }
            let effect = clip[keyPath: stack].remove(at: from)
            clip[keyPath: stack].insert(effect, at: min(max(index, 0), clip[keyPath: stack].count))
        }
    }

    /// Puts a copy of an effect just below it, named for the stack.
    @discardableResult
    mutating func duplicateEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID) -> UUID? {
        var copyID: UUID?
        editClip(clipID, in: timelineID) { clip in
            guard let stack = clip.stack(holding: effectID), let index = clip[keyPath: stack].index(of: effectID) else { return }
            let original = clip[keyPath: stack][index]
            var copy = original.duplicated(named: Effect.make(original.kind, among: clip[keyPath: stack]).name)
            // Two effects writing to one control would undo each other.
            copy.keyframing?.target = nil
            clip[keyPath: stack].insert(copy, at: index + 1)
            copyID = copy.id
        }
        return copyID
    }
}

// MARK: - Easing at the playhead

extension TimelineClip {
    /// Applies an ease to every keyframe the clip's anchor point, volume,
    /// pan and effect controls have at `time` in the timeline, for the F9 keys.
    /// Returns whether there was one.
    @discardableResult
    mutating func easeKeyframes(atTimelineTime time: CMTime, _ preset: KeyframeEase.Preset) -> Bool {
        let source = sourceTime(atTimelineTime: time)
        var eased = false
        if anchorPoint.keyframe(at: source) != nil {
            anchorPoint.applyEase(preset, at: source)
            eased = true
        }
        if volume.keyframe(at: source) != nil {
            volume.applyEase(preset, at: source)
            eased = true
        }
        if pan.keyframe(at: source) != nil {
            pan.applyEase(preset, at: source)
            eased = true
        }
        if self.time.speed.keyframe(at: source) != nil {
            self.time.speed.applyEase(preset, at: source)
            eased = true
        }
        for stack in [\TimelineClip.effects, \.audioEffects] {
            for e in self[keyPath: stack].indices {
                for c in self[keyPath: stack][e].controls.indices where self[keyPath: stack][e].controls[c].number.keyframe(at: source) != nil {
                    self[keyPath: stack][e].controls[c].number.applyEase(preset, at: source)
                    eased = true
                }
            }
        }
        return eased
    }
}
