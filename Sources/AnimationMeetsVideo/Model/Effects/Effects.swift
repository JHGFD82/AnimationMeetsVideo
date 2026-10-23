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
    case shapes
    case mattes
    /// Remaps the picture's colors (see docs/psychedelic-effects.md).
    case recolor
    /// Grain, snow and procedural fields.
    case noise
    /// Moves pixels, keeping their colors.
    case distortion
    /// Effects that draw nothing and write keyframes onto other controls
    /// instead (see docs/keyframing-effects.md).
    case keyframing
    case sound

    var id: Self { self }

    var name: String {
        switch self {
        case .foundations: "Foundations"
        case .shapes: "Shapes"
        case .mattes: "Mattes"
        case .recolor: "Color"
        case .noise: "Noise"
        case .distortion: "Distortion"
        case .keyframing: "Keyframing"
        case .sound: "Sound"
        }
    }
}

/// What a Matte takes from its picture to cut the clip with.
enum MatteMode: String, CaseIterable, Identifiable, Sendable {
    /// The clip shows where the picture is opaque.
    case alpha
    /// The clip shows where the picture is bright.
    case luma
    case invertedAlpha
    case invertedLuma

    var id: Self { self }

    var name: String {
        switch self {
        case .alpha: "Alpha"
        case .luma: "Luma"
        case .invertedAlpha: "Inverted Alpha"
        case .invertedLuma: "Inverted Luma"
        }
    }

    var usesLuma: Bool { self == .luma || self == .invertedLuma }
    var isInverted: Bool { self == .invertedAlpha || self == .invertedLuma }
}

/// A picture an effect takes besides the clip's: it comes from the browser,
/// not the timeline, so it takes up no layer and belongs to the clip, as
/// part of the effect's step. See docs/effects.md, "Inputs".
struct EffectInput: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case asset(UUID)
        case timeline(UUID)
    }

    var source: Source
    /// Where in the input it is when the clip starts. A moving input plays
    /// from the start of the clip.
    var offset = CMTime.zero
    /// Whether it plays again from its start at its end, rather than holding
    /// its last frame.
    var loops = false
}

