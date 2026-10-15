import CoreGraphics
import CoreMedia
import Foundation

/// A value a property can animate between: keyframed values are blended
/// linearly.
protocol Interpolatable: Equatable, Sendable {
    static func interpolate(_ from: Self, _ to: Self, fraction: Double) -> Self
}

extension Double: Interpolatable {
    static func interpolate(_ from: Double, _ to: Double, fraction: Double) -> Double {
        from + (to - from) * fraction
    }
}

/// A 2D value such as a position or a scale. 3D properties will add a `z`.
struct Vector2: Interpolatable, Hashable {
    var x: Double
    var y: Double

    static let zero = Vector2(x: 0, y: 0)

    static func interpolate(_ from: Vector2, _ to: Vector2, fraction: Double) -> Vector2 {
        Vector2(
            x: Double.interpolate(from.x, to.x, fraction: fraction),
            y: Double.interpolate(from.y, to.y, fraction: fraction)
        )
    }
}

/// One keyframe: a property's value at a time on the layer's timeline,
/// and how the value arrives at it and leaves it (nil is linear; see
/// `KeyframeEase`).
struct Keyframe<Value: Interpolatable>: Equatable, Sendable {
    var time: CMTime
    var value: Value
    var easeIn: KeyframeEase?
    var easeOut: KeyframeEase?
}

/// A property that is either a single value or animated by keyframes.
/// With no keyframes `value` applies everywhere. With keyframes, the value
/// holds the first keyframe's value before it, the last one's after it, and
/// is blended in between, linearly or along the curve the two keyframes'
/// eases make; `value` is then unused.
///
/// A keyframe is identified by its time: a property has at most one per
/// time, so setting a value at an existing keyframe's time replaces it.
struct AnimatedValue<Value: Interpolatable>: Equatable, Sendable {
    var value: Value
    /// Sorted by time, without duplicates.
    private(set) var keyframes: [Keyframe<Value>] = []

    init(_ value: Value, keyframes: [Keyframe<Value>] = []) {
        self.value = value
        self.keyframes = Self.normalized(keyframes)
    }

    var isAnimated: Bool { !keyframes.isEmpty }

    /// The first and last keyframe times, or nil when not animated. The value
    /// is constant outside this range.
    var animatedRange: ClosedRange<CMTime>? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        return first.time...last.time
    }

    func value(at time: CMTime) -> Value {
        guard let first = keyframes.first, let last = keyframes.last else { return value }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        let next = keyframes.lowerBound(of: time) { $0.time }
        let before = keyframes[next - 1]
        let after = keyframes[next]
        let span = CMTimeSubtract(after.time, before.time).seconds
        guard span > 0 else { return after.value }
        let fraction = CMTimeSubtract(time, before.time).seconds / span
        let progress = KeyframeEase.progress(fraction, leaving: before.easeOut, arriving: after.easeIn)
        return Value.interpolate(before.value, after.value, fraction: progress)
    }

    func keyframe(at time: CMTime) -> Keyframe<Value>? {
        keyframes.first { $0.time == time }
    }

    /// Sets the value at `time`: a keyframe there when animated (keeping
    /// its eases if one is already there), otherwise the single value.
    mutating func set(_ newValue: Value, at time: CMTime) {
        guard isAnimated else {
            value = newValue
            return
        }
        if let index = keyframes.firstIndex(where: { $0.time == time }) {
            keyframes[index].value = newValue
            return
        }
        keyframes.append(Keyframe(time: time, value: newValue))
        keyframes = Self.normalized(keyframes)
    }

    /// Sets how the value arrives at and leaves the keyframe at `time`.
    mutating func setEase(at time: CMTime, in easeIn: KeyframeEase?, out easeOut: KeyframeEase?) {
        guard let index = keyframes.firstIndex(where: { $0.time == time }) else { return }
        keyframes[index].easeIn = easeIn
        keyframes[index].easeOut = easeOut
    }

    /// Applies a ready-made ease to the keyframe at `time`. Ease In and
    /// Ease Out change only their own side.
    mutating func applyEase(_ preset: KeyframeEase.Preset, at time: CMTime) {
        guard let keyframe = keyframe(at: time) else { return }
        switch preset {
        case .linear: setEase(at: time, in: nil, out: nil)
        case .easeIn: setEase(at: time, in: .easy, out: keyframe.easeOut)
        case .easeOut: setEase(at: time, in: keyframe.easeIn, out: .easy)
        case .easyEase: setEase(at: time, in: .easy, out: .easy)
        }
    }

    /// Turns animation on with one keyframe holding the current value at
    /// `time`, or off, keeping the value that was showing at `time`.
    mutating func setAnimated(_ animated: Bool, at time: CMTime) {
        guard animated != isAnimated else { return }
        if animated {
            keyframes = [Keyframe(time: time, value: value)]
        } else {
            value = value(at: time)
            keyframes = []
        }
    }

    /// Adds a keyframe holding the current value at `time`, or removes the
    /// one that is there.
    mutating func toggleKeyframe(at time: CMTime) {
        if keyframe(at: time) != nil {
            removeKeyframe(at: time)
        } else if isAnimated {
            set(value(at: time), at: time)
        } else {
            setAnimated(true, at: time)
        }
    }

    /// Removing the last keyframe leaves the property set to its value.
    mutating func removeKeyframe(at time: CMTime) {
        guard let removed = keyframe(at: time) else { return }
        keyframes.removeAll { $0.time == time }
        if keyframes.isEmpty { value = removed.value }
    }

    /// Moves a keyframe in time, with its eases, replacing any keyframe
    /// already at `newTime`.
    mutating func moveKeyframe(at time: CMTime, to newTime: CMTime) {
        guard time != newTime, var moving = keyframe(at: time) else { return }
        keyframes.removeAll { $0.time == time || $0.time == newTime }
        moving.time = newTime
        keyframes.append(moving)
        keyframes = Self.normalized(keyframes)
    }

    /// Moves every keyframe to `move(time)`, with its eases. Keyframes that
    /// land on the same time merge, keeping the later one.
    mutating func moveKeyframeTimes(_ move: (CMTime) -> CMTime) {
        keyframes = Self.normalized(keyframes.map { keyframe in
            var moved = keyframe
            moved.time = move(keyframe.time)
            return moved
        })
    }

    /// Sorted, keeping the last of any keyframes that share a time.
    private static func normalized(_ keyframes: [Keyframe<Value>]) -> [Keyframe<Value>] {
        var result: [Keyframe<Value>] = []
        for keyframe in keyframes.enumerated().sorted(by: { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }).map(\.element) {
            if result.last?.time == keyframe.time { result.removeLast() }
            result.append(keyframe)
        }
        return result
    }
}

