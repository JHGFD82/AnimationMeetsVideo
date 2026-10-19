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
                Keyframe(time: $0.time, value: ComponentValue(values: $0.value.components), easeIn: $0.easeIn, easeOut: $0.easeOut, generatedBy: $0.generatedBy)
            }
        )
    }

    init(components: AnimatedValue<ComponentValue>) {
        self.init(
            Value(components: components.value.values),
            keyframes: components.keyframes.map {
                Keyframe(time: $0.time, value: Value(components: $0.value.values), easeIn: $0.easeIn, easeOut: $0.easeOut, generatedBy: $0.generatedBy)
            }
        )
    }
}

/// A value that can be keyframed: a layer's volume or pan, or something on
/// a clip: its volume, pan, anchor point or one of an effect's controls.
enum AnimatedParameter: Hashable {
    case layerVolume(layerID: UUID)
    case clipVolume(clipID: UUID)
    case layerPan(layerID: UUID)
    case clipPan(clipID: UUID)
    case anchorPoint(clipID: UUID)
    case speed(clipID: UUID)
    case control(ControlKind, clipID: UUID, effectID: UUID, controlID: UUID)

    var name: String {
        switch self {
        case .layerVolume, .clipVolume: "Volume"
        case .layerPan, .clipPan: "Pan"
        case .speed: "Speed"
        case .anchorPoint: "Anchor Point"
        case .control(let kind, _, _, _): kind.name
        }
    }

    /// The names of its components, for a graph's legend.
    var componentNames: [String] {
        switch self {
        case .layerVolume, .clipVolume: ["Level"]
        case .layerPan, .clipPan: ["Pan"]
        case .speed: ["Speed"]
        case .anchorPoint: ["x", "y"]
        case .control(let kind, _, _, _): kind.componentNames
        }
    }

    /// Added to each stored component to show it as the editor does. Every
    /// parameter is shown as stored.
    func displayOffset(frameSize: CGSize) -> [Double] {
        componentNames.map { _ in 0 }
    }

    /// A stored component limited to what the parameter allows.
    func clamped(_ component: Double) -> Double {
        switch self {
        case .layerVolume, .clipVolume: AudioLevel.clamped(component)
        case .layerPan, .clipPan: AudioPan.clamped(component)
        case .speed: ClipTime.clampedSpeed(component)
        case .anchorPoint: component
        case .control(let kind, _, _, _): kind.clamped(component)
        }
    }

    /// One stored component limited to what the parameter allows there.
    func clamped(_ component: Double, index: Int) -> Double {
        if case .control(let kind, _, _, _) = self { return kind.clamped(component, index: index) }
        return clamped(component)
    }

    /// A shown value with its unit.
    func label(_ shown: Double) -> String {
        switch self {
        case .layerVolume, .clipVolume: AudioLevel.label(shown)
        case .layerPan, .clipPan: AudioPan.label(shown)
        case .speed: NumericExpression.format(shown, maxFractionDigits: 1) + "%"
        case .anchorPoint: NumericExpression.format(shown, maxFractionDigits: 1) + " px"
        case .control(let kind, _, _, _): kind.label(shown)
        }
    }

    /// One component's shown value with its unit.
    func label(_ shown: Double, component index: Int) -> String {
        if case .control(let kind, _, _, _) = self { return kind.label(shown, component: index) }
        return label(shown)
    }
}

/// One parameter in one timeline.
struct ParameterKey: Hashable {
    var timelineID: UUID
    var parameter: AnimatedParameter
}

/// The time a parameter's keyframes are in, and the timeline's: a clip's
/// parameters are keyed in its source time, a layer's in the timeline's.
struct ParameterTimeAxis {
    /// The clip holding the parameter; nil for a layer's.
    var clip: TimelineClip?
    /// Where its keyframes can play, in seconds of its own time: the clip's
    /// trimmed range, or the timeline.
    var span: ClosedRange<Double>
    let frameDuration: CMTime

    func keyTime(atTimeline time: CMTime) -> CMTime {
        clip?.sourceTime(atTimelineTime: time) ?? time
    }

    func timelineTime(atKey time: CMTime) -> CMTime {
        clip?.timelineTime(forSourceTime: time) ?? time
    }

    /// The parameter's time nearest `seconds` that plays on a frame of the
    /// timeline, so keyframes land where the playhead can stop.
    func snapped(_ seconds: Double) -> CMTime {
        let timeline = timelineTime(atKey: CMTime(seconds: seconds, preferredTimescale: 240_000))
        let frame = CMTimeMaximum(.zero, CMTimeMultiply(frameDuration, multiplier: Int32((timeline.seconds / frameDuration.seconds).rounded())))
        return keyTime(atTimeline: frame)
    }
}

