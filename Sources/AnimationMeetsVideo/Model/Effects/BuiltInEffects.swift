import Foundation

// The effect and control kinds built into the app, and what each is (see
// `EffectRegistry`).

extension EffectKind {
    static let transform = EffectKind(builtIn: "transform")
    static let blending = EffectKind(builtIn: "blending")
    static let color = EffectKind(builtIn: "color")
    static let matte = EffectKind(builtIn: "matte")
    /// Shapes draw over the picture handed down to them (see
    /// docs/graphic-layers.md, "Shapes").
    static let rectangle = EffectKind(builtIn: "rectangle")
    static let ellipse = EffectKind(builtIn: "ellipse")
    static let polygon = EffectKind(builtIn: "polygon")
    static let star = EffectKind(builtIn: "star")
    /// A block of text whose outline is its glyphs, set with Core Text.
    static let text = EffectKind(builtIn: "text")
    /// Moves, scales, turns, fades and recolors a range of the letters of
    /// the Text effect above it, glyph by glyph.
    static let textAnimator = EffectKind(builtIn: "textAnimator")
    /// Strokes the outline of the shapes above it in the stack, strokes
    /// and all, so a stroke can have a stroke of its own.
    static let stroke = EffectKind(builtIn: "stroke")
    /// Sound effects (see docs/audio.md, "Sound effects").
    static let equalizer = EffectKind(builtIn: "equalizer")
    static let compressor = EffectKind(builtIn: "compressor")
    static let limiter = EffectKind(builtIn: "limiter")
    static let voiceIsolation = EffectKind(builtIn: "voiceIsolation")
    /// Keyframing effects (see docs/keyframing-effects.md): each writes
    /// keyframes onto a control below it, and draws nothing.
    static let audioKeys = EffectKind(builtIn: "audioKeys")
    static let beatKeys = EffectKind(builtIn: "beatKeys")
    static let wiggler = EffectKind(builtIn: "wiggler")
    static let oscillator = EffectKind(builtIn: "oscillator")
    static let smoother = EffectKind(builtIn: "smoother")
    static let looper = EffectKind(builtIn: "looper")
    static let timeStep = EffectKind(builtIn: "timeStep")
    static let overshoot = EffectKind(builtIn: "overshoot")
    /// Holds an effect whose package isn't installed (`Effect.missing`).
    /// Never listed or saved under this name.
    static let missing = EffectKind(builtIn: "missing")

    // From the packages in Resources/Effects, which ship with the app.
    static let posterize = EffectKind(package: "posterize")
    static let flowSmear = EffectKind(package: "flowSmear")
    static let feedback = EffectKind(package: "feedback")
    static let slitScan = EffectKind(package: "slitScan")
    static let displace = EffectKind(package: "displace")
    static let liquid = EffectKind(package: "liquid")
    static let twirl = EffectKind(package: "twirl")
    static let wave = EffectKind(package: "wave")
    static let kaleidoscope = EffectKind(package: "kaleidoscope")
    static let mirrorTile = EffectKind(package: "mirrorTile")
    static let chromaticAberration = EffectKind(package: "chromaticAberration")
    static let grain = EffectKind(package: "grain")
    static let staticNoise = EffectKind(package: "staticNoise")
    static let fractalNoise = EffectKind(package: "fractalNoise")
    static let cells = EffectKind(package: "cells")
    static let dither = EffectKind(package: "dither")
    static let interference = EffectKind(package: "interference")
    static let blockGlitch = EffectKind(package: "blockGlitch")
    static let hueCycle = EffectKind(package: "hueCycle")
    static let cosinePalette = EffectKind(package: "cosinePalette")
    static let gradientMap = EffectKind(package: "gradientMap")
    static let solarize = EffectKind(package: "solarize")
    static let channelMixer = EffectKind(package: "channelMixer")
    static let falseColor = EffectKind(package: "falseColor")
    static let neonEdges = EffectKind(package: "neonEdges")

    /// How a shape is filled and stroked, after what shapes it.
    static let paintControls: [ControlKind] = [.fill, .stroke, .strokeWidth, .strokeEdge, .strokeJoin, .strokeCap, .dash]

    /// A Text effect's settings, as Illustrator's Character, Paragraph and
    /// OpenType panels group them (see `TextInspectorGroup`).
    static let characterControls: [ControlKind] = [
        .fontSize, .leading, .kerning, .tracking, .verticalScale, .horizontalScale, .baselineShift, .characterRotation,
        .textCase, .underline, .strikethrough,
    ]
    static let paragraphControls: [ControlKind] = [
        .textAlign, .leftIndent, .rightIndent, .firstLineIndent, .spaceBefore, .spaceAfter, .wrapWidth, .hyphenate, .textAnchor,
    ]
    /// Whether text follows the outline of the shape above it, and where
    /// along it it starts.
    static let pathControls: [ControlKind] = [.textOnPath, .pathOffset, .pathFlip]
    static let openTypeControls: [ControlKind] = [
        .ligatures, .contextualAlternates, .figures, .fractions, .ordinals, .swash, .stylisticAlternates, .stylisticSet,
    ]