/// The 2D transform and opacity of a visual layer, After Effects-style. The
/// layer turns and scales about the center of its timeline's frame, which
/// is where fitted content is centered.
///
/// 3D (z position, x/y rotation, orientation) and an anchor point are not
/// modeled yet; they would join these as further properties.
struct LayerTransform: Equatable, Sendable {
    /// How far the layer's center is moved from the frame's center, in
    /// timeline pixels (y down). The editor shows it as an absolute position
    /// in the frame, After Effects-style; storing the offset keeps untouched
    /// layers centered when the timeline's frame size changes.
    var position = AnimatedValue(Vector2.zero)
    /// Percent of the fitted size; 100 fits the frame. Negative flips.
    var scale = AnimatedValue(Vector2(x: 100, y: 100))
    /// Degrees clockwise.
    var rotation = AnimatedValue(0.0)
    /// Percent, 0 (invisible) to 100.
    var opacity = AnimatedValue(100.0)
    /// Whether editing one scale axis scales the other in proportion.
    var scaleLinked = true

    static let identity = LayerTransform()

    var isAnimated: Bool {
        position.isAnimated || scale.isAnimated || rotation.isAnimated || opacity.isAnimated
    }

    /// Every property's keyframe span. The transform is constant outside all
    /// of them.
    var animatedRanges: [ClosedRange<CMTime>] {
        [position.animatedRange, scale.animatedRange, rotation.animatedRange, opacity.animatedRange].compactMap { $0 }
    }

    /// Maps the layer's content, already fitted into a frame whose center is
    /// `center`, to where it is drawn at `time`.
    func affineTransform(at time: CMTime, center: CGPoint) -> CGAffineTransform {
        let offset = position.value(at: time)
        let factors = scale.value(at: time)
        let radians = rotation.value(at: time) * .pi / 180
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: factors.x / 100, y: factors.y / 100))
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: center.x + offset.x, y: center.y + offset.y))
    }

    /// Opacity at `time` as a fraction, clamped to 0...1.
    func opacityFraction(at time: CMTime) -> Double {
        min(max(opacity.value(at: time) / 100, 0), 1)
    }
}

/// The animatable layer properties, with their After Effects shortcut keys.
enum TransformProperty: String, CaseIterable, Identifiable, Hashable {
    case position = "Position"
    case scale = "Scale"
    case rotation = "Rotation"
    case opacity = "Opacity"

    var id: Self { self }

    /// T is opacity, as in After Effects (O is taken there).
    var shortcutKey: Character {
        switch self {
        case .position: "p"
        case .scale: "s"
        case .rotation: "r"
        case .opacity: "t"
        }
    }

    init?(shortcutKey: Character) {
        guard let match = Self.allCases.first(where: { $0.shortcutKey == shortcutKey }) else { return nil }
        self = match
    }

    var unit: String {
        switch self {
        case .position: ""
        case .scale, .opacity: "%"
        case .rotation: "°"
        }
    }
}

extension LayerTransform {
    func isAnimated(_ property: TransformProperty) -> Bool {
        switch property {
        case .position: position.isAnimated
        case .scale: scale.isAnimated
        case .rotation: rotation.isAnimated
        case .opacity: opacity.isAnimated
        }
    }

    func keyframeTimes(_ property: TransformProperty) -> [CMTime] {
        switch property {
        case .position: position.keyframes.map(\.time)
        case .scale: scale.keyframes.map(\.time)
        case .rotation: rotation.keyframes.map(\.time)
        case .opacity: opacity.keyframes.map(\.time)
        }
    }