/// A kind of effect the library offers, by the name it is saved under.
/// What it is (its name, category and controls) is its definition in the
/// `EffectRegistry`; the built-in kinds are in BuiltInEffects.swift. Sound
/// effects (see docs/audio.md, "Sound effects") go in a clip's
/// `audioEffects` and play through the EQ's own filters or Apple's Audio
/// Units; the rest change its picture.
struct EffectKind: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String

    /// The kind saved as `rawValue`, if one is registered.
    init?(rawValue: String) {
        guard EffectRegistry.current.effect(named: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    /// One of the kinds in BuiltInEffects.swift, which are always
    /// registered.
    init(builtIn rawValue: String) {
        self.rawValue = rawValue
    }

    /// Every registered kind, in the library's order.
    static var all: [EffectKind] { EffectRegistry.current.effects.map(\.kind) }

    var id: Self { self }

    var definition: EffectDefinition { EffectRegistry.current.definition(of: self) }

    var name: String { definition.name }

    var category: EffectCategory { definition.category }

    /// Whether it works on the clip's sound rather than its picture.
    var isAudio: Bool { category == .sound }

    /// Whether it writes keyframes onto another control rather than
    /// changing the picture or the sound.
    var isKeyframing: Bool { category == .keyframing }

    /// For a Keyframing effect: whether it reshapes the target's own
    /// keyframes, rather than making a signal combined with them.
    var reshapesTarget: Bool { definition.reshapesTarget }

    /// Whether it is one of the shapes, or strokes them.
    var isShape: Bool { category == .shapes }

    /// Whether it draws a shape of its own, rather than stroking others.
    var drawsShape: Bool { isShape && self != .stroke }

    var systemImage: String { definition.systemImage }

    /// Whether the effect takes a picture dragged from the browser.
    var takesInput: Bool { definition.takesInput }

    /// Whether it can read the picture as it was before an earlier effect
    /// in the stack ("Against"): Blending blends with it, Displace moves it.
    var readsAgainst: Bool { definition.readsAgainst }

    /// Whether the picture it makes depends on the size it is drawn at, so a
    /// nested timeline holding it can't have its move pushed into its
    /// layers (a blur whose radius is in pixels, say). Effects that work on
    /// single pixels, or move them, don't, and shapes are drawn at the size
    /// they end up.
    var dependsOnPixelSize: Bool { definition.dependsOnPixelSize }

    /// Whether it is one of the looks of docs/psychedelic-effects.md,
    /// which are drawn as a `.look` step.
    var isLook: Bool { category == .recolor || category == .noise || category == .distortion }

    /// Whether it replaces the picture with one it makes, rather than
    /// changing the one that reaches it.
    var generates: Bool { definition.generates }

    /// The controls a new effect of this kind lists, in order.
    var controlKinds: [ControlKind] { definition.controlKinds }
}

/// One control of an effect, by the name it is saved under. Each is a step
/// of its own. What it holds is its definition in the `EffectRegistry`.
struct ControlKind: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String

    /// The kind saved as `rawValue`, if one is registered.
    init?(rawValue: String) {
        guard EffectRegistry.current.control(named: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    /// One of the kinds in BuiltInEffects.swift, which are always
    /// registered.
    init(builtIn rawValue: String) {
        self.rawValue = rawValue
    }

    var id: Self { self }

    var definition: ControlDefinition { EffectRegistry.current.definition(of: self) }

    var name: String { definition.name }

    /// The effect kind that lists the control; for one every shape lists,
    /// the rectangle.
    var effectKind: EffectKind { definition.effectKind }

    /// Whether the control changes nothing at its default, so it can be
    /// shown dimmed there. A compressor's, limiter's or voice isolation's
    /// controls always matter: at their defaults they still work. So do a
    /// shape's, which draw it.
    var hasNeutralDefault: Bool {
        switch effectKind {
        case .compressor, .limiter, .voiceIsolation: false
        // A Keyframing effect's settings are what it makes keyframes from,
        // and a look's what it looks like.
        case _ where effectKind.isKeyframing || effectKind.isLook: false
        default: !effectKind.isShape
        }
    }

    /// Whether the control is a choice from a list rather than numbers.
    var isChoice: Bool { !choiceOptions.isEmpty }

    /// What a choice offers, as raw values and names; empty for numbers.
    var choiceOptions: [(id: String, name: String)] { definition.choiceOptions }

    /// What a new choice control picks.
    var defaultChoice: String? { definition.defaultChoice }

    /// Whether its two axes can be linked, so editing one changes the other
    /// in proportion.
    var isLinkable: Bool { self == .scale || self == .shapeSize }

    /// Whether a new control's axes are linked: a scale's are, a shape's
    /// size, whose width is usually set on its own, isn't.
    var linksByDefault: Bool { self == .scale }

    /// Whether the control is a color: red, green, blue and alpha, 0...1,
    /// as the timeline's encoded values (as a transition's dip color is).
    var isColor: Bool { definition.isColor }

    /// The names of its components, for a graph's legend.
    var componentNames: [String] {
        definition.componentNames ?? (isChoice ? [] : isColor ? ["Red", "Green", "Blue", "Alpha"] : [name])
    }

    /// What the control holds while it changes nothing.
    var defaultValues: [Double] { definition.defaultValues }

    var unit: String { definition.unit }

    /// How far one point of dragging a value moves it: a pixel, a percent,
    /// a degree, a tenth of a stop.
    var dragStep: Double { definition.dragStep }

    /// What a component is limited to, if anything.
    var range: ClosedRange<Double>? { definition.range }

    /// Whether the control counts something, so it holds whole numbers.
    var isWhole: Bool { definition.isWhole }

    /// A component limited to what the control allows; a count is whole.
    func clamped(_ component: Double) -> Double {
        let whole = isWhole ? component.rounded() : component
        guard let range else { return whole }
        return min(max(whole, range.lowerBound), range.upperBound)
    }

    /// A shown value with its unit.
    func label(_ shown: Double) -> String {
        NumericExpression.format(shown, maxFractionDigits: dragStep < 1 ? 2 : 1) + unit
    }

    // MARK: Components

    /// Whether a new control of this kind is on: an EQ's bands start off,
    /// to be switched on as they're needed.
    var startsEnabled: Bool { EqualizerBand(controlKind: self) == nil }

    /// The unit of one component. Most controls' components share one; an
    /// EQ band's frequency, gain and Q each have their own.
    func unit(ofComponent index: Int) -> String {
        EqualizerBand(controlKind: self)?.unit(ofComponent: index) ?? unit
    }

    /// What one component is limited to, if anything.
    func range(ofComponent index: Int) -> ClosedRange<Double>? {
        EqualizerBand(controlKind: self)?.range(ofComponent: index) ?? range
    }

    /// How far one point of dragging one component moves it.
    func dragStep(ofComponent index: Int) -> Double {
        EqualizerBand(controlKind: self)?.dragStep(ofComponent: index) ?? dragStep
    }

    /// One component limited to what the control allows there.
    func clamped(_ component: Double, index: Int) -> Double {
        guard EqualizerBand(controlKind: self) != nil, let range = range(ofComponent: index) else { return clamped(component) }
        return min(max(component, range.lowerBound), range.upperBound)
    }

    /// One component's shown value with its unit.
    func label(_ shown: Double, component index: Int) -> String {
        NumericExpression.format(shown, maxFractionDigits: dragStep(ofComponent: index) < 1 ? 2 : 1) + unit(ofComponent: index)
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
    /// The option picked, for a choice: a raw value of one of its
    /// `choiceOptions`.
    var choice: String?
    /// Whether editing one axis of a scale or a size changes the other in
    /// proportion.
    var linked = true
    /// For a rectangle's Corners: rounded with continuous curvature, the
    /// corner easing into the edge as an app icon's does, instead of a
    /// circular arc meeting it abruptly. Found in the control's menu.
    var squircle = false

    init(id: UUID = UUID(), kind: ControlKind, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        linked = kind.linksByDefault
        number = AnimatedValue(ComponentValue(values: kind.defaultValues))
        choice = kind.defaultChoice
    }

    var isAnimated: Bool { number.isAnimated }

    var blendMode: BlendMode {
        get { choice.flatMap(BlendMode.init(rawValue:)) ?? .normal }
        set { choice = newValue.rawValue }
    }

    var matteMode: MatteMode {
        get { choice.flatMap(MatteMode.init(rawValue:)) ?? .alpha }
        set { choice = newValue.rawValue }
    }

    /// True when the control changes nothing: it is off, or it holds its
    /// default throughout.
    var isNoOp: Bool {
        guard enabled else { return true }
        guard kind.hasNeutralDefault else { return false }
        if let band = EqualizerBand(controlKind: kind) {
            // A cut always cuts; a shelf or bell does nothing at 0 dB,
            // wherever it is.
            guard let gain = band.gainIndex else { return false }
            let values = number.isAnimated ? number.keyframes.map(\.value.values) : [number.value.values]
            return values.allSatisfy { !$0.indices.contains(gain) || $0[gain] == 0 }
        }
        if kind == .mode { return blendMode == .normal }
        if kind == .matteMode { return false }
        let defaults = ComponentValue(values: kind.defaultValues)
        if number.isAnimated { return number.keyframes.allSatisfy { $0.value == defaults } }
        return number.value == defaults
    }

    /// Whether it holds what a new control of its kind does: not animated,
    /// at its default value or option, and not a squircle. Whether it is on
    /// doesn't count.
    var isAtDefault: Bool { isAtDefault(like: EffectControl(kind: kind)) }

    /// Whether it holds what `fresh`, a new control of its kind as its
    /// effect would make it (a shape's size fitted to the frame), does.
    func isAtDefault(like fresh: EffectControl) -> Bool {
        !number.isAnimated && number.value == fresh.number.value && choice == fresh.choice && !squircle
    }

    /// The control's components at `source time`.
    func values(at time: CMTime) -> [Double] {
        number.value(at: time).values
    }

    mutating func reset() {
        reset(to: EffectControl(id: id, kind: kind, enabled: enabled))
    }

    /// Back to what `fresh` holds, keeping its ID and whether it is on.
    mutating func reset(to fresh: EffectControl) {
        number = fresh.number
        choice = fresh.choice
        squircle = fresh.squircle
    }

    /// Sets one component at `time` (a keyframe when animated). Linked
    /// scale keeps its proportion; limits apply.
    mutating func setComponent(_ index: Int, to newValue: Double, at time: CMTime) {
        guard newValue.isFinite, !kind.isChoice else { return }
        var values = number.value(at: time).values
        guard values.indices.contains(index) else { return }
        let old = values
        values[index] = kind.clamped(newValue, index: index)
        if kind.isLinkable, linked, values.count == 2 {
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
    /// For an effect that takes one: the picture dropped on it.
    var input: EffectInput?
    /// For a Keyframing effect: what it writes to and how (nil for every
    /// other kind).
    var keyframing: KeyframingSetup?
    /// What pasting or applying a preset couldn't bring over, until each is
    /// marked resolved (see docs/effects.md, "Paste changes").
    var pasteChanges: [PasteChange] = []
    var controls: [EffectControl]

    init(id: UUID = UUID(), kind: EffectKind, name: String? = nil, controls: [EffectControl]? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.controls = controls ?? kind.controlKinds.map { EffectControl(kind: $0, enabled: $0.startsEnabled) }
        keyframing = kind.isKeyframing ? KeyframingSetup() : nil
        if kind == .audioKeys { keyframing?.audioSource = .mix }
    }

    var displayName: String { name ?? kind.name }

    /// The value of a choice control, or nil if the effect lacks it.
    func choice<Option: RawRepresentable>(_ kind: ControlKind, as type: Option.Type = Option.self) -> Option?
    where Option.RawValue == String {
        control(kind).flatMap { $0.choice }.flatMap(Option.init(rawValue:))
    }

    func control(_ kind: ControlKind) -> EffectControl? {
        controls.first { $0.kind == kind }
    }

    func controlIndex(_ id: UUID) -> Int? {
        controls.firstIndex { $0.id == id }
    }

    /// True when nothing in the effect changes the picture, or for a
    /// sound effect the sound.
    var isNoOp: Bool {
        guard enabled else { return true }
        // It wrote its keyframes onto another control, which draws them.
        if kind.isKeyframing { return true }
        // Displace needs a map: an input, or the picture read against an
        // earlier step.
        if kind == .displace, input == nil, against == nil { return true }
        // A look always changes the picture, unless it is mixed in at none.
        if kind.isLook {
            guard let amount = control(.amount), amount.enabled else { return false }
            return !amount.number.isAnimated && amount.number.value.values.first == 0
        }
        if kind == .matte {
            // Without a picture to cut with, or at 0%, nothing changes.
            guard input != nil else { return true }
            guard let amount = control(.amount) else { return false }
            return amount.enabled && !amount.number.isAnimated && amount.number.value.values.first == 0
        }
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
    mutating func reset(in frame: CGSize? = nil) {
        let setup = keyframing
        self = Effect(id: id, kind: kind, name: name)
        if let frame { sizeShape(to: frame) }
        keyframing = setup
    }

    /// The control of `kind` a new effect of this one's kind starts with,
    /// a shape's sized to `frame` as one added to a timeline is, which is
    /// what Reset goes back to.
    func freshControl(_ kind: ControlKind, in frame: CGSize?) -> EffectControl {
        var fresh = Effect(kind: self.kind)
        if let frame { fresh.sizeShape(to: frame) }
        return fresh.control(kind) ?? EffectControl(kind: kind)
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
        controls.append(EffectControl(kind: kind, enabled: kind.startsEnabled))
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

    /// Whether it changes over time by itself, without keyframes: a Hue
    /// Cycle that turns, a palette that cycles. Its clip is drawn afresh
    /// at every frame then.
    var changesOnItsOwn: Bool {
        guard enabled, !isNoOp else { return false }
        // Grain, snow and glitches are new every frame, and so is a picture
        // drawn from other moments.
        switch kind {
        case .grain, .staticNoise, .blockGlitch, .flowSmear, .slitScan, .feedback: return true
        default: break
        }
        let moving: ControlKind? = switch kind {
        case .hueCycle: .hueSpeed
        case .cosinePalette: .cycleSpeed
        case .gradientMap: .scrollSpeed
        case .fractalNoise, .cells, .liquid: .evolution
        case .interference: .driftSpeed
        case .wave: .waveSpeed
        case .kaleidoscope: .spinSpeed
        default: nil
        }
        guard let moving, let control = control(moving), control.enabled else { return false }
        return control.number.isAnimated ? control.number.keyframes.contains { $0.value.values.first != 0 } : control.number.value.values.first != 0
    }

    /// The earlier moments of the clip's footage the effect draws from, as
    /// how long before the moment drawn, for the composition to have
    /// frames there (`MomentDelays`). Taken at the most any keyframe asks.
    func momentDelays(frame: CMTime) -> [CMTime] {
        guard enabled else { return [] }
        func most(_ kind: ControlKind) -> Double {
            guard let control = control(kind), control.enabled else { return kind.defaultValues.first ?? 0 }
            let values = control.number.isAnimated ? control.number.keyframes.map(\.value) : [control.number.value]
            return values.compactMap { $0.values.first.map { kind.clamped($0) } }.max() ?? 0
        }
        switch kind {
        case .feedback:
            let delay = Int(most(.feedbackDelay))
            return (1...max(Int(most(.copies)), 1)).map { MomentDelays.feedback(copy: $0, delayFrames: delay, frame: frame) }
        case .slitScan:
            let bands = max(Int(most(.bands)), 2), spread = most(.timeSpread)
            return Array(Set((1..<bands).map { MomentDelays.slit(band: $0, of: bands, spread: spread, frame: frame) }))
                .filter { $0 > .zero }.sorted()
        default:
            return []
        }
    }

    /// For Flow Smear: how many frames ahead in the footage it measures the
    /// motion to.
    var framesAhead: Int? {
        guard enabled, kind == .flowSmear else { return nil }
        return Int(control(.framesAhead)?.values(at: .zero).first ?? 1)
    }

    /// The span of time in which any enabled control is between keyframes.
    var animatedRanges: [ClosedRange<CMTime>] {
        guard enabled, !kind.isKeyframing else { return [] }
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
    /// The list effects of `kind` go in: the picture's stack, or the
    /// sound's.
    static func stack(for kind: EffectKind) -> WritableKeyPath<TimelineClip, [Effect]> {
        kind.isAudio ? \.audioEffects : \.effects
    }

    /// The list holding the effect with ID `id`, if the clip has it.
    func stack(holding id: UUID) -> WritableKeyPath<TimelineClip, [Effect]>? {
        if effects.contains(where: { $0.id == id }) { return \.effects }
        if audioEffects.contains(where: { $0.id == id }) { return \.audioEffects }
        return nil
    }

    /// The effect with ID `id`, in either list.
    func effect(id: UUID) -> Effect? {
        stack(holding: id).flatMap { self[keyPath: $0].first { $0.id == id } }
    }

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
        case .layerVolume(let layerID), .layerPan(let layerID):
            guard let layer = timeline.layer(id: layerID) else { return key.parameter.name }
            return "\(displayName(of: layer, in: timeline)) · \(key.parameter.name)"
        case .clipVolume(let clipID), .clipPan(let clipID), .anchorPoint(let clipID), .speed(let clipID):
            return "\(clipName(clipID, in: key.timelineID)) · \(key.parameter.name)"
        case .control(_, let clipID, let effectID, _):
            let effect = clipAndLayer(clipID, in: key.timelineID)?.clip.effect(id: effectID)
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
    /// end (a Keyframing effect at the top): a sound effect to its sound's.
    /// Clips with no pictures take no picture effects, and clips with no
    /// sound no sound effects. A Keyframing effect writes to the first
    /// control below it that no other one does. Returns the effect's ID.
    @discardableResult
    mutating func addEffect(_ kind: EffectKind, toClip clipID: UUID, in timelineID: UUID, at index: Int? = nil) -> UUID? {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip,
              kind.isAudio ? playsAudio(clip) : hasEffectStack(clip)
        else { return nil }
        let stack = TimelineClip.stack(for: kind)
        var effect = Effect.make(kind, among: clip[keyPath: stack])
        if let frame = timeline(id: timelineID)?.frameSize { effect.sizeShape(to: frame) }
        let count = clip[keyPath: stack].count
        let at = min(max(index ?? (kind.isKeyframing ? 0 : count), 0), count)
        var placed = clip
        placed[keyPath: stack].insert(effect, at: at)
        if kind.isKeyframing {
            // The first that no other Keyframing effect writes to, since two
            // on one control would undo each other.
            let taken = Set(placed.effects.compactMap { $0.keyframing?.target })
            let targets = keyframingTargets(forEffectAt: at, in: placed)
            effect.keyframing?.target = targets.first { !taken.contains($0) } ?? targets.first
        }
        editClip(clipID, in: timelineID) { clip in
            clip[keyPath: stack].insert(effect, at: at)
        }
        if kind.isKeyframing { regenerateKeyframes(ofEffect: effect.id, onClip: clipID, in: timelineID) }
        return effect.id
    }

    /// Applies `change` to one effect of a clip. A Keyframing effect then
    /// makes its keyframes again; one pointed somewhere else leaves what it
    /// wrote on its old target as plain keyframes.
    mutating func editEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID, _ change: (inout Effect) -> Void) {
        var before: Effect?
        var after: Effect?
        editClip(clipID, in: timelineID) { clip in
            guard let stack = clip.stack(holding: effectID), let index = clip[keyPath: stack].index(of: effectID) else { return }
            before = clip[keyPath: stack][index]
            change(&clip[keyPath: stack][index])
            after = clip[keyPath: stack][index]
            if let old = before?.keyframing?.target, old != after?.keyframing?.target {
                clip.releaseKeyframes(of: effectID, on: old)
            }
        }
        if let after, after.kind.isKeyframing, after != before {
            regenerateKeyframes(ofEffect: effectID, onClip: clipID, in: timelineID)
        }
    }

    /// Removes an effect. A Keyframing effect takes what it wrote with it,
    /// putting its target back as it was.
    mutating func removeEffect(_ effectID: UUID, fromClip clipID: UUID, in timelineID: UUID) {
        restoreKeyframingBase(ofEffect: effectID, onClip: clipID, in: timelineID)
        editClip(clipID, in: timelineID) { clip in
            guard let stack = clip.stack(holding: effectID) else { return }
            clip[keyPath: stack].removeAll { $0.id == effectID }
        }
    }

    /// Moves an effect to `index` in its stack (0 is the top).
    mutating func moveEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID, toIndex index: Int) {
        editClip(clipID, in: timelineID) { clip in
            guard let stack = clip.stack(holding: effectID), let from = clip[keyPath: stack].index(of: effectID) else { return }
            let effect = clip[keyPath: stack].remove(at: from)
            clip[keyPath: stack].insert(effect, at: min(max(index, 0), clip[keyPath: stack].count))
        }
    }

    /// Puts a copy of an effect just below it, named for the stack.
    @discardableResult
    mutating func duplicateEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID) -> UUID? {
        var copyID: UUID?
        editClip(clipID, in: timelineID) { clip in
            guard let stack = clip.stack(holding: effectID), let index = clip[keyPath: stack].index(of: effectID) else { return }
            let original = clip[keyPath: stack][index]
            var copy = original.duplicated(named: Effect.make(original.kind, among: clip[keyPath: stack]).name)
            // Two effects writing to one control would undo each other.
            copy.keyframing?.target = nil
            clip[keyPath: stack].insert(copy, at: index + 1)
            copyID = copy.id
        }
        return copyID
    }
}

// MARK: - Easing at the playhead

extension TimelineClip {
    /// Applies an ease to every keyframe the clip's anchor point, volume,
    /// pan and effect controls have at `time` in the timeline, for the F9 keys.
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
        if pan.keyframe(at: source) != nil {
            pan.applyEase(preset, at: source)
            eased = true
        }
        if self.time.speed.keyframe(at: source) != nil {
            self.time.speed.applyEase(preset, at: source)
            eased = true
        }
        for stack in [\TimelineClip.effects, \.audioEffects] {
            for e in self[keyPath: stack].indices {
                for c in self[keyPath: stack][e].controls.indices where self[keyPath: stack][e].controls[c].number.keyframe(at: source) != nil {
                    self[keyPath: stack][e].controls[c].number.applyEase(preset, at: source)
                    eased = true
                }
            }
        }
        return eased
    }
}