    /// A drawn shape's sections in the effects panel: what shapes it, then
    /// how it is painted.
    static func shapeSections(_ shape: [ControlKind]) -> [ControlSection] {
        [ControlSection("Shape", shape), ControlSection("Fill & Stroke", paintControls)]
    }

    /// A Text effect's sections in the effects panel, as the inspector
    /// groups them; the font's variation axes go under Character. Where
    /// the block sits goes with the paragraph, beside its Anchor.
    static let textSections: [ControlSection] = [
        ControlSection("Character", characterControls, holdsFontAxes: true),
        ControlSection("Paragraph", paragraphControls + [.shapePosition]),
        ControlSection("Path", pathControls),
        ControlSection("OpenType", openTypeControls),
        ControlSection("Fill & Stroke", paintControls),
    ]
}

extension ControlKind {
    // Transform
    static let position = ControlKind(builtIn: "position")
    static let scale = ControlKind(builtIn: "scale")
    static let rotation = ControlKind(builtIn: "rotation")
    static let opacity = ControlKind(builtIn: "opacity")
    // Blending
    static let mode = ControlKind(builtIn: "mode")
    static let amount = ControlKind(builtIn: "amount")
    // Color
    static let exposure = ControlKind(builtIn: "exposure")
    static let contrast = ControlKind(builtIn: "contrast")
    static let saturation = ControlKind(builtIn: "saturation")
    static let temperature = ControlKind(builtIn: "temperature")
    static let tint = ControlKind(builtIn: "tint")
    static let lift = ControlKind(builtIn: "lift")
    static let gamma = ControlKind(builtIn: "gamma")
    static let gain = ControlKind(builtIn: "gain")
    // Matte
    static let matteMode = ControlKind(builtIn: "matteMode")
    // Rectangle
    static let shapeSize = ControlKind(builtIn: "shapeSize")
    static let cornerRadius = ControlKind(builtIn: "cornerRadius")
    static let shapePosition = ControlKind(builtIn: "shapePosition")
    static let fill = ControlKind(builtIn: "fill")
    static let stroke = ControlKind(builtIn: "stroke")
    static let strokeWidth = ControlKind(builtIn: "strokeWidth")
    static let strokeEdge = ControlKind(builtIn: "strokeEdge")
    static let strokeJoin = ControlKind(builtIn: "strokeJoin")
    static let strokeCap = ControlKind(builtIn: "strokeCap")
    static let dash = ControlKind(builtIn: "dash")
    // Polygon
    static let points = ControlKind(builtIn: "points")
    static let radius = ControlKind(builtIn: "radius")
    static let shapeRotation = ControlKind(builtIn: "shapeRotation")
    // Star
    static let innerRadius = ControlKind(builtIn: "innerRadius")
    // Text
    static let fontSize = ControlKind(builtIn: "fontSize")
    static let leading = ControlKind(builtIn: "leading")
    static let kerning = ControlKind(builtIn: "kerning")
    static let tracking = ControlKind(builtIn: "tracking")
    static let verticalScale = ControlKind(builtIn: "verticalScale")
    static let horizontalScale = ControlKind(builtIn: "horizontalScale")
    static let baselineShift = ControlKind(builtIn: "baselineShift")
    static let characterRotation = ControlKind(builtIn: "characterRotation")
    static let textCase = ControlKind(builtIn: "textCase")
    static let underline = ControlKind(builtIn: "underline")
    static let strikethrough = ControlKind(builtIn: "strikethrough")
    static let textAlign = ControlKind(builtIn: "textAlign")
    static let leftIndent = ControlKind(builtIn: "leftIndent")
    static let rightIndent = ControlKind(builtIn: "rightIndent")
    static let firstLineIndent = ControlKind(builtIn: "firstLineIndent")
    static let spaceBefore = ControlKind(builtIn: "spaceBefore")
    static let spaceAfter = ControlKind(builtIn: "spaceAfter")
    static let wrapWidth = ControlKind(builtIn: "wrapWidth")
    static let hyphenate = ControlKind(builtIn: "hyphenate")
    static let textAnchor = ControlKind(builtIn: "textAnchor")
    static let textOnPath = ControlKind(builtIn: "textOnPath")
    static let pathOffset = ControlKind(builtIn: "pathOffset")
    static let pathFlip = ControlKind(builtIn: "pathFlip")
    static let ligatures = ControlKind(builtIn: "ligatures")
    static let contextualAlternates = ControlKind(builtIn: "contextualAlternates")
    static let figures = ControlKind(builtIn: "figures")
    static let fractions = ControlKind(builtIn: "fractions")
    static let ordinals = ControlKind(builtIn: "ordinals")
    static let swash = ControlKind(builtIn: "swash")
    static let stylisticAlternates = ControlKind(builtIn: "stylisticAlternates")
    static let stylisticSet = ControlKind(builtIn: "stylisticSet")
    // Text Animator
    static let animatorStart = ControlKind(builtIn: "animatorStart")
    static let animatorEnd = ControlKind(builtIn: "animatorEnd")
    static let animatorOffset = ControlKind(builtIn: "animatorOffset")
    static let animatorUnit = ControlKind(builtIn: "animatorUnit")
    static let animatorShape = ControlKind(builtIn: "animatorShape")
    static let animatorPosition = ControlKind(builtIn: "animatorPosition")
    static let animatorScale = ControlKind(builtIn: "animatorScale")
    static let animatorRotation = ControlKind(builtIn: "animatorRotation")
    static let animatorOpacity = ControlKind(builtIn: "animatorOpacity")
    static let animatorFill = ControlKind(builtIn: "animatorFill")
    static let animatorStroke = ControlKind(builtIn: "animatorStroke")
    static let animatorTracking = ControlKind(builtIn: "animatorTracking")
    // EQ
    static let eqLowCut = ControlKind(builtIn: "eqLowCut")
    static let eqLowCutSlope = ControlKind(builtIn: "eqLowCutSlope")
    static let eqLowShelf = ControlKind(builtIn: "eqLowShelf")
    static let eqBell1 = ControlKind(builtIn: "eqBell1")
    static let eqBell2 = ControlKind(builtIn: "eqBell2")
    static let eqBell3 = ControlKind(builtIn: "eqBell3")
    static let eqBell4 = ControlKind(builtIn: "eqBell4")
    static let eqHighShelf = ControlKind(builtIn: "eqHighShelf")
    static let eqHighCut = ControlKind(builtIn: "eqHighCut")
    static let eqHighCutSlope = ControlKind(builtIn: "eqHighCutSlope")
    static let eqOutput = ControlKind(builtIn: "eqOutput")
    // Compressor
    static let threshold = ControlKind(builtIn: "threshold")
    static let headroom = ControlKind(builtIn: "headroom")
    static let attack = ControlKind(builtIn: "attack")
    static let release = ControlKind(builtIn: "release")
    static let makeup = ControlKind(builtIn: "makeup")
    // Limiter
    static let drive = ControlKind(builtIn: "drive")
    static let limiterRelease = ControlKind(builtIn: "limiterRelease")
    // Voice Isolation
    static let isolation = ControlKind(builtIn: "isolation")
    // Audio Keys
    static let frequencyRange = ControlKind(builtIn: "frequencyRange")
    static let levelRange = ControlKind(builtIn: "levelRange")
    static let keyAttack = ControlKind(builtIn: "keyAttack")
    static let keyRelease = ControlKind(builtIn: "keyRelease")
    static let outputRange = ControlKind(builtIn: "outputRange")
    static let keyCurve = ControlKind(builtIn: "keyCurve")
    // Beat Keys
    static let beatSelection = ControlKind(builtIn: "beatSelection")
    static let everyBeats = ControlKind(builtIn: "everyBeats")
    static let beatOffset = ControlKind(builtIn: "beatOffset")
    static let accent = ControlKind(builtIn: "accent")
    static let beatShape = ControlKind(builtIn: "beatShape")
    static let peak = ControlKind(builtIn: "peak")
    static let decay = ControlKind(builtIn: "decay")
    // Wiggler
    static let wiggleFrequency = ControlKind(builtIn: "wiggleFrequency")
    static let magnitude = ControlKind(builtIn: "magnitude")
    static let wiggleType = ControlKind(builtIn: "wiggleType")
    static let octaves = ControlKind(builtIn: "octaves")
    static let wiggleDimensions = ControlKind(builtIn: "wiggleDimensions")
    static let seed = ControlKind(builtIn: "seed")
    static let tolerance = ControlKind(builtIn: "tolerance")
    // Oscillator
    static let wave = ControlKind(builtIn: "wave")
    static let oscillatorFrequency = ControlKind(builtIn: "oscillatorFrequency")
    static let amplitude = ControlKind(builtIn: "amplitude")
    static let phase = ControlKind(builtIn: "phase")
    static let fade = ControlKind(builtIn: "fade")
    // Smoother
    static let smoothing = ControlKind(builtIn: "smoothing")
    // Looper
    static let loopMode = ControlKind(builtIn: "loopMode")
    static let loopSide = ControlKind(builtIn: "loopSide")
    // Time Step
    static let hold = ControlKind(builtIn: "hold")
    // Overshoot
    static let stiffness = ControlKind(builtIn: "stiffness")
    static let damping = ControlKind(builtIn: "damping")
    static let mass = ControlKind(builtIn: "mass")
}