    func hasKeyframe(_ property: TransformProperty, at time: CMTime) -> Bool {
        keyframeTimes(property).contains(time)
    }

    /// The property's components at `time`, as shown in the editor:
    /// position is absolute in a frame of `frameSize`.
    func components(_ property: TransformProperty, at time: CMTime, frameSize: CGSize) -> [Double] {
        switch property {
        case .position:
            let offset = position.value(at: time)
            return [frameSize.width / 2 + offset.x, frameSize.height / 2 + offset.y]
        case .scale:
            let factors = scale.value(at: time)
            return [factors.x, factors.y]
        case .rotation:
            return [rotation.value(at: time)]
        case .opacity:
            return [opacity.value(at: time)]
        }
    }

    /// Sets one component of a property at `time` from an editor value.
    /// Scale keeps its aspect when linked; opacity is clamped to 0...100.
    mutating func setComponent(_ index: Int, of property: TransformProperty, to newValue: Double, at time: CMTime, frameSize: CGSize) {
        guard newValue.isFinite else { return }
        switch property {
        case .position:
            var offset = position.value(at: time)
            if index == 0 { offset.x = newValue - frameSize.width / 2 } else { offset.y = newValue - frameSize.height / 2 }
            position.set(offset, at: time)
        case .scale:
            let old = scale.value(at: time)
            var factors = old
            if index == 0 {
                factors.x = newValue
                if scaleLinked { factors.y = old.x != 0 ? old.y * newValue / old.x : newValue }
            } else {
                factors.y = newValue
                if scaleLinked { factors.x = old.y != 0 ? old.x * newValue / old.y : newValue }
            }
            scale.set(factors, at: time)
        case .rotation:
            rotation.set(newValue, at: time)
        case .opacity:
            opacity.set(min(max(newValue, 0), 100), at: time)
        }
    }

    mutating func setAnimated(_ property: TransformProperty, _ animated: Bool, at time: CMTime) {
        switch property {
        case .position: position.setAnimated(animated, at: time)
        case .scale: scale.setAnimated(animated, at: time)
        case .rotation: rotation.setAnimated(animated, at: time)
        case .opacity: opacity.setAnimated(animated, at: time)
        }
    }

    mutating func toggleKeyframe(_ property: TransformProperty, at time: CMTime) {
        switch property {
        case .position: position.toggleKeyframe(at: time)
        case .scale: scale.toggleKeyframe(at: time)
        case .rotation: rotation.toggleKeyframe(at: time)
        case .opacity: opacity.toggleKeyframe(at: time)
        }
    }

    mutating func removeKeyframe(_ property: TransformProperty, at time: CMTime) {
        switch property {
        case .position: position.removeKeyframe(at: time)
        case .scale: scale.removeKeyframe(at: time)
        case .rotation: rotation.removeKeyframe(at: time)
        case .opacity: opacity.removeKeyframe(at: time)
        }
    }

    mutating func moveKeyframe(_ property: TransformProperty, at time: CMTime, to newTime: CMTime) {
        switch property {
        case .position: position.moveKeyframe(at: time, to: newTime)
        case .scale: scale.moveKeyframe(at: time, to: newTime)
        case .rotation: rotation.moveKeyframe(at: time, to: newTime)
        case .opacity: opacity.moveKeyframe(at: time, to: newTime)
        }
    }
}

// MARK: - Frames

extension Timeline {
    /// Exact frame durations for the NTSC-family rates (23.976, 29.97, 59.94)
    /// rather than rounding them to 24/30/60. Other fractional rates, such
    /// as 12.5, are kept to a thousandth of a frame a second rather than
    /// rounded to a whole number.
    static func frameDuration(for frameRate: Double) -> CMTime {
        let clamped = min(max(frameRate, 1), 1000)
        let rounded = clamped.rounded()
        if abs(clamped - rounded * 1000 / 1001) < 0.01 {
            return CMTime(value: 1001, timescale: Int32(rounded) * 1000)
        }
        if abs(clamped - rounded) < 0.0005 {
            return CMTime(value: 1, timescale: Int32(rounded))
        }
        return CMTime(value: 1000, timescale: Int32((clamped * 1000).rounded()))
    }

    var frameDuration: CMTime { Self.frameDuration(for: frameRate) }

    /// The start of the frame nearest `time`, never before zero. Keyframes
    /// sit on frames so two edits at the same playhead hit the same keyframe.
    func snappedToFrame(_ time: CMTime) -> CMTime {
        CMTimeMaximum(.zero, frameAligned(time, .nearest))
    }
}

// MARK: - Editing

extension TimelineLayer {
    /// Whether the layer draws pictures, so its transform means something.
    /// Audio-only layers have no transform controls.
    func isVisual(in project: EditingProject) -> Bool {
        clips.contains { project.playsVideo($0) }
    }
}

extension EditingProject {
    /// Applies `change` to a layer's transform. Times passed in should
    /// already be snapped to the timeline's frames.
    mutating func editTransform(of layerID: UUID, in timelineID: UUID, _ change: (inout LayerTransform) -> Void) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        change(&timelines[tIndex].layers[lIndex].transform)
    }
}
