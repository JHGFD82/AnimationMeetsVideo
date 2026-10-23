import Foundation

// The effect and control kinds built into the app, and what each is (see
// `EffectRegistry`).

extension EffectKind {
    static let transform = EffectKind(builtIn: "transform")
    static let blending = EffectKind(builtIn: "blending")
    static let color = EffectKind(builtIn: "color")
    static let matte = EffectKind(builtIn: "matte")
    /// Color looks (see docs/psychedelic-effects.md): each remaps every
    /// pixel's color on its own, and nothing moves.
    static let hueCycle = EffectKind(builtIn: "hueCycle")
    static let cosinePalette = EffectKind(builtIn: "cosinePalette")
    static let gradientMap = EffectKind(builtIn: "gradientMap")
    static let solarize = EffectKind(builtIn: "solarize")
    static let posterize = EffectKind(builtIn: "posterize")
    static let channelMixer = EffectKind(builtIn: "channelMixer")
    static let falseColor = EffectKind(builtIn: "falseColor")
    /// Its edges are found between neighboring pixels.
    static let neonEdges = EffectKind(builtIn: "neonEdges")
    /// Noise looks: grain and glitches over the picture, or generators
    /// that replace it.
    static let grain = EffectKind(builtIn: "grain")
    static let staticNoise = EffectKind(builtIn: "staticNoise")
    static let fractalNoise = EffectKind(builtIn: "fractalNoise")
    static let cells = EffectKind(builtIn: "cells")
    /// A dither's pattern is a pixel's.
    static let dither = EffectKind(builtIn: "dither")
    static let interference = EffectKind(builtIn: "interference")
    static let blockGlitch = EffectKind(builtIn: "blockGlitch")
    /// Distortion looks: they move the picture's pixels.
    static let displace = EffectKind(builtIn: "displace")
    static let liquid = EffectKind(builtIn: "liquid")
    static let twirl = EffectKind(builtIn: "twirl")
    static let wave = EffectKind(builtIn: "wave")
    static let kaleidoscope = EffectKind(builtIn: "kaleidoscope")
    static let mirrorTile = EffectKind(builtIn: "mirrorTile")
    static let chromaticAberration = EffectKind(builtIn: "chromaticAberration")
    /// Distortions drawn from the picture at several moments. Flow
    /// Smear's motion is measured between neighboring pixels.
    static let flowSmear = EffectKind(builtIn: "flowSmear")
    static let slitScan = EffectKind(builtIn: "slitScan")
    static let feedback = EffectKind(builtIn: "feedback")
    /// Shapes draw over the picture handed down to them (see
    /// docs/graphic-layers.md, "Shapes").
    static let rectangle = EffectKind(builtIn: "rectangle")
    static let ellipse = EffectKind(builtIn: "ellipse")
    static let polygon = EffectKind(builtIn: "polygon")
    static let star = EffectKind(builtIn: "star")
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

