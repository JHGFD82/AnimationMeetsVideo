import Foundation
import Synchronization

/// Every effect kind and control kind the app knows, and what each is: the
/// ones written in Swift (BuiltInEffects.swift), those of the effect
/// packages that ship with the app (Resources/Effects), and those of the
/// person's packages, added at launch (see docs/effect-packages.md).
struct EffectRegistry: Sendable {
    /// The effect kinds, in the library's order.
    let effects: [EffectDefinition]
    /// The packages that couldn't be installed, and why.
    let problems: [EffectPackageProblem]
    private let effectsByName: [String: EffectDefinition]
    private let controlsByName: [String: ControlDefinition]

    /// The Swift effects and controls, then each package's, in order, the
    /// built-in ones sorted into `BuiltInEffects.libraryOrder`. A package
    /// whose ID is taken isn't added, so one can never replace a built-in
    /// effect or a package installed before it; it joins `problems`, the
    /// packages that couldn't be read.
    init(
        effects: [EffectDefinition], controls: [ControlDefinition], packages: [EffectPackage],
        problems: [EffectPackageProblem] = []
    ) {
        var effects = effects
        var controls = controls
        var problems = problems
        var taken = Set(effects.map(\.kind.rawValue))
        for package in packages {
            guard taken.insert(package.id).inserted else {
                problems.append(EffectPackageProblem(url: package.url, message: "An effect called \"\(package.id)\" is already installed."))
                continue
            }
            effects.append(package.definition)
            controls += package.controls
        }
        let order = Dictionary(uniqueKeysWithValues: BuiltInEffects.libraryOrder.enumerated().map { ($1, $0) })
        self.effects = effects.enumerated()
            .sorted { (order[$0.element.kind.rawValue] ?? Int.max, $0.offset) < (order[$1.element.kind.rawValue] ?? Int.max, $1.offset) }
            .map(\.element)
        self.problems = problems
        effectsByName = Dictionary(uniqueKeysWithValues: effects.map { ($0.kind.rawValue, $0) })
        controlsByName = Dictionary(uniqueKeysWithValues: controls.map { ($0.kind.rawValue, $0) })
    }

    /// The packages that ship with the app, read once.
    static let builtInPackages = EffectPackageStore.loadBuiltIn()

    /// Every built-in effect, Swift's and the shipped packages', with
    /// `packages` after them.
    static func withBuiltIns(_ packages: [EffectPackage] = [], problems: [EffectPackageProblem] = []) -> EffectRegistry {
        EffectRegistry(
            effects: BuiltInEffects.effects, controls: BuiltInEffects.controls,
            packages: builtInPackages.packages + packages, problems: builtInPackages.problems + problems
        )
    }

    static let builtIn = withBuiltIns()

    private static let installed = Mutex(builtIn)

    /// A registry used in place of the installed one within a task, so a
    /// test can read packages without changing what other tests see.
    @TaskLocal static var override: EffectRegistry?

    /// The registry in use: the built-in effects until `install` adds the
    /// person's packages, at launch.
    static var current: EffectRegistry { override ?? installed.withLock { $0 } }

    /// This registry with `package` added beside the person's others, for
    /// one made or opened while the app runs. Throws if its ID is taken.
    func adding(_ package: EffectPackage) throws -> EffectRegistry {
        guard effect(named: package.id) == nil else { throw EffectRegistryError.taken(package.id) }
        let builtIn = Set(Self.builtInPackages.packages.map(\.id))
        let shipped = Set(Self.builtInPackages.problems.map(\.url))
        let theirs = effects.compactMap(\.package).filter { !builtIn.contains($0.id) }
        return Self.withBuiltIns(theirs + [package], problems: problems.filter { !shipped.contains($0.url) })
    }

    /// Adds `package` to the registry in use (see `adding`).
    static func add(_ package: EffectPackage) throws {
        try installed.withLock { registry in registry = try registry.adding(package) }
    }

    /// Puts `packages` beside the built-in effects, replacing any installed
    /// before, with `problems` the packages that couldn't be read.
    static func install(_ packages: [EffectPackage], problems: [EffectPackageProblem] = []) {
        let registry = withBuiltIns(packages, problems: problems)
        installed.withLock { $0 = registry }
    }

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

enum EffectRegistryError: LocalizedError {
    case taken(String)

    var errorDescription: String? {
        switch self {
        case .taken(let id): "An effect called \"\(id)\" is already installed."
        }
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
    /// The package it was read from; nil for one built into the app.
    var package: EffectPackage?
    /// Whether it is left out of `EffectKind.all`: never offered, nor
    /// saved under its own name.
    var isHidden = false

    init(
        _ kind: EffectKind, _ name: String, _ category: EffectCategory, _ systemImage: String, controls: [ControlKind],
        reshapesTarget: Bool = false, takesInput: Bool = false, readsAgainst: Bool = false,
        dependsOnPixelSize: Bool = false, generates: Bool = false, isHidden: Bool = false
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
        self.isHidden = isHidden
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
extension TextAlign: ControlChoice {}
extension TextKerning: ControlChoice {}
extension TextCase: ControlChoice {}
extension TextLigatures: ControlChoice {}
extension TextFigures: ControlChoice {}
extension OnOff: ControlChoice {}
extension EqualizerSlope: ControlChoice {}
extension BeatSelection: ControlChoice {}
extension BeatShape: ControlChoice {}
extension WiggleType: ControlChoice {}
extension WiggleDimensions: ControlChoice {}
extension OscillatorWave: ControlChoice {}
extension LoopMode: ControlChoice {}
extension LoopSide: ControlChoice {}
extension KeyCurve: ControlChoice {}