enum BuiltInEffects {
    /// Every built-in kind, Swift's and those of the packages that ship
    /// with the app, in the library's order. A kind not listed (a package
    /// the person installed) comes after them.
    static let libraryOrder: [String] = [
        "transform", "blending", "color", "matte",
        // Color Correction
        "levels", "shadowsHighlights", "hueSaturation", "vibrance", "hueRange", "grayPoint", "blackAndWhite", "colorize",
        "sepia", "invert", "threshold", "broadcastSafe",
        // Blur & Sharpen
        // Keying & Masks
        // Light
        // Stylize
        // Color
        "hueCycle", "cosinePalette", "gradientMap", "solarize", "posterize", "channelMixer", "falseColor", "neonEdges",
        "grain", "staticNoise", "fractalNoise", "cells", "dither", "interference", "blockGlitch",
        "displace", "liquid", "twirl", "wave", "kaleidoscope", "mirrorTile", "chromaticAberration",
        "flowSmear", "slitScan", "feedback",
        "rectangle", "ellipse", "polygon", "star", "text", "textAnimator", "stroke",
        "equalizer", "compressor", "limiter", "voiceIsolation",
        "audioKeys", "beatKeys", "wiggler", "oscillator", "smoother", "looper", "timeStep", "overshoot",
    ]

