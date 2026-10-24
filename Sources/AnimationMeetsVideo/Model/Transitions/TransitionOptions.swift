import CoreGraphics
import Foundation

/// Which way a transition moves. For a wipe, the way its edge travels; for
/// a slide or push, the way the pictures travel.
enum TransitionDirection: String, CaseIterable, Identifiable, Sendable {
    case left, right, up, down

    var id: Self { self }

    var name: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        }
    }

    var systemImage: String {
        switch self {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }

    var isHorizontal: Bool { self == .left || self == .right }

    /// A unit step in the frame of a timeline, which measures y downward.
    var step: CGVector {
        switch self {
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        case .up: CGVector(dx: 0, dy: -1)
        case .down: CGVector(dx: 0, dy: 1)
        }
    }
}

/// A color a transition draws with, in the timeline's encoded values.
struct TransitionColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = TransitionColor(red: 0, green: 0, blue: 0)
    static let white = TransitionColor(red: 1, green: 1, blue: 1)
}

/// The shape an iris opens in.
enum IrisShape: String, CaseIterable, Identifiable, Sendable {
    case circle, diamond, box

    var id: Self { self }

    var name: String {
        switch self {
        case .circle: "Circle"
        case .diamond: "Diamond"
        case .box: "Box"
        }
    }
}

/// The order a grid's cells turn over in.
enum GridOrder: String, CaseIterable, Identifiable, Sendable {
    case random, diagonal

    var id: Self { self }

    var name: String {
        switch self {
        case .random: "Random"
        case .diagonal: "Diagonal"
        }
    }
}

/// What a matte wipe reads its map from: generated noise, or a frame of a
/// video in the project.
enum MatteSource: Hashable, Sendable {
    case noise
    case clip(UUID)
}

/// One thing about a transition a person can set besides its length and
/// curve. Each kind offers some of them (`TransitionKind.settings`).
enum TransitionSetting: Hashable, Sendable {
    case direction
    case color
    case center
    case shape
    case count
    case order
    case amount
    case matte
}

/// A transition's settings. Every kind has the same fields; each uses only
/// those listed in its `settings`, and only those are saved.
struct TransitionOptions: Equatable, Sendable {
    var direction: TransitionDirection = .right
    var color: TransitionColor = .black
    /// Where it centers, as fractions of the frame from its top left.
    var center = CGPoint(x: 0.5, y: 0.5)
    var shape: IrisShape = .circle
    /// How many strips or columns.
    var count = 8
    var order: GridOrder = .random
    /// How strong it is, from 0 to 1.
    var amount = 0.5
    var matte: MatteSource = .noise

    static let countRange = 2...32

    /// Clamped to what each field allows.
    var clamped: TransitionOptions {
        var options = self
        options.color = TransitionColor(
            red: color.red.clamped(between: 0, and: 1), green: color.green.clamped(between: 0, and: 1), blue: color.blue.clamped(between: 0, and: 1)
        )
        options.center = CGPoint(x: center.x.clamped(between: 0, and: 1), y: center.y.clamped(between: 0, and: 1))
        options.count = min(max(count, Self.countRange.lowerBound), Self.countRange.upperBound)
        options.amount = amount.clamped(between: 0, and: 1)
        return options
    }
}