extension EditingProject {
    /// The time axis of a parameter's graph, or nil when what holds it is
    /// gone.
    func timeAxis(of key: ParameterKey) -> ParameterTimeAxis? {
        guard let timeline = timeline(id: key.timelineID) else { return nil }
        let frame = timeline.frameDuration
        switch key.parameter {
        case .layerVolume, .layerPan:
            let last = components(of: key)?.keyframes.last?.time.seconds ?? 0
            return ParameterTimeAxis(clip: nil, span: 0...max(timeline.duration.seconds, last, 1), frameDuration: frame)
        case .clipVolume(let clipID), .clipPan(let clipID), .anchorPoint(let clipID), .speed(let clipID),
             .control(_, let clipID, _, _):
            guard let clip = clipAndLayer(clipID, in: key.timelineID)?.clip else { return nil }
            let start = clip.trimStart.seconds, end = clip.trimEnd.seconds
            return ParameterTimeAxis(clip: clip, span: min(start, end)...max(start, end, min(start, end) + 1e-3), frameDuration: frame)
        }
    }
}

extension EditingProject {
    /// The parameter's keyframes as components, or nil when what holds it
    /// is gone (or it is a choice, which has none).
    func components(of key: ParameterKey) -> AnimatedValue<ComponentValue>? {
        guard let timeline = timeline(id: key.timelineID) else { return nil }
        switch key.parameter {
        case .layerVolume(let layerID):
            return timeline.layer(id: layerID)?.volume.asComponents
        case .clipVolume(let clipID):
            return clipAndLayer(clipID, in: key.timelineID)?.clip.volume.asComponents
        case .layerPan(let layerID):
            return timeline.layer(id: layerID)?.pan.asComponents
        case .clipPan(let clipID):
            return clipAndLayer(clipID, in: key.timelineID)?.clip.pan.asComponents
        case .anchorPoint(let clipID):
            return clipAndLayer(clipID, in: key.timelineID)?.clip.anchorPoint.asComponents
        case .speed(let clipID):
            return clipAndLayer(clipID, in: key.timelineID)?.clip.time.speed.asComponents
        case .control(_, let clipID, let effectID, let controlID):
            let control = clipAndLayer(clipID, in: key.timelineID)?.clip.effect(id: effectID)?
                .controls.first { $0.id == controlID }
            return control.flatMap { $0.kind.isChoice ? nil : $0.number }
        }
    }

    mutating func editComponents(of key: ParameterKey, _ change: (inout AnimatedValue<ComponentValue>) -> Void) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == key.timelineID }) else { return }
        switch key.parameter {
        case .layerVolume(let layerID):
            guard let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }) else { return }
            var components = timelines[tIndex].layers[lIndex].volume.asComponents
            change(&components)
            timelines[tIndex].layers[lIndex].volume = AnimatedValue(components: components)
        case .clipVolume(let clipID):
            editClip(clipID, in: key.timelineID) { clip in
                var components = clip.volume.asComponents
                change(&components)
                clip.volume = AnimatedValue(components: components)
            }
        case .layerPan(let layerID):
            guard let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }) else { return }
            var components = timelines[tIndex].layers[lIndex].pan.asComponents
            change(&components)
            timelines[tIndex].layers[lIndex].pan = AnimatedValue(components: components)
        case .clipPan(let clipID):
            editClip(clipID, in: key.timelineID) { clip in
                var components = clip.pan.asComponents
                change(&components)
                clip.pan = AnimatedValue(components: components)
            }
        case .anchorPoint(let clipID):
            editClip(clipID, in: key.timelineID) { clip in
                var components = clip.anchorPoint.asComponents
                change(&components)
                clip.anchorPoint = AnimatedValue(components: components)
            }
        case .speed(let clipID):
            guard let layerID = clipAndLayer(clipID, in: key.timelineID)?.layer.id else { return }
            editTime(ofClip: clipID, in: key.timelineID, layer: layerID) { time in
                var components = time.speed.asComponents
                change(&components)
                time.speed = AnimatedValue(components: components)
            }
        case .control(_, let clipID, let effectID, let controlID):
            editEffect(effectID, ofClip: clipID, in: key.timelineID) { effect in
                guard let c = effect.controls.firstIndex(where: { $0.id == controlID }) else { return }
                change(&effect.controls[c].number)
            }
        }
    }
}
