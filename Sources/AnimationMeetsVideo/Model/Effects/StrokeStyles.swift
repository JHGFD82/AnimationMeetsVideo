import CoreGraphics
import Foundation

/// Which side of an outline a stroke is drawn on (see
/// docs/graphic-layers.md, "Strokes").
enum StrokeEdge: String, CaseIterable, Identifiable, Sendable {
    /// Straddling the outline, half its width each side.
    case center
    /// Inside the outline, so the shape keeps its size.
    case inside
    /// Outside the outline, so it never covers the shape.
    case outside

    var id: Self { self }

    var name: String {
        switch self {
        case .center: "Center"
        case .inside: "Inside"
        case .outside: "Outside"
        }
    }
}

/// How a stroke turns a corner.
enum StrokeJoin: String, CaseIterable, Identifiable, Sendable {
    case miter, round, bevel

    var id: Self { self }

    var name: String {
        switch self {
        case .miter: "Miter"
        case .round: "Round"
        case .bevel: "Bevel"
        }
    }

    var cgJoin: CGLineJoin {
        switch self {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
    }
}

/// How a stroke's dashes end.
enum StrokeCap: String, CaseIterable, Identifiable, Sendable {
    case butt, round, square

    var id: Self { self }

    var name: String {
        switch self {
        case .butt: "Flat"
        case .round: "Round"
        case .square: "Square"
        }
    }

    var cgCap: CGLineCap {
        switch self {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }
}