    /// How a shape is filled and stroked, after what shapes it.
    static let paintControls: [ControlKind] = [.fill, .stroke, .strokeWidth, .strokeEdge, .strokeJoin, .strokeCap, .dash]
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
    // Hue Cycle
    static let hueSpeed = ControlKind(builtIn: "hueSpeed")
    static let hueSpread = ControlKind(builtIn: "hueSpread")
    static let saturationBoost = ControlKind(builtIn: "saturationBoost")
    // Cosine Palette
    static let palette = ControlKind(builtIn: "palette")
    static let cycleSpeed = ControlKind(builtIn: "cycleSpeed")
    static let paletteBias = ControlKind(builtIn: "paletteBias")
    static let paletteAmplitude = ControlKind(builtIn: "paletteAmplitude")
    static let paletteFrequency = ControlKind(builtIn: "paletteFrequency")
    static let palettePhase = ControlKind(builtIn: "palettePhase")
    // Gradient Map
    static let shadowColor = ControlKind(builtIn: "shadowColor")
    static let midtoneColor = ControlKind(builtIn: "midtoneColor")
    static let highlightColor = ControlKind(builtIn: "highlightColor")
    static let repeats = ControlKind(builtIn: "repeats")
    static let scrollSpeed = ControlKind(builtIn: "scrollSpeed")
    // Solarize
    static let solarizeLevel = ControlKind(builtIn: "solarizeLevel")
    static let folds = ControlKind(builtIn: "folds")
    static let solarizeChannels = ControlKind(builtIn: "solarizeChannels")
    // Posterize
    static let levels = ControlKind(builtIn: "levels")
    // Channel Mixer
    static let mixRed = ControlKind(builtIn: "mixRed")
    static let mixGreen = ControlKind(builtIn: "mixGreen")
    static let mixBlue = ControlKind(builtIn: "mixBlue")
    static let mixOffset = ControlKind(builtIn: "mixOffset")
    // False Color
    static let falseColorLook = ControlKind(builtIn: "falseColorLook")
    // Neon Edges
    static let edgeWidth = ControlKind(builtIn: "edgeWidth")
    static let glow = ControlKind(builtIn: "glow")
    static let edgeColoring = ControlKind(builtIn: "edgeColoring")
    static let edgeColor = ControlKind(builtIn: "edgeColor")
    // Grain
    static let grainSize = ControlKind(builtIn: "grainSize")
    static let grainChannels = ControlKind(builtIn: "grainChannels")
    // Static
    static let bars = ControlKind(builtIn: "bars")
    static let rollSpeed = ControlKind(builtIn: "rollSpeed")
    // Fractal Noise
    static let noiseScale = ControlKind(builtIn: "noiseScale")
    static let noiseOctaves = ControlKind(builtIn: "noiseOctaves")
    static let roughness = ControlKind(builtIn: "roughness")
    static let noiseType = ControlKind(builtIn: "noiseType")
    static let evolution = ControlKind(builtIn: "evolution")
    // Cells
    static let cellSize = ControlKind(builtIn: "cellSize")
    static let jitter = ControlKind(builtIn: "jitter")
    static let cellOutput = ControlKind(builtIn: "cellOutput")
    // Dither
    static let ditherLevels = ControlKind(builtIn: "ditherLevels")
    static let ditherPattern = ControlKind(builtIn: "ditherPattern")
    // Interference
    static let spacing = ControlKind(builtIn: "spacing")
    static let crossAngle = ControlKind(builtIn: "crossAngle")
    static let driftSpeed = ControlKind(builtIn: "driftSpeed")
    // Block Glitch
    static let intensity = ControlKind(builtIn: "intensity")
    static let blockSize = ControlKind(builtIn: "blockSize")
    static let glitchRate = ControlKind(builtIn: "glitchRate")
    // Displace
    static let displacement = ControlKind(builtIn: "displacement")
    static let mapCenter = ControlKind(builtIn: "mapCenter")
    // Liquid
    static let warps = ControlKind(builtIn: "warps")
    // Twirl
    static let twirlShape = ControlKind(builtIn: "twirlShape")
    static let distortCenter = ControlKind(builtIn: "distortCenter")
    static let distortRadius = ControlKind(builtIn: "distortRadius")
    static let twirlAmount = ControlKind(builtIn: "twirlAmount")
    // Wave
    static let waveDirection = ControlKind(builtIn: "waveDirection")
    static let wavelength = ControlKind(builtIn: "wavelength")
    static let waveHeight = ControlKind(builtIn: "waveHeight")
    static let waveSpeed = ControlKind(builtIn: "waveSpeed")
    // Kaleidoscope
    static let segments = ControlKind(builtIn: "segments")
    static let distortAngle = ControlKind(builtIn: "distortAngle")
    static let spinSpeed = ControlKind(builtIn: "spinSpeed")
    // Mirror Tile
    static let tilePattern = ControlKind(builtIn: "tilePattern")
    static let tileSize = ControlKind(builtIn: "tileSize")
    // Chromatic Aberration
    static let aberration = ControlKind(builtIn: "aberration")
    static let aberrationMode = ControlKind(builtIn: "aberrationMode")
    // Flow Smear
    static let smear = ControlKind(builtIn: "smear")
    static let framesAhead = ControlKind(builtIn: "framesAhead")
    // Slit-Scan
    static let slitDirection = ControlKind(builtIn: "slitDirection")
    static let bands = ControlKind(builtIn: "bands")
    static let timeSpread = ControlKind(builtIn: "timeSpread")
    // Feedback
    static let copies = ControlKind(builtIn: "copies")
    static let feedbackDelay = ControlKind(builtIn: "feedbackDelay")
    static let copyScale = ControlKind(builtIn: "copyScale")
    static let copyRotation = ControlKind(builtIn: "copyRotation")
    static let hueStep = ControlKind(builtIn: "hueStep")
    static let copyDecay = ControlKind(builtIn: "copyDecay")
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
    /// In the library's order.
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
            controls: [.exposure, .contrast, .saturation, .temperature, .tint, .lift, .gamma, .gain]
        ),
        EffectDefinition(
            .matte, "Matte", .mattes, "circle.dashed.inset.filled", controls: [.matteMode, .amount], takesInput: true
        ),
        // Color looks (see docs/psychedelic-effects.md): each remaps every
        // pixel's color on its own, and nothing moves.
        EffectDefinition(
            .hueCycle, "Hue Cycle", .recolor, "paintpalette", controls: [.hueSpeed, .hueSpread, .saturationBoost, .amount]
        ),
        EffectDefinition(
            .cosinePalette, "Cosine Palette", .recolor, "rainbow",
            controls: [.palette, .cycleSpeed, .paletteBias, .paletteAmplitude, .paletteFrequency, .palettePhase, .amount]
        ),
        EffectDefinition(
            .gradientMap, "Gradient Map", .recolor, "slider.horizontal.below.rectangle",
            controls: [.shadowColor, .midtoneColor, .highlightColor, .repeats, .scrollSpeed, .amount]
        ),
        EffectDefinition(
            .solarize, "Solarize", .recolor, "sun.max.trianglebadge.exclamationmark",
            controls: [.solarizeLevel, .folds, .solarizeChannels, .amount]
        ),
        EffectDefinition(.posterize, "Posterize", .recolor, "square.stack.3d.down.forward", controls: [.levels, .amount]),
        EffectDefinition(
            .channelMixer, "Channel Mixer", .recolor, "circle.grid.cross",
            controls: [.mixRed, .mixGreen, .mixBlue, .mixOffset, .amount]
        ),
        EffectDefinition(
            .falseColor, "False Color", .recolor, "thermometer.sun",
            controls: [.falseColorLook, .shadowColor, .highlightColor, .amount]
        ),
        // Its edges are found between neighboring pixels.
        EffectDefinition(
            .neonEdges, "Neon Edges", .recolor, "scribble", controls: [.edgeWidth, .glow, .edgeColoring, .edgeColor, .amount],
            dependsOnPixelSize: true
        ),
        // Noise looks: grain and glitches over the picture, or generators
        // that replace it.
        EffectDefinition(.grain, "Grain", .noise, "circle.dotted", controls: [.amount, .grainSize, .grainChannels, .seed]),
        EffectDefinition(
            .staticNoise, "Static", .noise, "tv", controls: [.grainSize, .bars, .rollSpeed, .seed, .amount], generates: true
        ),
        EffectDefinition(
            .fractalNoise, "Fractal Noise", .noise, "cloud",
            controls: [.noiseScale, .noiseOctaves, .roughness, .noiseType, .evolution, .seed, .amount], generates: true
        ),
        EffectDefinition(
            .cells, "Cells", .noise, "circle.hexagongrid",
            controls: [.cellSize, .jitter, .cellOutput, .evolution, .seed, .amount], generates: true
        ),
        // A dither's pattern is a pixel's.
        EffectDefinition(
            .dither, "Dither", .noise, "checkerboard.rectangle", controls: [.ditherLevels, .ditherPattern, .amount],
            dependsOnPixelSize: true
        ),
        EffectDefinition(
            .interference, "Interference", .noise, "line.3.horizontal.decrease",
            controls: [.spacing, .crossAngle, .driftSpeed, .amount], generates: true
        ),
        EffectDefinition(
            .blockGlitch, "Block Glitch", .noise, "rectangle.split.3x3",
            controls: [.intensity, .blockSize, .glitchRate, .seed, .amount]
        ),
        // Distortion looks: they move the picture's pixels.
        EffectDefinition(
            .displace, "Displace", .distortion, "arrow.up.and.down.and.arrow.left.and.right",
            controls: [.displacement, .mapCenter], takesInput: true, readsAgainst: true
        ),
        EffectDefinition(
            .liquid, "Liquid", .distortion, "drop", controls: [.displacement, .noiseScale, .warps, .evolution, .seed]
        ),
        EffectDefinition(
            .twirl, "Twirl", .distortion, "tornado", controls: [.twirlShape, .distortCenter, .distortRadius, .twirlAmount]
        ),
        EffectDefinition(
            .wave, "Wave", .distortion, "water.waves", controls: [.waveDirection, .wavelength, .waveHeight, .waveSpeed]
        ),
        EffectDefinition(
            .kaleidoscope, "Kaleidoscope", .distortion, "seal", controls: [.segments, .distortCenter, .distortAngle, .spinSpeed]
        ),
        EffectDefinition(
            .mirrorTile, "Mirror Tile", .distortion, "square.grid.2x2",
            controls: [.tilePattern, .tileSize, .distortCenter, .distortAngle]
        ),
        EffectDefinition(
            .chromaticAberration, "Chromatic Aberration", .distortion, "camera.filters",
            controls: [.aberration, .aberrationMode, .distortCenter, .distortAngle]
        ),
        // Distortions drawn from the picture at several moments. Flow
        // Smear's motion is measured between neighboring pixels.
        EffectDefinition(
            .flowSmear, "Flow Smear", .distortion, "wind", controls: [.smear, .framesAhead], dependsOnPixelSize: true
        ),
        EffectDefinition(
            .slitScan, "Slit-Scan", .distortion, "line.3.horizontal",
            controls: [.slitDirection, .bands, .timeSpread, .distortCenter]
        ),
        EffectDefinition(
            .feedback, "Feedback", .distortion, "circle.circle",
            controls: [.copies, .feedbackDelay, .copyScale, .copyRotation, .hueStep, .copyDecay, .distortCenter]
        ),
        // Shapes draw over the picture handed down to them (see
        // docs/graphic-layers.md, "Shapes").
        EffectDefinition(
            .rectangle, "Rectangle", .shapes, "rectangle",
            controls: [.shapeSize, .cornerRadius, .shapePosition] + EffectKind.paintControls
        ),
        EffectDefinition(
            .ellipse, "Ellipse", .shapes, "circle", controls: [.shapeSize, .shapePosition] + EffectKind.paintControls
        ),
        EffectDefinition(
            .polygon, "Polygon", .shapes, "hexagon",
            controls: [.points, .radius, .cornerRadius, .shapeRotation, .shapePosition] + EffectKind.paintControls
        ),
        EffectDefinition(
            .star, "Star", .shapes, "star",
            controls: [.points, .radius, .innerRadius, .cornerRadius, .shapeRotation, .shapePosition] + EffectKind.paintControls
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
            controls: [.frequencyRange, .levelRange, .keyAttack, .keyRelease, .outputRange, .keyCurve, .tolerance]
        ),
        EffectDefinition(
            .beatKeys, "Beat Keys", .keyframing, "metronome",
            controls: [.beatSelection, .everyBeats, .beatOffset, .accent, .beatShape, .peak, .decay, .tolerance]
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
        // Hue Cycle
        ControlDefinition(.hueSpeed, "Speed", .hueCycle, defaults: [0.25], unit: " turns/s", dragStep: 0.01, range: -20...20),
        ControlDefinition(.hueSpread, "Spread", .hueCycle, defaults: [0], unit: "°", range: -1080...1080),
        ControlDefinition(.saturationBoost, "Saturation", .hueCycle, defaults: [0], unit: "%", range: -100...400),
        // Cosine Palette
        ControlDefinition(.palette, "Palette", .cosinePalette, choice: PaletteLook.rainbow),
        ControlDefinition(.cycleSpeed, "Speed", .cosinePalette, defaults: [0], unit: " /s", dragStep: 0.01, range: -20...20),
        ControlDefinition(
            .paletteBias, "Bias", .cosinePalette, defaults: PaletteLook.rainbow.vectors.bias, dragStep: 0.01, range: -2...2,
            componentNames: ["Red", "Green", "Blue"]
        ),
        ControlDefinition(
            .paletteAmplitude, "Amplitude", .cosinePalette, defaults: PaletteLook.rainbow.vectors.amplitude, dragStep: 0.01,
            range: -2...2, componentNames: ["Red", "Green", "Blue"]
        ),
        ControlDefinition(
            .paletteFrequency, "Frequency", .cosinePalette, defaults: PaletteLook.rainbow.vectors.frequency, dragStep: 0.01,
            range: 0...8, componentNames: ["Red", "Green", "Blue"]
        ),
        ControlDefinition(
            .palettePhase, "Phase", .cosinePalette, defaults: PaletteLook.rainbow.vectors.phase, dragStep: 0.01, range: -2...2,
            componentNames: ["Red", "Green", "Blue"]
        ),
        // Gradient Map
        // A lava gradient, and a navy-to-amber duotone.
        ControlDefinition(
            .shadowColor, "Shadows", .gradientMap, defaults: [0.08, 0.02, 0.18, 1], dragStep: 0.01, range: 0...1, isColor: true
        ),
        ControlDefinition(
            .midtoneColor, "Midtones", .gradientMap, defaults: [0.9, 0.25, 0.05, 1], dragStep: 0.01, range: 0...1, isColor: true
        ),
        ControlDefinition(
            .highlightColor, "Highlights", .gradientMap, defaults: [1, 0.92, 0.55, 1], dragStep: 0.01, range: 0...1,
            isColor: true
        ),
        ControlDefinition(.repeats, "Repeat", .gradientMap, defaults: [1], range: 1...32, isWhole: true),
        ControlDefinition(.scrollSpeed, "Speed", .gradientMap, defaults: [0], unit: " /s", dragStep: 0.01, range: -20...20),
        // Solarize
        ControlDefinition(.solarizeLevel, "Threshold", .solarize, defaults: [50], unit: "%", range: 1...99),
        ControlDefinition(.folds, "Folds", .solarize, defaults: [1], range: 1...16, isWhole: true),
        ControlDefinition(.solarizeChannels, "Channels", .solarize, choice: SolarizeChannels.luminance),
        // Posterize
        ControlDefinition(.levels, "Levels", .posterize, defaults: [6], range: 2...64, isWhole: true),
        // Channel Mixer
        ControlDefinition(
            .mixRed, "Red From", .channelMixer, defaults: [1, 0, 0], dragStep: 0.01, range: -4...4,
            componentNames: ["Red", "Green", "Blue"]
        ),
        ControlDefinition(
            .mixGreen, "Green From", .channelMixer, defaults: [0, 1, 0], dragStep: 0.01, range: -4...4,
            componentNames: ["Red", "Green", "Blue"]
        ),
        ControlDefinition(
            .mixBlue, "Blue From", .channelMixer, defaults: [0, 0, 1], dragStep: 0.01, range: -4...4,
            componentNames: ["Red", "Green", "Blue"]
        ),
        ControlDefinition(
            .mixOffset, "Offset", .channelMixer, defaults: [0, 0, 0], dragStep: 0.01, range: -1...1,
            componentNames: ["Red", "Green", "Blue"]
        ),
        // False Color
        ControlDefinition(.falseColorLook, "Look", .falseColor, choice: FalseColorLook.thermal),
        // Neon Edges
        ControlDefinition(.edgeWidth, "Width", .neonEdges, defaults: [2], unit: " px", dragStep: 0.1, range: 0.5...50),
        ControlDefinition(.glow, "Glow", .neonEdges, defaults: [50], unit: "%", range: 0...200),
        ControlDefinition(.edgeColoring, "Coloring", .neonEdges, choice: EdgeColoring.byAngle),
        ControlDefinition(
            .edgeColor, "Color", .neonEdges, defaults: [0.2, 1, 0.9, 1], dragStep: 0.01, range: 0...1, isColor: true
        ),
        // Grain
        ControlDefinition(.grainSize, "Size", .grain, defaults: [1], unit: " px", dragStep: 0.1, range: 0.25...64),
        ControlDefinition(.grainChannels, "Channels", .grain, choice: GrainChannels.mono),
        // Static
        ControlDefinition(.bars, "Bars", .staticNoise, defaults: [2], range: 0...16, isWhole: true),
        ControlDefinition(.rollSpeed, "Roll", .staticNoise, defaults: [0.5], unit: " /s", dragStep: 0.01, range: -20...20),
        // Fractal Noise
        ControlDefinition(.noiseScale, "Scale", .fractalNoise, defaults: [200], unit: " px", range: 2...10_000),
        ControlDefinition(.noiseOctaves, "Octaves", .fractalNoise, defaults: [4], range: 1...8, isWhole: true),
        ControlDefinition(.roughness, "Roughness", .fractalNoise, defaults: [50], unit: "%", range: 0...100),
        ControlDefinition(.noiseType, "Type", .fractalNoise, choice: NoiseType.smooth),
        ControlDefinition(.evolution, "Evolution", .fractalNoise, defaults: [0.25], unit: " /s", dragStep: 0.01, range: -20...20),
        // Cells
        ControlDefinition(.cellSize, "Cell Size", .cells, defaults: [80], unit: " px", range: 2...10_000),
        ControlDefinition(.jitter, "Jitter", .cells, defaults: [100], unit: "%", range: 0...100),
        ControlDefinition(.cellOutput, "Output", .cells, choice: CellOutput.edges),
        // Dither
        ControlDefinition(.ditherLevels, "Levels", .dither, defaults: [4], range: 2...64, isWhole: true),
        ControlDefinition(.ditherPattern, "Pattern", .dither, choice: DitherPattern.bayer4),
        // Interference
        ControlDefinition(.spacing, "Spacing", .interference, defaults: [8], unit: " px", range: 1...1000),
        ControlDefinition(.crossAngle, "Angle", .interference, defaults: [3], unit: "°", dragStep: 0.1, range: -90...90),
        ControlDefinition(.driftSpeed, "Drift", .interference, defaults: [0.5], unit: " /s", dragStep: 0.01, range: -20...20),
        // Block Glitch
        ControlDefinition(.intensity, "Intensity", .blockGlitch, defaults: [30], unit: "%", range: 0...100),
        ControlDefinition(.blockSize, "Block Size", .blockGlitch, defaults: [80], unit: " px", range: 2...2000),
        // Under three flashes a second (docs/psychedelic-effects.md, "Safety").
        ControlDefinition(.glitchRate, "Rate", .blockGlitch, defaults: [2], unit: " /s", range: 0...60),
        // Displace
        ControlDefinition(.displacement, "Amount", .displace, defaults: [2], unit: "%", dragStep: 0.1, range: -100...100),
        ControlDefinition(.mapCenter, "Still At", .displace, choice: MapCenter.gray),
        // Liquid
        ControlDefinition(.warps, "Warps", .liquid, defaults: [2], range: 1...4, isWhole: true),
        // Twirl
        ControlDefinition(.twirlShape, "Shape", .twirl, choice: TwirlShape.twirl),
        ControlDefinition(.distortCenter, "Center", .twirl, defaults: [0, 0], unit: " px", componentNames: ["Δx", "Δy"]),
        ControlDefinition(.distortRadius, "Radius", .twirl, defaults: [300], unit: " px", range: 1...50_000),
        ControlDefinition(.twirlAmount, "Amount", .twirl, defaults: [100], unit: "%", range: -1000...1000),
        // Wave
        ControlDefinition(.waveDirection, "Direction", .wave, choice: WaveDirection.horizontal),
        ControlDefinition(.wavelength, "Wavelength", .wave, defaults: [120], unit: " px", range: 2...50_000),
        ControlDefinition(.waveHeight, "Height", .wave, defaults: [12], unit: " px", range: -10_000...10_000),
        ControlDefinition(.waveSpeed, "Speed", .wave, defaults: [1], unit: " /s", dragStep: 0.01, range: -20...20),
        // Kaleidoscope
        ControlDefinition(.segments, "Segments", .kaleidoscope, defaults: [6], range: 2...64, isWhole: true),
        ControlDefinition(.distortAngle, "Angle", .kaleidoscope, defaults: [0], unit: "°"),
        ControlDefinition(.spinSpeed, "Speed", .kaleidoscope, defaults: [0], unit: " /s", dragStep: 0.01, range: -20...20),
        // Mirror Tile
        ControlDefinition(.tilePattern, "Pattern", .mirrorTile, choice: TilePattern.fourfold),
        ControlDefinition(.tileSize, "Tile Size", .mirrorTile, defaults: [480], unit: " px", range: 1...50_000),
        // Chromatic Aberration
        ControlDefinition(.aberration, "Amount", .chromaticAberration, defaults: [1], unit: "%", dragStep: 0.1, range: -20...20),
        ControlDefinition(.aberrationMode, "Mode", .chromaticAberration, choice: AberrationMode.radial),
        // Flow Smear
        ControlDefinition(.smear, "Amount", .flowSmear, defaults: [100], unit: "%", range: 0...400),
        ControlDefinition(.framesAhead, "Frames Ahead", .flowSmear, defaults: [1], unit: " frames", range: 1...8, isWhole: true),
        // Slit-Scan
        ControlDefinition(.slitDirection, "Direction", .slitScan, choice: SlitDirection.rows),
        ControlDefinition(.bands, "Bands", .slitScan, defaults: [16], range: 2...64, isWhole: true),
        ControlDefinition(.timeSpread, "Time Spread", .slitScan, defaults: [0.5], unit: " s", range: 0...10),
        // Feedback
        ControlDefinition(.copies, "Copies", .feedback, defaults: [8], range: 1...32, isWhole: true),
        ControlDefinition(.feedbackDelay, "Delay", .feedback, defaults: [1], unit: " frames", range: 1...30, isWhole: true),
        ControlDefinition(.copyScale, "Scale", .feedback, defaults: [103], unit: "%", range: 10...1000),
        ControlDefinition(.copyRotation, "Rotation", .feedback, defaults: [4], unit: "°", range: -360...360),
        ControlDefinition(.hueStep, "Hue Shift", .feedback, defaults: [15], unit: "°", range: -360...360),
        ControlDefinition(.copyDecay, "Decay", .feedback, defaults: [30], unit: "%", range: 0...100),
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