    /// The effects written in Swift, in the library's order.
    static let effects: [EffectDefinition] = [
        EffectDefinition(
            .transform, "Transform", .foundations, "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
            controls: [.position, .scale, .rotation, .opacity]
        ),
        EffectDefinition(
            .blending, "Blending", .foundations, "circle.lefthalf.filled.righthalf.striped.horizontal",
            controls: [.mode, .amount], readsAgainst: true
        ),
        EffectDefinition(
            .color, "Color", .foundations, "slider.horizontal.3",
            sections: [
                ControlSection("Tone", [.exposure, .contrast, .saturation]),
                ControlSection("White Balance", [.temperature, .tint]),
                ControlSection("Lift, Gamma, Gain", [.lift, .gamma, .gain]),
            ]
        ),
        EffectDefinition(
            .matte, "Matte", .mattes, "circle.dashed.inset.filled", controls: [.matteMode, .amount], takesInput: true
        ),
        // Shapes draw over the picture handed down to them (see
        // docs/graphic-layers.md, "Shapes").
        EffectDefinition(
            .rectangle, "Rectangle", .shapes, "rectangle",
            sections: EffectKind.shapeSections([.shapeSize, .cornerRadius, .shapePosition])
        ),
        EffectDefinition(.ellipse, "Ellipse", .shapes, "circle", sections: EffectKind.shapeSections([.shapeSize, .shapePosition])),
        EffectDefinition(
            .polygon, "Polygon", .shapes, "hexagon",
            sections: EffectKind.shapeSections([.points, .radius, .cornerRadius, .shapeRotation, .shapePosition])
        ),
        EffectDefinition(
            .star, "Star", .shapes, "star",
            sections: EffectKind.shapeSections([.points, .radius, .innerRadius, .cornerRadius, .shapeRotation, .shapePosition])
        ),
        // Its outline is its glyphs, so it fills, strokes and stays sharp
        // as the other shapes do.
        EffectDefinition(.text, "Text", .shapes, "textformat", sections: EffectKind.textSections),
        // Animates a range of the letters of the Text effect above it.
        EffectDefinition(
            .textAnimator, "Text Animator", .shapes, "textformat.abc.dottedunderline",
            sections: [
                ControlSection("Range", [.animatorStart, .animatorEnd, .animatorOffset, .animatorUnit, .animatorShape]),
                ControlSection(
                    "Letters",
                    [.animatorPosition, .animatorScale, .animatorRotation, .animatorOpacity, .animatorFill, .animatorStroke, .animatorTracking]
                ),
            ]
        ),
        // Strokes the outline of the shapes above it in the stack, strokes
        // and all, so a stroke can have a stroke of its own.
        EffectDefinition(
            .stroke, "Stroke", .shapes, "circle.dashed",
            controls: [.stroke, .strokeWidth, .strokeEdge, .strokeJoin, .strokeCap, .dash]
        ),
        // Sound effects (see docs/audio.md, "Sound effects").
        EffectDefinition(.equalizer, "EQ", .sound, "slider.vertical.3", controls: Equalizer.controlKinds),
        EffectDefinition(
            .compressor, "Compressor", .sound, "arrow.down.right.and.arrow.up.left",
            controls: [.threshold, .headroom, .attack, .release, .makeup]
        ),
        EffectDefinition(
            .limiter, "Limiter", .sound, "line.horizontal.star.fill.line.horizontal", controls: [.drive, .limiterRelease]
        ),
        EffectDefinition(.voiceIsolation, "Voice Isolation", .sound, "person.wave.2", controls: [.isolation]),
        // Keyframing effects (see docs/keyframing-effects.md): each writes
        // keyframes onto a control below it, and draws nothing.
        EffectDefinition(
            .audioKeys, "Audio Keys", .keyframing, "waveform.badge.magnifyingglass",
            sections: [
                ControlSection("Listen", [.frequencyRange, .levelRange, .keyAttack, .keyRelease]),
                ControlSection("Keyframes", [.outputRange, .keyCurve, .tolerance]),
            ]
        ),
        EffectDefinition(
            .beatKeys, "Beat Keys", .keyframing, "metronome",
            sections: [
                ControlSection("Beats", [.beatSelection, .everyBeats, .beatOffset, .accent]),
                ControlSection("Keyframes", [.beatShape, .peak, .decay, .tolerance]),
            ]
        ),
        EffectDefinition(
            .wiggler, "Wiggler", .keyframing, "scribble.variable",
            controls: [.wiggleFrequency, .magnitude, .wiggleType, .octaves, .wiggleDimensions, .seed, .tolerance]
        ),
        EffectDefinition(
            .oscillator, "Oscillator", .keyframing, "waveform.path",
            controls: [.wave, .oscillatorFrequency, .amplitude, .phase, .fade, .tolerance]
        ),
        EffectDefinition(
            .smoother, "Smoother", .keyframing, "point.topleft.down.to.point.bottomright.curvepath",
            controls: [.smoothing, .tolerance], reshapesTarget: true
        ),
        EffectDefinition(
            .looper, "Looper", .keyframing, "repeat", controls: [.loopMode, .loopSide, .tolerance], reshapesTarget: true
        ),
        EffectDefinition(.timeStep, "Time Step", .keyframing, "stairs", controls: [.hold], reshapesTarget: true),
        EffectDefinition(
            .overshoot, "Overshoot", .keyframing, "arrowshape.bounce.right", controls: [.stiffness, .damping, .mass, .tolerance],
            reshapesTarget: true
        ),
        EffectDefinition(.missing, "Missing Effect", .foundations, "questionmark.square.dashed", controls: [], isHidden: true),
    ]

