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

    var id: Self { self }

    var name: String {
        switch self {
        case .foundations: "Foundations"
        }
    }
}

/// The kinds of effect the library offers.
enum EffectKind: String, CaseIterable, Identifiable, Sendable {
    case transform
    case blending
    case color

    var id: Self { self }

    var name: String {
        switch self {
        case .transform: "Transform"
        case .blending: "Blending"
        case .color: "Color"
        }
    }

    var category: EffectCategory {
        switch self {
        case .transform, .blending, .color: .foundations
        }
    }

    var systemImage: String {
        switch self {
        case .transform: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .blending: "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .color: "slider.horizontal.3"
        }
    }

    /// Whether the picture it makes depends on the size it is drawn at, so a
    /// nested timeline holding it can't have its move pushed into its
    /// layers (a blur whose radius is in pixels, say). Effects that work on
    /// single pixels, or move them, don't.
    var dependsOnPixelSize: Bool {
        switch self {
        case .transform, .blending, .color: false
        }
    }

    /// The controls a new effect of this kind lists, in order.
    var controlKinds: [ControlKind] {
        switch self {
        case .transform: [.position, .scale, .rotation, .opacity]
        case .blending: [.mode, .amount]
        case .color: [.exposure, .contrast, .saturation, .temperature, .tint, .lift, .gamma, .gain]
        }
    }
}

/// One control of an effect. Each is a step of its own.
enum ControlKind: String, CaseIterable, Identifiable, Sendable {
    case position, scale, rotation, opacity
    case mode, amount
    case exposure, contrast, saturation, temperature, tint, lift, gamma, gain

    var id: Self { self }

    var name: String {
        switch self {
        case .position: "Position"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        case .mode: "Mode"
        case .amount: "Amount"
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .lift: "Lift"
        case .gamma: "Gamma"
        case .gain: "Gain"
        }
    }

    /// The effect kind that lists the control.
    var effectKind: EffectKind {
        switch self {
        case .position, .scale, .rotation, .opacity: .transform
        case .mode, .amount: .blending
        case .exposure, .contrast, .saturation, .temperature, .tint, .lift, .gamma, .gain: .color
        }
    }

    /// Whether the control is a choice from a list rather than numbers.
    var isChoice: Bool { self == .mode }

    /// The names of its components, for a graph's legend.
    var componentNames: [String] {
        switch self {
        case .position: ["Δx", "Δy"]
        case .scale: ["x", "y"]
        case .mode: []
        case .lift, .gamma, .gain: ["All", "Red", "Green", "Blue"]
        default: [name]
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
        case .mode: []
        }
    }

    var unit: String {
        switch self {
        case .position: " px"
        case .scale, .opacity, .amount, .contrast, .saturation: "%"
        case .rotation: "°"
        case .exposure: " stops"
        case .mode, .temperature, .tint, .lift, .gamma, .gain: ""
        }
    }

    /// How far one point of dragging a value moves it: a pixel, a percent,
    /// a degree, a tenth of a stop.
    var dragStep: Double {
        switch self {
        case .exposure: 0.1
        case .lift, .gamma, .gain: 0.01
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
        case .position, .scale, .rotation, .mode: nil
        }
    }

    /// A component limited to what the control allows.
    func clamped(_ component: Double) -> Double {
        guard let range else { return component }
        return min(max(component, range.lowerBound), range.upperBound)
    }

