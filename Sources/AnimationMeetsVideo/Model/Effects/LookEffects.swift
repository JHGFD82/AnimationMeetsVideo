import Foundation

// The choices of the Color and Noise looks (see docs/psychedelic-effects.md).

/// Cosine Palette's starting palettes: each a set of the four vectors in
/// `a + b·cos(2π(c·t + d))` (Inigo Quilez's palettes), or the person's own.
enum PaletteLook: String, CaseIterable, Identifiable, Sendable {
    case rainbow, acid, infrared, oilSlick, custom

    var id: Self { self }

    var name: String {
        switch self {
        case .rainbow: "Rainbow"
        case .acid: "Acid"
        case .infrared: "Infrared"
        case .oilSlick: "Oil Slick"
        case .custom: "Custom"
        }
    }

    /// Bias (a), amplitude (b), frequency (c) and phase (d), each for red,
    /// green and blue. Custom takes them from the effect's controls.
    var vectors: (bias: [Double], amplitude: [Double], frequency: [Double], phase: [Double]) {
        switch self {
        case .rainbow, .custom: ([0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [1, 1, 1], [0, 0.33, 0.67])
        case .acid: ([0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [2, 1, 0], [0.5, 0.2, 0.25])
        case .infrared: ([0.8, 0.5, 0.4], [0.2, 0.4, 0.2], [2, 1, 1], [0, 0.25, 0.25])
        case .oilSlick: ([0.5, 0.5, 0.5], [0.5, 0.5, 0.5], [1, 0.7, 0.4], [0, 0.15, 0.2])
        }
    }
}

/// What Solarize folds: the brightness, keeping each color's hue, or each
/// channel on its own, which shifts hues too.
enum SolarizeChannels: String, CaseIterable, Identifiable, Sendable {
    case luminance, each

    var id: Self { self }

    var name: String {
        switch self {
        case .luminance: "Brightness"
        case .each: "Each Channel"
        }
    }
}

enum FalseColorLook: String, CaseIterable, Identifiable, Sendable {
    case thermal, xray, duotone

    var id: Self { self }

    var name: String {
        switch self {
        case .thermal: "Thermal"
        case .xray: "X-Ray"
        case .duotone: "Duotone"
        }
    }
}

/// How Neon Edges colors its outlines.
enum EdgeColoring: String, CaseIterable, Identifiable, Sendable {
    /// Around the color wheel by the edge's direction.
    case byAngle
    case oneColor

    var id: Self { self }

    var name: String {
        switch self {
        case .byAngle: "By Direction"
        case .oneColor: "One Color"
        }
    }
}

enum GrainChannels: String, CaseIterable, Identifiable, Sendable {
    case mono, color

    var id: Self { self }

    var name: String {
        switch self {
        case .mono: "Mono"
        case .color: "Color"
        }
    }
}

/// How Fractal Noise's octaves are summed: smooth clouds, turbulent
/// (folded at zero, billowing) or ridged (sharp crests, as marble).
enum NoiseType: String, CaseIterable, Identifiable, Sendable {
    case smooth, turbulent, ridged

    var id: Self { self }

    var name: String {
        switch self {
        case .smooth: "Smooth"
        case .turbulent: "Turbulent"
        case .ridged: "Ridged"
        }
    }
}

/// What Cells draws: bright edges between cells, the distance to each
/// cell's middle, or each cell one flat gray.
enum CellOutput: String, CaseIterable, Identifiable, Sendable {
    case edges, distance, flat

    var id: Self { self }

    var name: String {
        switch self {
        case .edges: "Edges"
        case .distance: "Distance"
        case .flat: "Flat Cells"
        }
    }
}

enum DitherPattern: String, CaseIterable, Identifiable, Sendable {
    case bayer4, bayer8, noise

    var id: Self { self }

    var name: String {
        switch self {
        case .bayer4: "Bayer 4×4"
        case .bayer8: "Bayer 8×8"
        case .noise: "Noise"
        }
    }
}