    static let controls: [ControlDefinition] = [
        // Transform
        ControlDefinition(.position, "Position", .transform, defaults: [0, 0], unit: " px", componentNames: ["Δx", "Δy"]),
        ControlDefinition(.scale, "Scale", .transform, defaults: [100, 100], unit: "%", componentNames: ["x", "y"]),
        ControlDefinition(.rotation, "Rotation", .transform, defaults: [0], unit: "°"),
        ControlDefinition(.opacity, "Opacity", .transform, defaults: [100], unit: "%", range: 0...100),
        // Blending
        ControlDefinition(.mode, "Mode", .blending, choice: BlendMode.normal),
        ControlDefinition(.amount, "Amount", .blending, defaults: [100], unit: "%", range: 0...100),
        // Color
        ControlDefinition(.exposure, "Exposure", .color, defaults: [0], unit: " stops", dragStep: 0.1, range: -20...20),
        ControlDefinition(.contrast, "Contrast", .color, defaults: [100], unit: "%", range: 0...1000),
        ControlDefinition(.saturation, "Saturation", .color, defaults: [100], unit: "%", range: 0...1000),
        ControlDefinition(.temperature, "Temperature", .color, defaults: [0], range: -100...100),
        ControlDefinition(.tint, "Tint", .color, defaults: [0], range: -100...100),
        ControlDefinition(
            .lift, "Lift", .color, defaults: [0, 0, 0, 0], dragStep: 0.01, range: -1...1,
            componentNames: ["All", "Red", "Green", "Blue"]
        ),
        ControlDefinition(
            .gamma, "Gamma", .color, defaults: [1, 1, 1, 1], dragStep: 0.01, range: 0.01...10,
            componentNames: ["All", "Red", "Green", "Blue"]
        ),
        ControlDefinition(
            .gain, "Gain", .color, defaults: [1, 1, 1, 1], dragStep: 0.01, range: 0...10,
            componentNames: ["All", "Red", "Green", "Blue"]
        ),
        // Matte
        ControlDefinition(.matteMode, "Take", .matte, choice: MatteMode.alpha),
        // Rectangle
        ControlDefinition(
            .shapeSize, "Size", .rectangle, defaults: [640, 360], unit: " px", range: 0...100_000,
            componentNames: ["Width", "Height"]
        ),
        ControlDefinition(.cornerRadius, "Corners", .rectangle, defaults: [0], unit: " px", range: 0...50_000),
        ControlDefinition(.shapePosition, "Position", .rectangle, defaults: [0, 0], unit: " px", componentNames: ["Δx", "Δy"]),
        ControlDefinition(.fill, "Fill", .rectangle, defaults: [1, 1, 1, 1], dragStep: 0.01, range: 0...1, isColor: true),
        ControlDefinition(.stroke, "Stroke", .rectangle, defaults: [0, 0, 0, 1], dragStep: 0.01, range: 0...1, isColor: true),
        ControlDefinition(.strokeWidth, "Stroke Width", .rectangle, defaults: [0], unit: " px", range: 0...10_000),
        ControlDefinition(.strokeEdge, "Edge", .rectangle, choice: StrokeEdge.center),
        ControlDefinition(.strokeJoin, "Join", .rectangle, choice: StrokeJoin.miter),
        ControlDefinition(.strokeCap, "Cap", .rectangle, choice: StrokeCap.butt),
        ControlDefinition(
            .dash, "Dash", .rectangle, defaults: [0, 0], unit: " px", range: 0...10_000, componentNames: ["Dash", "Gap"]
        ),
        // Polygon
        ControlDefinition(.points, "Points", .polygon, defaults: [5], range: 3...100, isWhole: true),
        ControlDefinition(.radius, "Radius", .polygon, defaults: [180], unit: " px", range: 0...50_000),
        ControlDefinition(.shapeRotation, "Rotation", .polygon, defaults: [0], unit: "°"),
        // Star
        ControlDefinition(.innerRadius, "Inner Radius", .star, defaults: [90], unit: " px", range: 0...50_000),
        // Text
        // Character
        ControlDefinition(.fontSize, "Size", .text, defaults: [120], unit: " px", range: 1...10_000),
        // Baseline to baseline; 0 is Auto, 120% of the size.
        ControlDefinition(.leading, "Leading", .text, defaults: [0], unit: " px", range: 0...100_000),
        ControlDefinition(.kerning, "Kerning", .text, choice: TextKerning.metrics),
        // In thousandths of an em, as Illustrator and InDesign count it.
        ControlDefinition(.tracking, "Tracking", .text, defaults: [0], range: -1000...10_000),
        ControlDefinition(.verticalScale, "Vertical Scale", .text, defaults: [100], unit: "%", range: 1...10_000),
        ControlDefinition(.horizontalScale, "Horizontal Scale", .text, defaults: [100], unit: "%", range: 1...10_000),
        // Up from the baseline.
        ControlDefinition(.baselineShift, "Baseline Shift", .text, defaults: [0], unit: " px", range: -100_000...100_000),
        // Each letter about its own middle, clockwise.
        ControlDefinition(.characterRotation, "Character Rotation", .text, defaults: [0], unit: "°"),
        ControlDefinition(.textCase, "Case", .text, choice: TextCase.normal),
        ControlDefinition(.underline, "Underline", .text, choice: OnOff.off),
        ControlDefinition(.strikethrough, "Strikethrough", .text, choice: OnOff.off),
        // Paragraph
        ControlDefinition(.textAlign, "Alignment", .text, choice: TextAlign.center),
        ControlDefinition(.leftIndent, "Left Indent", .text, defaults: [0], unit: " px", range: 0...100_000),
        ControlDefinition(.rightIndent, "Right Indent", .text, defaults: [0], unit: " px", range: 0...100_000),
        // Below 0 hangs the first line out to the left.
        ControlDefinition(.firstLineIndent, "First Line Indent", .text, defaults: [0], unit: " px", range: -100_000...100_000),
        ControlDefinition(.spaceBefore, "Space Before", .text, defaults: [0], unit: " px", range: 0...100_000),
        ControlDefinition(.spaceAfter, "Space After", .text, defaults: [0], unit: " px", range: 0...100_000),
        // 0 sets each paragraph on one line.
        ControlDefinition(.wrapWidth, "Wrap Width", .text, defaults: [0], unit: " px", range: 0...100_000),
        // Breaks a word across wrapped lines with a hyphen.
        ControlDefinition(.hyphenate, "Hyphenate", .text, choice: OnOff.off),
        // Which point of the block sits at Position.
        ControlDefinition(.textAnchor, "Anchor", .text, choice: TextAnchor.center),
        // Path: on, the text follows the shape above it in the stack, from
        // Path Offset pixels along it.
        ControlDefinition(.textOnPath, "On Path", .text, choice: OnOff.off),
        ControlDefinition(.pathOffset, "Path Offset", .text, defaults: [0], unit: " px"),
        // The other side of the path, running the other way.
        ControlDefinition(.pathFlip, "Flip", .text, choice: OnOff.off),
        // OpenType
        ControlDefinition(.ligatures, "Ligatures", .text, choice: TextLigatures.standard),
        ControlDefinition(.contextualAlternates, "Contextual Alternates", .text, choice: OnOff.on),
        ControlDefinition(.figures, "Figures", .text, choice: TextFigures.default),
        ControlDefinition(.fractions, "Fractions", .text, choice: OnOff.off),
        ControlDefinition(.ordinals, "Ordinals", .text, choice: OnOff.off),
        ControlDefinition(.swash, "Swash", .text, choice: OnOff.off),
        ControlDefinition(.stylisticAlternates, "Stylistic Alternates", .text, choice: OnOff.off),
        // ss01 to ss20; 0 for none.
        ControlDefinition(.stylisticSet, "Stylistic Set", .text, defaults: [0], range: 0...20, isWhole: true),
        // Text Animator: a range of the units, in percent of them all, and
        // what it does to what it selects, in proportion to how much.
        ControlDefinition(.animatorStart, "Start", .textAnimator, defaults: [0], unit: "%", range: 0...100),
        ControlDefinition(.animatorEnd, "End", .textAnimator, defaults: [100], unit: "%", range: 0...100),
        ControlDefinition(.animatorOffset, "Offset", .textAnimator, defaults: [0], unit: "%", range: -100...100),
        ControlDefinition(.animatorUnit, "Based On", .textAnimator, choice: TextAnimatorUnit.characters),
        ControlDefinition(.animatorShape, "Shape", .textAnimator, choice: TextAnimatorShape.square),
        ControlDefinition(
            .animatorPosition, "Position", .textAnimator, defaults: [0, 0], unit: " px", componentNames: ["Δx", "Δy"]
        ),
        ControlDefinition(.animatorScale, "Scale", .textAnimator, defaults: [100], unit: "%", range: 0...10_000),
        ControlDefinition(.animatorRotation, "Rotation", .textAnimator, defaults: [0], unit: "°"),
        ControlDefinition(.animatorOpacity, "Opacity", .textAnimator, defaults: [100], unit: "%", range: 0...100),
        // Starts off: on, the letters take this color.
        ControlDefinition(.animatorFill, "Fill", .textAnimator, defaults: [1, 0.3, 0.2, 1], dragStep: 0.01, range: 0...1, isColor: true),
        // Starts off: on, the strokes of the letters it selects take this color.
        ControlDefinition(.animatorStroke, "Stroke", .textAnimator, defaults: [0.2, 0.5, 1, 1], dragStep: 0.01, range: 0...1, isColor: true),
        // Thousandths of an em after each selected letter.
        ControlDefinition(.animatorTracking, "Tracking", .textAnimator, defaults: [0], range: -1000...10_000),
        // EQ
        ControlDefinition(.eqLowCut, band: .lowCut),
        ControlDefinition(.eqLowCutSlope, "Low Slope", .equalizer, choice: EqualizerSlope.db12),
        ControlDefinition(.eqLowShelf, band: .lowShelf),
        ControlDefinition(.eqBell1, band: .bell1),
        ControlDefinition(.eqBell2, band: .bell2),
        ControlDefinition(.eqBell3, band: .bell3),
        ControlDefinition(.eqBell4, band: .bell4),
        ControlDefinition(.eqHighShelf, band: .highShelf),
        ControlDefinition(.eqHighCut, band: .highCut),
        ControlDefinition(.eqHighCutSlope, "High Slope", .equalizer, choice: EqualizerSlope.db12),
        ControlDefinition(.eqOutput, "Output", .equalizer, defaults: [0], unit: " dB", dragStep: 0.1, range: Equalizer.gains),
        // Compressor
        ControlDefinition(.threshold, "Threshold", .compressor, defaults: [-20], unit: " dB", range: -60...0),
        ControlDefinition(.headroom, "Headroom", .compressor, defaults: [5], unit: " dB", dragStep: 0.1, range: 0.1...40),
        ControlDefinition(.attack, "Attack", .compressor, defaults: [10], unit: " ms", range: 1...300),
        ControlDefinition(.release, "Release", .compressor, defaults: [100], unit: " ms", range: 10...3000),
        ControlDefinition(.makeup, "Makeup", .compressor, defaults: [0], unit: " dB", range: -20...40),
        // Limiter
        ControlDefinition(.drive, "Drive", .limiter, defaults: [0], unit: " dB", range: 0...24),
        ControlDefinition(.limiterRelease, "Release", .limiter, defaults: [5], unit: " ms", range: 1...40),
        // Voice Isolation
        ControlDefinition(.isolation, "Isolation", .voiceIsolation, defaults: [100], unit: "%", range: 0...100),
        // Audio Keys
        // A kick drum's range, and a gate and ceiling for a typical mix.
        ControlDefinition(
            .frequencyRange, "Frequencies", .audioKeys, defaults: [40, 120], unit: " Hz",
            range: Spectrogram.lowestFrequency...Spectrogram.highestFrequency, componentNames: ["Low", "High"]
        ),
        ControlDefinition(
            .levelRange, "Levels", .audioKeys, defaults: [-50, -10], unit: " dB", range: Spectrogram.floor...0,
            componentNames: ["Low", "High"]
        ),
        ControlDefinition(.keyAttack, "Attack", .audioKeys, defaults: [0], unit: " ms", range: 0...2000),
        ControlDefinition(.keyRelease, "Release", .audioKeys, defaults: [200], unit: " ms", range: 0...5000),
        ControlDefinition(.outputRange, "Output", .audioKeys, defaults: [0, 10], componentNames: ["From", "To"]),
        ControlDefinition(.keyCurve, "Curve", .audioKeys, choice: KeyCurve.linear),
        // Beat Keys
        ControlDefinition(.beatSelection, "Beats", .beatKeys, choice: BeatSelection.every),
        ControlDefinition(.everyBeats, "Every", .beatKeys, defaults: [1], unit: " beats", range: 1...64, isWhole: true),
        ControlDefinition(.beatOffset, "Offset", .beatKeys, defaults: [0], unit: " beats", range: 0...63, isWhole: true),
        ControlDefinition(.accent, "Accent", .beatKeys, defaults: [50], unit: "%", range: 0...1000),
        ControlDefinition(.beatShape, "Shape", .beatKeys, choice: BeatShape.pulse),
        ControlDefinition(.peak, "Peak", .beatKeys, defaults: [10]),
        ControlDefinition(.decay, "Decay", .beatKeys, defaults: [250], unit: " ms", range: 0...10_000),
        // Wiggler
        ControlDefinition(.wiggleFrequency, "Frequency", .wiggler, defaults: [2], unit: "/s", dragStep: 0.1, range: 0...60),
        ControlDefinition(.magnitude, "Magnitude", .wiggler, defaults: [10]),
        ControlDefinition(.wiggleType, "Type", .wiggler, choice: WiggleType.smooth),
        ControlDefinition(.octaves, "Octaves", .wiggler, defaults: [1], range: 1...8, isWhole: true),
        ControlDefinition(.wiggleDimensions, "Dimensions", .wiggler, choice: WiggleDimensions.independent),
        ControlDefinition(.seed, "Seed", .wiggler, defaults: [1], range: 0...100_000, isWhole: true),
        ControlDefinition(.tolerance, "Tolerance", .wiggler, defaults: [0.5], unit: "%", dragStep: 0.1, range: 0...50),
        // Oscillator
        ControlDefinition(.wave, "Wave", .oscillator, choice: OscillatorWave.sine),
        ControlDefinition(
            .oscillatorFrequency, "Frequency", .oscillator, defaults: [1], unit: " Hz", dragStep: 0.1, range: 0...60
        ),
        ControlDefinition(.amplitude, "Amplitude", .oscillator, defaults: [10]),
        ControlDefinition(.phase, "Phase", .oscillator, defaults: [0], unit: "°"),
        ControlDefinition(.fade, "Fade", .oscillator, defaults: [0], unit: " s", dragStep: 0.1, range: 0...60),
        // Smoother
        ControlDefinition(.smoothing, "Strength", .smoother, defaults: [5], unit: " frames", range: 1...240, isWhole: true),
        // Looper
        ControlDefinition(.loopMode, "Mode", .looper, choice: LoopMode.cycle),
        ControlDefinition(.loopSide, "Repeat", .looper, choice: LoopSide.after),
        // Time Step
        ControlDefinition(.hold, "Hold", .timeStep, defaults: [2], unit: " frames", range: 1...120, isWhole: true),
        // Overshoot
        ControlDefinition(.stiffness, "Stiffness", .overshoot, defaults: [200], range: 1...10_000),
        ControlDefinition(.damping, "Damping", .overshoot, defaults: [8], range: 0...1000),
        ControlDefinition(.mass, "Mass", .overshoot, defaults: [1], dragStep: 0.1, range: 0.01...100),
    ]
}