    /// A shown value with its unit.
    func label(_ shown: Double) -> String {
        NumericExpression.format(shown, maxFractionDigits: dragStep < 1 ? 2 : 1) + unit
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
    /// The option picked, for a choice: a `BlendMode` raw value.
    var choice: String?
    /// Whether editing one scale axis scales the other in proportion.
    var linked = true

    init(id: UUID = UUID(), kind: ControlKind, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        number = AnimatedValue(ComponentValue(values: kind.defaultValues))
        choice = kind == .mode ? BlendMode.normal.rawValue : nil
    }

    var isAnimated: Bool { number.isAnimated }

    var blendMode: BlendMode {
        get { choice.flatMap(BlendMode.init(rawValue:)) ?? .normal }
        set { choice = newValue.rawValue }
    }

    /// True when the control changes nothing: it is off, or it holds its
    /// default throughout.
    var isNoOp: Bool {
        guard enabled else { return true }
        if kind.isChoice { return blendMode == .normal }
        let defaults = ComponentValue(values: kind.defaultValues)
        if number.isAnimated { return number.keyframes.allSatisfy { $0.value == defaults } }
        return number.value == defaults
    }

    /// The control's components at `source time`.
    func values(at time: CMTime) -> [Double] {
        number.value(at: time).values
    }

    mutating func reset() {
        let fresh = EffectControl(id: id, kind: kind, enabled: enabled)
        number = fresh.number
        choice = fresh.choice
    }

    /// Sets one component at `time` (a keyframe when animated). Linked
    /// scale keeps its proportion; limits apply.
    mutating func setComponent(_ index: Int, to newValue: Double, at time: CMTime) {
        guard newValue.isFinite, !kind.isChoice else { return }
        var values = number.value(at: time).values
        guard values.indices.contains(index) else { return }
        let old = values
        values[index] = kind.clamped(newValue)
        if kind == .scale, linked, values.count == 2 {
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
    var controls: [EffectControl]

    init(id: UUID = UUID(), kind: EffectKind, name: String? = nil, controls: [EffectControl]? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.controls = controls ?? kind.controlKinds.map { EffectControl(kind: $0) }
    }

    var displayName: String { name ?? kind.name }

    func control(_ kind: ControlKind) -> EffectControl? {
        controls.first { $0.kind == kind }
    }

    func controlIndex(_ id: UUID) -> Int? {
        controls.firstIndex { $0.id == id }
    }

    /// True when nothing in the effect changes the picture.
    var isNoOp: Bool {
        guard enabled else { return true }
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
        self = Effect(id: id, kind: kind, name: name)
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
        controls.append(EffectControl(kind: kind))
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

    /// The span of time in which any enabled control is between keyframes.
    var animatedRanges: [ClosedRange<CMTime>] {
        guard enabled else { return [] }
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
        case .layerVolume(let layerID):
            guard let layer = timeline.layer(id: layerID) else { return key.parameter.name }
            return "\(displayName(of: layer, in: timeline)) · Volume"
        case .clipVolume(let clipID), .anchorPoint(let clipID), .speed(let clipID):
            return "\(clipName(clipID, in: key.timelineID)) · \(key.parameter.name)"
        case .control(_, let clipID, let effectID, _):
            let effect = clipAndLayer(clipID, in: key.timelineID)?.clip.effects.first { $0.id == effectID }
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
    /// end. Clips with no pictures take none. Returns the effect's ID.
    @discardableResult
    mutating func addEffect(_ kind: EffectKind, toClip clipID: UUID, in timelineID: UUID, at index: Int? = nil) -> UUID? {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip, hasEffectStack(clip) else { return nil }
        let effect = Effect.make(kind, among: clip.effects)
        editClip(clipID, in: timelineID) { clip in
            clip.effects.insert(effect, at: min(max(index ?? clip.effects.count, 0), clip.effects.count))
        }
        return effect.id
    }

    /// Applies `change` to one effect of a clip.
    mutating func editEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID, _ change: (inout Effect) -> Void) {
        editClip(clipID, in: timelineID) { clip in
            guard let index = clip.effects.index(of: effectID) else { return }
            change(&clip.effects[index])
        }
    }

    mutating func removeEffect(_ effectID: UUID, fromClip clipID: UUID, in timelineID: UUID) {
        editClip(clipID, in: timelineID) { $0.effects.removeAll { $0.id == effectID } }
    }

    /// Moves an effect to `index` in the stack (0 is the top).
    mutating func moveEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID, toIndex index: Int) {
        editClip(clipID, in: timelineID) { clip in
            guard let from = clip.effects.index(of: effectID) else { return }
            let effect = clip.effects.remove(at: from)
            clip.effects.insert(effect, at: min(max(index, 0), clip.effects.count))
        }
    }

    /// Puts a copy of an effect just below it, named for the stack.
    @discardableResult
    mutating func duplicateEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID) -> UUID? {
        var copyID: UUID?
        editClip(clipID, in: timelineID) { clip in
            guard let index = clip.effects.index(of: effectID) else { return }
            let original = clip.effects[index]
            let copy = original.duplicated(named: Effect.make(original.kind, among: clip.effects).name)
            clip.effects.insert(copy, at: index + 1)
            copyID = copy.id
        }
        return copyID
    }
}

// MARK: - Easing at the playhead

extension TimelineClip {
    /// Applies an ease to every keyframe the clip's anchor point, volume and
    /// effect controls have at `time` in the timeline, for the F9 keys.
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
        if self.time.speed.keyframe(at: source) != nil {
            self.time.speed.applyEase(preset, at: source)
            eased = true
        }
        for e in effects.indices {
            for c in effects[e].controls.indices where effects[e].controls[c].number.keyframe(at: source) != nil {
                effects[e].controls[c].number.applyEase(preset, at: source)
                eased = true
            }
        }
        return eased
    }
}
