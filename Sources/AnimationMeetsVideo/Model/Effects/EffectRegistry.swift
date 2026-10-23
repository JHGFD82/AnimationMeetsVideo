import Foundation

/// Every effect kind and control kind the app knows, and what each is. The
/// built-in ones are listed in BuiltInEffects.swift; effect packages (see
/// docs/effect-packages.md) will add theirs.
struct EffectRegistry: Sendable {
    /// The effect kinds, in the library's order.
    let effects: [EffectDefinition]
    private let effectsByName: [String: EffectDefinition]
    private let controlsByName: [String: ControlDefinition]

    init(effects: [EffectDefinition], controls: [ControlDefinition]) {
        self.effects = effects
        effectsByName = Dictionary(uniqueKeysWithValues: effects.map { ($0.kind.rawValue, $0) })
        controlsByName = Dictionary(uniqueKeysWithValues: controls.map { ($0.kind.rawValue, $0) })
    }

    static let current = EffectRegistry(effects: BuiltInEffects.effects, controls: BuiltInEffects.controls)

    /// The effect kind saved as `name`, if there is one.
    func effect(named name: String) -> EffectDefinition? { effectsByName[name] }

    /// The control kind saved as `name`, if there is one.
    func control(named name: String) -> ControlDefinition? { controlsByName[name] }

    func definition(of kind: EffectKind) -> EffectDefinition {
        guard let definition = effectsByName[kind.rawValue] else { preconditionFailure("No effect kind \"\(kind.rawValue)\"") }
        return definition
    }

    func definition(of kind: ControlKind) -> ControlDefinition {
        guard let definition = controlsByName[kind.rawValue] else { preconditionFailure("No control kind \"\(kind.rawValue)\"") }
        return definition
    }
}

/// What one kind of effect is: how the library shows it, the controls a
/// new one lists, and how the renderer treats it.
struct EffectDefinition: Sendable {
    let kind: EffectKind
    let name: String
    let category: EffectCategory
    /// An SF Symbol.
    let systemImage: String
    /// The controls a new effect of this kind lists, in order.
    let controlKinds: [ControlKind]
    /// For a Keyframing effect: whether it reshapes the target's own
    /// keyframes, rather than making a signal combined with them.
    var reshapesTarget = false
    /// Whether the effect takes a picture dragged from the browser.
    var takesInput = false
    /// Whether it can read the picture as it was before an earlier effect
    /// in the stack ("Against").
    var readsAgainst = false
    /// Whether the picture it makes depends on the size it is drawn at
    /// (see `EffectKind.dependsOnPixelSize`).
    var dependsOnPixelSize = false
    /// Whether it replaces the picture with one it makes, rather than
    /// changing the one that reaches it.
    var generates = false

    init(
        _ kind: EffectKind, _ name: String, _ category: EffectCategory, _ systemImage: String, controls: [ControlKind],
        reshapesTarget: Bool = false, takesInput: Bool = false, readsAgainst: Bool = false,
        dependsOnPixelSize: Bool = false, generates: Bool = false
    ) {
        self.kind = kind
        self.name = name
        self.category = category
        self.systemImage = systemImage
        controlKinds = controls
        self.reshapesTarget = reshapesTarget
        self.takesInput = takesInput
        self.readsAgainst = readsAgainst
        self.dependsOnPixelSize = dependsOnPixelSize
        self.generates = generates
    }
}

/// What one kind of control is: its numbers or its choice, their default,
/// limits and unit.
struct ControlDefinition: Sendable {
    let kind: ControlKind
    let name: String
    /// The effect kind that lists it; for one every shape lists, the
    /// rectangle.
    let effectKind: EffectKind
    /// What it holds while it changes nothing; empty for a choice.
    var defaultValues: [Double] = []
    var unit = ""
    /// How far one point of dragging a value moves it.
    var dragStep = 1.0
    /// What a component is limited to, if anything.
    var range: ClosedRange<Double>?
    /// Whether it counts something, so it holds whole numbers.
    var isWhole = false
    /// Whether it is a color: red, green, blue and alpha, 0...1.
    var isColor = false
    /// The names of its components, for a graph's legend; nil for none
    /// (a choice), red to alpha (a color) or its own name (the rest).
    var componentNames: [String]?
    /// What a choice offers, as raw values and names; empty for numbers.
    var choiceOptions: [(id: String, name: String)] = []
    /// What a new choice control picks.
    var defaultChoice: String?

    init(
        _ kind: ControlKind, _ name: String, _ effectKind: EffectKind, defaults: [Double] = [], unit: String = "",
        dragStep: Double = 1, range: ClosedRange<Double>? = nil, isWhole: Bool = false, isColor: Bool = false,
        componentNames: [String]? = nil
    ) {
        self.kind = kind
        self.name = name
        self.effectKind = effectKind
        defaultValues = defaults
        self.unit = unit
        self.dragStep = dragStep
        self.range = range
        self.isWhole = isWhole
        self.isColor = isColor
        self.componentNames = componentNames
    }

    /// A choice from `Choice`'s options, starting at `choice`.
    init<Choice: ControlChoice>(_ kind: ControlKind, _ name: String, _ effectKind: EffectKind, choice: Choice) {
        self.kind = kind
        self.name = name
        self.effectKind = effectKind
        choiceOptions = Choice.allCases.map { ($0.rawValue, $0.name) }
        defaultChoice = choice.rawValue
    }

    /// An EQ band, whose components each have a unit and range of their
    /// own (see `ControlKind.unit(ofComponent:)`).
    init(_ kind: ControlKind, band: EqualizerBand) {
        self.kind = kind
        name = band.name
        effectKind = .equalizer
        defaultValues = band.defaultValues
        componentNames = band.componentNames
    }
}

/// The options of a choice control.
protocol ControlChoice: CaseIterable, RawRepresentable where RawValue == String {
    var name: String { get }
}

extension BlendMode: ControlChoice {}
extension MatteMode: ControlChoice {}
extension StrokeEdge: ControlChoice {}
extension StrokeJoin: ControlChoice {}
extension StrokeCap: ControlChoice {}
extension EqualizerSlope: ControlChoice {}
extension BeatSelection: ControlChoice {}
extension BeatShape: ControlChoice {}
extension WiggleType: ControlChoice {}
extension WiggleDimensions: ControlChoice {}
extension OscillatorWave: ControlChoice {}
extension LoopMode: ControlChoice {}
extension LoopSide: ControlChoice {}
extension KeyCurve: ControlChoice {}
extension PaletteLook: ControlChoice {}
extension SolarizeChannels: ControlChoice {}
extension FalseColorLook: ControlChoice {}
extension EdgeColoring: ControlChoice {}
extension GrainChannels: ControlChoice {}
extension NoiseType: ControlChoice {}
extension CellOutput: ControlChoice {}
extension DitherPattern: ControlChoice {}
extension MapCenter: ControlChoice {}
extension TwirlShape: ControlChoice {}
extension WaveDirection: ControlChoice {}
extension TilePattern: ControlChoice {}
extension AberrationMode: ControlChoice {}
extension SlitDirection: ControlChoice {}
