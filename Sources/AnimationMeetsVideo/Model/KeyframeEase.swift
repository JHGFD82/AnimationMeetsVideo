import CoreGraphics
import CoreMedia
import Foundation

/// How a value leaves a keyframe or arrives at one, as After Effects'
/// temporal ease: a bezier handle reaching `influence` of the way to the
/// neighboring keyframe in time, at `speed` relative to a steady move.
///
/// Between two keyframes the value follows a cubic bezier from (0, 0) to
/// (1, 1), time across and progress up, whose inner control points are the
/// first keyframe's outgoing handle and the second's incoming one. A side
/// without an ease is linear: its handle sits on the straight line, a
/// third of the way along, so two linear sides make a steady blend.
struct KeyframeEase: Equatable, Sendable {
    /// Share of the time to the neighboring keyframe the handle reaches.
    var influence: Double
    /// Speed at the keyframe as a multiple of the steady speed: 0 stops
    /// there, 1 is steady, more overshoots.
    var speed: Double

    static let influenceRange = 0.01...1.0
    static let speedRange = -10.0...10.0

    init(influence: Double, speed: Double) {
        self.influence = min(max(influence, Self.influenceRange.lowerBound), Self.influenceRange.upperBound)
        self.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    /// After Effects' Easy Ease: stops at the keyframe, 33% influence.
    static let easy = KeyframeEase(influence: TransitionCurve.influence, speed: 0)

    /// Where a linear side's handle sits.
    static let linearInfluence = TransitionCurve.influence

    /// Ready-made eases, named as on transitions and in After Effects.
    enum Preset: CaseIterable, Identifiable {
        case linear, easeIn, easeOut, easyEase

        var id: Self { self }

        var name: String {
            switch self {
            case .linear: "Linear"
            case .easeIn: "Ease In"
            case .easeOut: "Ease Out"
            case .easyEase: "Easy Ease"
            }
        }

        var detail: String {
            switch self {
            case .linear: "Steady into and out of the keyframe"
            case .easeIn: "Slows into the keyframe"
            case .easeOut: "Leaves the keyframe slowly"
            case .easyEase: "Slows in and leaves slowly"
            }
        }

        /// The After Effects shortcut, for menus.
        var shortcutHint: String? {
            switch self {
            case .linear: nil
            case .easeIn: "⇧F9"
            case .easeOut: "⌘⇧F9"
            case .easyEase: "F9"
            }
        }
    }

    /// The outgoing handle of a segment's first keyframe, in the segment's
    /// unit square (time across, progress up).
    static func outgoingHandle(_ ease: KeyframeEase?) -> CGPoint {
        guard let ease else { return CGPoint(x: linearInfluence, y: linearInfluence) }
        return CGPoint(x: ease.influence, y: ease.influence * ease.speed)
    }

    /// The incoming handle of a segment's last keyframe, in the same square.
    static func incomingHandle(_ ease: KeyframeEase?) -> CGPoint {
        guard let ease else { return CGPoint(x: 1 - linearInfluence, y: 1 - linearInfluence) }
        return CGPoint(x: 1 - ease.influence, y: 1 - ease.influence * ease.speed)
    }

    /// The ease an outgoing handle dragged to `point` in the unit square
    /// makes. Its time is kept inside the segment.
    static func outgoing(handleAt point: CGPoint) -> KeyframeEase {
        let influence = min(max(Double(point.x), influenceRange.lowerBound), influenceRange.upperBound)
        return KeyframeEase(influence: influence, speed: Double(point.y) / influence)
    }

    static func incoming(handleAt point: CGPoint) -> KeyframeEase {
        let influence = min(max(1 - Double(point.x), influenceRange.lowerBound), influenceRange.upperBound)
        return KeyframeEase(influence: influence, speed: (1 - Double(point.y)) / influence)
    }

    /// How far between two keyframes the value has got when `fraction` of
    /// the time between them has passed.
    static func progress(_ fraction: Double, leaving out: KeyframeEase?, arriving into: KeyframeEase?) -> Double {
        guard out != nil || into != nil else { return fraction }
        let controls = (CGPoint.zero, outgoingHandle(out), incomingHandle(into), CGPoint(x: 1, y: 1))
        // Both handles stay within the square's width, so time only grows
        // along the curve and it can be searched by time.
        let s = TransitionCurve.parameter(forTime: min(max(fraction, 0), 1), on: controls)
        return Double(TransitionCurve.point(on: controls, at: s).y)
    }
}

// MARK: - Any keyframed parameter

/// A value made of plain numbers, so any parameter's keyframes can be
/// drawn and edited the same way.
protocol KeyframeComponents: Interpolatable {
    var components: [Double] { get }
    init(components: [Double])
}

extension Double: KeyframeComponents {
    var components: [Double] { [self] }
    init(components: [Double]) { self = components.first ?? 0 }
}

extension Vector2: KeyframeComponents {
    var components: [Double] { [x, y] }
    init(components: [Double]) {
        self.init(x: components.first ?? 0, y: components.count > 1 ? components[1] : 0)
    }
}

/// Any parameter's value as its components.
struct ComponentValue: Interpolatable, Hashable {
    var values: [Double]

