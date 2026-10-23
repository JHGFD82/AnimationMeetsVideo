import CoreMedia
import Foundation

// The choices of the Color, Noise and Distortion looks (see
// docs/psychedelic-effects.md).

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

/// Which of a Displace map's values leaves a pixel where it is.
enum MapCenter: String, CaseIterable, Identifiable, Sendable {
    /// Middle gray: darker moves one way, lighter the other.
    case gray
    /// Black: the map only ever pushes one way.
    case black

    var id: Self { self }

    var name: String {
        switch self {
        case .gray: "Gray"
        case .black: "Black"
        }
    }
}

enum TwirlShape: String, CaseIterable, Identifiable, Sendable {
    /// Turns most at the middle, fading out at the radius.
    case twirl
    /// Turns more the closer to the middle, like water down a drain.
    case vortex
    /// Draws the middle in.
    case pinch
    /// Pushes the middle out.
    case bulge

    var id: Self { self }

    var name: String {
        switch self {
        case .twirl: "Twirl"
        case .vortex: "Vortex"
        case .pinch: "Pinch"
        case .bulge: "Bulge"
        }
    }
}

enum WaveDirection: String, CaseIterable, Identifiable, Sendable {
    case horizontal, vertical, radial

    var id: Self { self }

    var name: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        case .radial: "Radial"
        }
    }
}

enum TilePattern: String, CaseIterable, Identifiable, Sendable {
    /// The same tile again and again.
    case tile
    /// Mirrored at every edge, so tiles meet seamlessly.
    case fourfold
    /// Mirrored across the diagonals too.
    case eightfold
    /// Into itself, smaller and smaller, as an endless spiral.
    case droste

    var id: Self { self }

    var name: String {
        switch self {
        case .tile: "Tile"
        case .fourfold: "Fourfold"
        case .eightfold: "Eightfold"
        case .droste: "Droste"
        }
    }
}

/// Which way Chromatic Aberration pulls red and blue apart.
enum AberrationMode: String, CaseIterable, Identifiable, Sendable {
    /// Out from the center, as a lens does.
    case radial
    /// Along one direction.
    case linear

    var id: Self { self }

    var name: String {
        switch self {
        case .radial: "Radial"
        case .linear: "Linear"
        }
    }
}

/// Which way Slit-Scan's bands run: each from a moment later than the last.
enum SlitDirection: String, CaseIterable, Identifiable, Sendable {
    /// Across, the top now.
    case rows
    /// Down, the left now.
    case columns
    /// Round the center, the middle now.
    case rings

    var id: Self { self }

    var name: String {
        switch self {
        case .rows: "Rows"
        case .columns: "Columns"
        case .rings: "Rings"
        }
    }
}

/// How long before the moment drawn each copy Feedback and Slit-Scan draw
/// from is, on the timeline's frames, so the composition and the
/// compositor agree on them, and copies can be shared.
enum MomentDelays {
    static func feedback(copy: Int, delayFrames: Int, frame: CMTime) -> CMTime {
        CMTimeMultiply(frame, multiplier: Int32(copy * max(delayFrames, 1)))
    }

    /// Band `band` of `bands` (0 is now) is `spread` seconds across the
    /// last, rounded to a frame.
    static func slit(band: Int, of bands: Int, spread: Double, frame: CMTime) -> CMTime {
        guard bands > 1, frame.seconds > 0 else { return .zero }
        let seconds = Double(band) / Double(bands - 1) * spread
        return CMTimeMultiply(frame, multiplier: Int32((seconds / frame.seconds).rounded()))
    }
}
