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
    case sound

    var id: Self { self }

    var name: String {
        switch self {
        case .foundations: "Foundations"
        case .shapes: "Shapes"
        case .mattes: "Mattes"
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

/// The kinds of effect the library offers. Sound effects (see
/// docs/audio.md, "Sound effects") go in a clip's `audioEffects` and play
/// through Apple's Audio Units; the rest change its picture.
enum EffectKind: String, CaseIterable, Identifiable, Sendable {
    case transform
    case blending
    case color
    case matte
    /// Shapes draw over the picture handed down to them (see
    /// docs/graphic-layers.md, "Shapes").
    case rectangle
    case ellipse
    case polygon
    case star
    /// Strokes the outline of the shapes above it in the stack, strokes and
    /// all, so a stroke can have a stroke of its own.
    case stroke
    case equalizer
    case compressor
    case limiter
    case voiceIsolation

    var id: Self { self }

    var name: String {
        switch self {
        case .transform: "Transform"
        case .blending: "Blending"
        case .color: "Color"
        case .matte: "Matte"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .polygon: "Polygon"
        case .star: "Star"
        case .stroke: "Stroke"
        case .equalizer: "EQ"
        case .compressor: "Compressor"
        case .limiter: "Limiter"
        case .voiceIsolation: "Voice Isolation"
        }
    }

    var category: EffectCategory {
        switch self {
        case .transform, .blending, .color: .foundations
        case .rectangle, .ellipse, .polygon, .star, .stroke: .shapes
        case .matte: .mattes
        case .equalizer, .compressor, .limiter, .voiceIsolation: .sound
        }
    }

    /// Whether it works on the clip's sound rather than its picture.
    var isAudio: Bool { category == .sound }

    /// Whether it is one of the shapes, or strokes them.
    var isShape: Bool { category == .shapes }

    /// Whether it draws a shape of its own, rather than stroking others.
    var drawsShape: Bool { isShape && self != .stroke }

    var systemImage: String {
        switch self {
        case .transform: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .blending: "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .color: "slider.horizontal.3"
        case .matte: "circle.dashed.inset.filled"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .polygon: "hexagon"
        case .star: "star"
        case .stroke: "circle.dashed"
        case .equalizer: "slider.vertical.3"
        case .compressor: "arrow.down.right.and.arrow.up.left"
        case .limiter: "line.horizontal.star.fill.line.horizontal"
        case .voiceIsolation: "person.wave.2"
        }
    }

    /// Whether the effect takes a picture dragged from the browser.
    var takesInput: Bool { self == .matte }

    /// Whether the picture it makes depends on the size it is drawn at, so a
    /// nested timeline holding it can't have its move pushed into its
    /// layers (a blur whose radius is in pixels, say). Effects that work on
    /// single pixels, or move them, don't, and shapes are drawn at the size
    /// they end up.
    var dependsOnPixelSize: Bool {
        switch self {
        case .transform, .blending, .color, .matte, .rectangle, .ellipse, .polygon, .star, .stroke,
             .equalizer, .compressor, .limiter, .voiceIsolation: false
        }
    }

    /// How a shape is filled and stroked, after what shapes it.
    static let paintControls: [ControlKind] = [.fill, .stroke, .strokeWidth, .strokeEdge, .strokeJoin, .strokeCap, .dash]

    /// The controls a new effect of this kind lists, in order.
    var controlKinds: [ControlKind] {
        switch self {
        case .transform: [.position, .scale, .rotation, .opacity]
        case .blending: [.mode, .amount]
        case .color: [.exposure, .contrast, .saturation, .temperature, .tint, .lift, .gamma, .gain]
        case .matte: [.matteMode, .amount]
        case .rectangle: [.shapeSize, .cornerRadius, .shapePosition] + Self.paintControls
        case .ellipse: [.shapeSize, .shapePosition] + Self.paintControls
        case .polygon: [.points, .radius, .cornerRadius, .shapeRotation, .shapePosition] + Self.paintControls
        case .star: [.points, .radius, .innerRadius, .cornerRadius, .shapeRotation, .shapePosition] + Self.paintControls
        case .stroke: [.stroke, .strokeWidth, .strokeEdge, .strokeJoin, .strokeCap, .dash]
        case .equalizer: [.lowCut, .bass, .mid, .midFrequency, .treble]
        case .compressor: [.threshold, .headroom, .attack, .release, .makeup]
        case .limiter: [.drive, .limiterRelease]
        case .voiceIsolation: [.isolation]
        }
    }
}

/// One control of an effect. Each is a step of its own.
enum ControlKind: String, CaseIterable, Identifiable, Sendable {
    case position, scale, rotation, opacity
    case mode, amount
    case exposure, contrast, saturation, temperature, tint, lift, gamma, gain
    case matteMode
    case shapeSize, cornerRadius, shapePosition, fill, stroke, strokeWidth
    case strokeEdge, strokeJoin, strokeCap, dash
    case points, radius, innerRadius, shapeRotation
    case lowCut, bass, mid, midFrequency, treble
    case threshold, headroom, attack, release, makeup
    case drive, limiterRelease
    case isolation

    var id: Self { self }

    var name: String {
        switch self {
        case .position: "Position"
        case .scale: "Scale"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        case .mode: "Mode"
        case .matteMode: "Take"
        case .amount: "Amount"
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .lift: "Lift"
        case .gamma: "Gamma"
        case .gain: "Gain"
        case .shapeSize: "Size"
        case .cornerRadius: "Corners"
        case .shapePosition: "Position"
        case .fill: "Fill"
        case .stroke: "Stroke"
        case .strokeWidth: "Stroke Width"
        case .strokeEdge: "Edge"
        case .strokeJoin: "Join"
        case .strokeCap: "Cap"
        case .dash: "Dash"
        case .points: "Points"
        case .radius: "Radius"
        case .innerRadius: "Inner Radius"
        case .shapeRotation: "Rotation"
        case .lowCut: "Low Cut"
        case .bass: "Bass"
        case .mid: "Mid"
        case .midFrequency: "Mid Freq"
        case .treble: "Treble"
        case .threshold: "Threshold"
        case .headroom: "Headroom"
        case .attack: "Attack"
        case .release, .limiterRelease: "Release"
        case .makeup: "Makeup"
        case .drive: "Drive"
        case .isolation: "Isolation"
        }
    }

    /// The effect kind that lists the control; for one every shape lists,
    /// the rectangle.
    var effectKind: EffectKind {
        switch self {
        case .position, .scale, .rotation, .opacity: .transform
        case .mode: .blending
        case .amount: .blending
        case .matteMode: .matte
        case .exposure, .contrast, .saturation, .temperature, .tint, .lift, .gamma, .gain: .color
        case .shapeSize, .cornerRadius, .shapePosition, .fill, .stroke, .strokeWidth: .rectangle
        case .strokeEdge, .strokeJoin, .strokeCap, .dash: .rectangle
        case .points, .radius, .shapeRotation: .polygon
        case .innerRadius: .star
        case .lowCut, .bass, .mid, .midFrequency, .treble: .equalizer
        case .threshold, .headroom, .attack, .release, .makeup: .compressor
        case .drive, .limiterRelease: .limiter
        case .isolation: .voiceIsolation
        }
    }

    /// Whether the control changes nothing at its default, so it can be
    /// shown dimmed there. A compressor's, limiter's or voice isolation's
    /// controls always matter: at their defaults they still work. So do a
    /// shape's, which draw it.
    var hasNeutralDefault: Bool {
        switch effectKind {
        case .compressor, .limiter, .voiceIsolation: false
        default: !effectKind.isShape
        }
    }

    /// Whether the control is a choice from a list rather than numbers.
    var isChoice: Bool { !choiceOptions.isEmpty }

    /// What a choice offers, as raw values and names; empty for numbers.
    var choiceOptions: [(id: String, name: String)] {
        switch self {
        case .mode: BlendMode.allCases.map { ($0.rawValue, $0.name) }
        case .matteMode: MatteMode.allCases.map { ($0.rawValue, $0.name) }
        case .strokeEdge: StrokeEdge.allCases.map { ($0.rawValue, $0.name) }
        case .strokeJoin: StrokeJoin.allCases.map { ($0.rawValue, $0.name) }
        case .strokeCap: StrokeCap.allCases.map { ($0.rawValue, $0.name) }
        default: []
        }
    }

    /// What a new choice control picks.
    var defaultChoice: String? {
        switch self {
        case .mode: BlendMode.normal.rawValue
        case .matteMode: MatteMode.alpha.rawValue
        case .strokeEdge: StrokeEdge.center.rawValue
        case .strokeJoin: StrokeJoin.miter.rawValue
        case .strokeCap: StrokeCap.butt.rawValue
        default: nil
        }
    }

    /// Whether its two axes can be linked, so editing one changes the other
    /// in proportion.
    var isLinkable: Bool { self == .scale || self == .shapeSize }

    /// Whether a new control's axes are linked: a scale's are, a shape's
    /// size, whose width is usually set on its own, isn't.
    var linksByDefault: Bool { self == .scale }

    /// Whether the control is a color: red, green, blue and alpha, 0...1,
    /// as the timeline's encoded values (as a transition's dip color is).
    var isColor: Bool { self == .fill || self == .stroke }

    /// The names of its components, for a graph's legend.
    var componentNames: [String] {
        switch self {
        case .position: ["Δx", "Δy"]
        case .scale: ["x", "y"]
        case .mode, .matteMode: []
        case .lift, .gamma, .gain: ["All", "Red", "Green", "Blue"]
        case .shapeSize: ["Width", "Height"]
        case .shapePosition: ["Δx", "Δy"]
        case .fill, .stroke: ["Red", "Green", "Blue", "Alpha"]
        case .dash: ["Dash", "Gap"]
        case .strokeEdge, .strokeJoin, .strokeCap: []
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
        case .mode, .matteMode: []
        case .shapeSize: [640, 360]
        case .cornerRadius, .strokeWidth: [0]
        case .shapePosition: [0, 0]
        case .fill: [1, 1, 1, 1]
        case .stroke: [0, 0, 0, 1]
        case .strokeEdge, .strokeJoin, .strokeCap: []
        case .dash: [0, 0]
        case .points: [5]
        case .radius: [180]
        case .innerRadius: [90]
        case .shapeRotation: [0]
        case .lowCut: [20]
        case .bass, .mid, .treble, .makeup, .drive: [0]
        case .midFrequency: [1000]
        case .threshold: [-20]
        case .headroom: [5]
        case .attack: [10]
        case .release: [100]
        case .limiterRelease: [5]
        case .isolation: [100]
        }
    }

    var unit: String {
        switch self {
        case .position, .shapeSize, .cornerRadius, .shapePosition, .strokeWidth, .dash, .radius, .innerRadius: " px"
        case .fill, .stroke, .strokeEdge, .strokeJoin, .strokeCap, .points: ""
        case .shapeRotation: "°"
        case .scale, .opacity, .amount, .contrast, .saturation, .isolation: "%"
        case .rotation: "°"
        case .exposure: " stops"
        case .mode, .matteMode, .temperature, .tint, .lift, .gamma, .gain: ""
        case .lowCut, .midFrequency: " Hz"
        case .bass, .mid, .treble, .threshold, .headroom, .makeup, .drive: " dB"
        case .attack, .release, .limiterRelease: " ms"
        }
    }

    /// How far one point of dragging a value moves it: a pixel, a percent,
    /// a degree, a tenth of a stop.
    var dragStep: Double {
        switch self {
        case .exposure: 0.1
        case .lift, .gamma, .gain, .fill, .stroke: 0.01
        case .headroom: 0.1
        case .midFrequency: 10
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
        case .position, .scale, .rotation, .mode, .matteMode, .shapePosition, .shapeRotation: nil
        case .strokeEdge, .strokeJoin, .strokeCap: nil
        case .dash: 0...10_000
        case .points: 3...100
        case .radius, .innerRadius: 0...50_000
        case .shapeSize: 0...100_000
        case .cornerRadius: 0...50_000
        case .strokeWidth: 0...10_000
        case .fill, .stroke: 0...1
        case .lowCut: 20...1000
        case .bass, .mid, .treble: -24...24
        case .midFrequency: 100...10000
        case .threshold: -60...0
        case .headroom: 0.1...40
        case .attack: 1...300
        case .release: 10...3000
        case .makeup: -20...40
        case .drive: 0...24
        case .limiterRelease: 1...40
        case .isolation: 0...100
        }
    }

    /// A component limited to what the control allows; a count of points
    /// is whole.
    func clamped(_ component: Double) -> Double {
        let whole = self == .points ? component.rounded() : component
        guard let range else { return whole }
        return min(max(whole, range.lowerBound), range.upperBound)
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
    /// The option picked, for a choice: a raw value of one of its
    /// `choiceOptions`.
    var choice: String?
    /// Whether editing one axis of a scale or a size changes the other in
    /// proportion.
    var linked = true

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
        if kind == .mode { return blendMode == .normal }
        if kind == .matteMode { return false }
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
    /// What pasting or applying a preset couldn't bring over, until each is
    /// marked resolved (see docs/effects.md, "Paste changes").
    var pasteChanges: [PasteChange] = []
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

    /// True when nothing in the effect changes the picture, or for a
    /// sound effect the sound.
    var isNoOp: Bool {
        guard enabled else { return true }
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
    /// end: a sound effect to its sound's. Clips with no pictures take no
    /// picture effects, and clips with no sound no sound effects. Returns
    /// the effect's ID.
    @discardableResult
    mutating func addEffect(_ kind: EffectKind, toClip clipID: UUID, in timelineID: UUID, at index: Int? = nil) -> UUID? {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip,
              kind.isAudio ? playsAudio(clip) : hasEffectStack(clip)
        else { return nil }
        let stack = TimelineClip.stack(for: kind)
        var effect = Effect.make(kind, among: clip[keyPath: stack])
        if let frame = timeline(id: timelineID)?.frameSize { effect.sizeShape(to: frame) }
        editClip(clipID, in: timelineID) { clip in
            let count = clip[keyPath: stack].count
            clip[keyPath: stack].insert(effect, at: min(max(index ?? count, 0), count))
        }
        return effect.id
    }

    /// Applies `change` to one effect of a clip.
    mutating func editEffect(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID, _ change: (inout Effect) -> Void) {
        editClip(clipID, in: timelineID) { clip in
            guard let stack = clip.stack(holding: effectID), let index = clip[keyPath: stack].index(of: effectID) else { return }
            change(&clip[keyPath: stack][index])
        }
    }

    mutating func removeEffect(_ effectID: UUID, fromClip clipID: UUID, in timelineID: UUID) {
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
            let copy = original.duplicated(named: Effect.make(original.kind, among: clip[keyPath: stack]).name)
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