    static func interpolate(_ from: ComponentValue, _ to: ComponentValue, fraction: Double) -> ComponentValue {
        ComponentValue(values: zip(from.values, to.values).map { Double.interpolate($0, $1, fraction: fraction) })
    }
}

extension AnimatedValue where Value: KeyframeComponents {
    /// The same keyframes, eases and value, as plain components.
    var asComponents: AnimatedValue<ComponentValue> {
        AnimatedValue<ComponentValue>(
            ComponentValue(values: value.components),
            keyframes: keyframes.map {
                Keyframe(time: $0.time, value: ComponentValue(values: $0.value.components), easeIn: $0.easeIn, easeOut: $0.easeOut)
            }
        )
    }

    init(components: AnimatedValue<ComponentValue>) {
        self.init(
            Value(components: components.value.values),
            keyframes: components.keyframes.map {
                Keyframe(time: $0.time, value: Value(components: $0.value.values), easeIn: $0.easeIn, easeOut: $0.easeOut)
            }
        )
    }
}

/// A layer property that can be keyframed: a transform property or the
/// layer's volume.
enum AnimatedParameter: Hashable {
    case transform(TransformProperty)
    case volume

    var name: String {
        switch self {
        case .transform(let property): property.rawValue
        case .volume: "Volume"
        }
    }

    /// The names of its components, for a graph's legend.
    var componentNames: [String] {
        switch self {
        case .transform(.position): ["X", "Y"]
        case .transform(.scale): ["Width", "Height"]
        case .transform(let property): [property.rawValue]
        case .volume: ["Level"]
        }
    }

    /// Added to each stored component to show it as the editor does:
    /// position is shown absolute in the frame.
    func displayOffset(frameSize: CGSize) -> [Double] {
        switch self {
        case .transform(.position): [frameSize.width / 2, frameSize.height / 2]
        default: componentNames.map { _ in 0 }
        }
    }

    /// A stored component limited to what the property allows.
    func clamped(_ component: Double) -> Double {
        switch self {
        case .transform(.opacity): min(max(component, 0), 100)
        case .volume: AudioLevel.clamped(component)
        default: component
        }
    }

    /// A shown value with its unit.
    func label(_ shown: Double) -> String {
        switch self {
        case .volume: AudioLevel.label(shown)
        case .transform(let property): NumericExpression.format(shown, maxFractionDigits: 1) + property.unit
        }
    }
}

/// One parameter of one layer of one timeline.
struct ParameterKey: Hashable {
    var timelineID: UUID
    var layerID: UUID
    var parameter: AnimatedParameter
}

extension LayerTransform {
    subscript(components property: TransformProperty) -> AnimatedValue<ComponentValue> {
        get {
            switch property {
            case .position: position.asComponents
            case .scale: scale.asComponents
            case .rotation: rotation.asComponents
            case .opacity: opacity.asComponents
            }
        }
        set {
            switch property {
            case .position: position = AnimatedValue(components: newValue)
            case .scale: scale = AnimatedValue(components: newValue)
            case .rotation: rotation = AnimatedValue(components: newValue)
            case .opacity: opacity = AnimatedValue(components: newValue)
            }
        }
    }
}

extension TimelineLayer {
    subscript(components parameter: AnimatedParameter) -> AnimatedValue<ComponentValue> {
        get {
            switch parameter {
            case .transform(let property): transform[components: property]
            case .volume: volume.asComponents
            }
        }
        set {
            switch parameter {
            case .transform(let property): transform[components: property] = newValue
            case .volume: volume = AnimatedValue(components: newValue)
            }
        }
    }
}

extension EditingProject {
    /// The parameter's keyframes as components, or nil when its layer is gone.
    func components(of key: ParameterKey) -> AnimatedValue<ComponentValue>? {
        timeline(id: key.timelineID)?.layer(id: key.layerID)?[components: key.parameter]
    }

    mutating func editComponents(of key: ParameterKey, _ change: (inout AnimatedValue<ComponentValue>) -> Void) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == key.timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == key.layerID })
        else {
            return
        }
        change(&timelines[tIndex].layers[lIndex][components: key.parameter])
    }
}
