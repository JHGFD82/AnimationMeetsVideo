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
    /// The kinds that can be added and saved, in the library's order
    /// (`EffectKind.all`).
    let addable: [EffectKind]
    private let effectsByName: [String: EffectDefinition]
    private let controlsByName: [String: ControlDefinition]
    /// The definitions of effects and controls that packages changed or
    /// removed while the app runs stopped listing, by name. Effects in open
    /// projects may still hold them, so they are looked up here when the
    /// registry no longer lists them, and such an effect keeps drawing and
    /// editing as it did; it can't be added again, and a control saves no
    /// more (`ProjectFile.EffectEntry`).
    private var retiredEffects: [String: EffectDefinition] = [:]
    private var retiredControls: [String: ControlDefinition] = [:]

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
        effects = effects.map { $0.resolved() }
        let order = Dictionary(uniqueKeysWithValues: BuiltInEffects.libraryOrder.enumerated().map { ($1, $0) })
        self.effects = effects.enumerated()
            .sorted { (order[$0.element.kind.rawValue] ?? Int.max, $0.offset) < (order[$1.element.kind.rawValue] ?? Int.max, $1.offset) }
            .map(\.element)
        self.problems = problems
        addable = self.effects.filter { !$0.isHidden }.map(\.kind)
        let effectsByName = Dictionary(uniqueKeysWithValues: effects.map { ($0.kind.rawValue, $0) })
        self.effectsByName = effectsByName
        controlsByName = Dictionary(uniqueKeysWithValues: controls.map {
            ($0.kind.rawValue, $0.resolved(owner: effectsByName[$0.effectKind.rawValue]))
        })
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
        return changingTheirs { packages, _ in packages.append(package) }
    }

    /// This registry with the person's packages and the problems of
    /// packages not shipped with the app as `change` leaves them, the
    /// built-in effects as they are.
    func changingTheirs(_ change: (inout [EffectPackage], inout [EffectPackageProblem]) -> Void) -> EffectRegistry {
        let builtIn = Set(Self.builtInPackages.packages.map(\.id))
        let shipped = Set(Self.builtInPackages.problems.map(\.url))
        var theirs = effects.compactMap(\.package).filter { !builtIn.contains($0.id) }
        var problems = problems.filter { !shipped.contains($0.url) }
        change(&theirs, &problems)
        var changed = Self.withBuiltIns(theirs, problems: problems)
        changed.retiredEffects = retiredEffects.merging(effectsByName) { $1 }.filter { changed.effectsByName[$0.key] == nil }
        changed.retiredControls = retiredControls.merging(controlsByName) { $1 }.filter { changed.controlsByName[$0.key] == nil }
        return changed
    }

    /// Whether `kind` was a package's that was removed or renamed while the
    /// app runs: still drawn where it is, but no longer listed.
    func isRetired(_ kind: EffectKind) -> Bool {
        effectsByName[kind.rawValue] == nil && retiredEffects[kind.rawValue] != nil
    }

    /// Adds `package` to the registry in use (see `adding`).
    static func add(_ package: EffectPackage) throws {
        try installed.withLock { registry in registry = try registry.adding(package) }
    }

    /// This registry with the person's package at `url` read again as
    /// `read`, nil for one removed, and the package added or changed, whose
    /// kernel is to be compiled. A new package is added, and a changed one
    /// replaces the one installed; effects of it in open projects are then
    /// fitted to it (`EditingProject.fitPackageEffects`). One removed, or
    /// whose ID changed, is no longer listed, and effects of it already in
    /// open projects draw as they did (`retiredEffects`). One that can no
    /// longer be read joins the problems, the one installed before staying
    /// in use.
    func reloading(_ url: URL, as read: Result<EffectPackage, any Error>?) -> (registry: EffectRegistry, changed: EffectPackage?) {
        let url = url.standardizedFileURL
        let installed = effects.lazy.compactMap(\.package).first { $0.url.standardizedFileURL == url }
        var problem: String?
        var removed: String?
        var changed: EffectPackage?
        switch read {
        case nil:
            removed = installed?.id
        case .failure(let error)?:
            problem = error.localizedDescription
        case .success(let package)?:
            if let installed, installed.id == package.id {
                if installed.contentHash != package.contentHash { changed = package }
            } else if effect(named: package.id) != nil {
                // The one installed from here, under its old ID, stays.
                problem = EffectRegistryError.taken(package.id).localizedDescription
            } else {
                removed = installed?.id
                changed = package
            }
        }
        let registry = changingTheirs { packages, problems in
            problems.removeAll { $0.url.standardizedFileURL == url }
            if let problem { problems.append(EffectPackageProblem(url: url, message: problem)) }
            if let removed { packages.removeAll { $0.id == removed } }
            guard let changed else { return }
            if let index = packages.firstIndex(where: { $0.id == changed.id }) {
                packages[index] = changed
            } else {
                packages.append(changed)
            }
        }
        return (registry, changed)
    }

    /// Reloads the package at `url` in the registry in use (see
    /// `reloading`), returning the package added or changed, and the one
    /// of its ID it replaced.
    static func reload(_ url: URL, as read: Result<EffectPackage, any Error>?) -> Reload {
        installed.withLock { registry in
            let reloaded = registry.reloading(url, as: read)
            let replaced = reloaded.changed.flatMap { registry.effect(named: $0.id)?.package }
            registry = reloaded.registry
            return Reload(changed: reloaded.changed, replaced: replaced)
        }
    }

    /// What reloading a package changed.
    struct Reload: Sendable {
        /// The package added or changed, whose kernel is to be compiled.
        var changed: EffectPackage?
        /// The version of it installed before, for one changed.
        var replaced: EffectPackage?
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
        guard let definition = effectsByName[kind.rawValue] ?? retiredEffects[kind.rawValue] else {
            preconditionFailure("No effect kind \"\(kind.rawValue)\"")
        }
        return definition
    }

    func definition(of kind: ControlKind) -> ControlDefinition {
        guard let definition = controlsByName[kind.rawValue] ?? retiredControls[kind.rawValue] else {
            preconditionFailure("No control kind \"\(kind.rawValue)\"")
        }
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
    /// The groups the effects panel lists its controls in, under headers
    /// (see `ControlSection`); empty for none.
    var sections: [ControlSection] = []
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

    // Worked out from the rest when the registry is made, so that reading
    // one costs a single lookup (see `EffectKind`).
    fileprivate(set) var isLook = false
    fileprivate(set) var drawsShape = false
    fileprivate(set) var readsBesidePixels = false

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

    /// One whose controls are listed in `sections`, under headers: a new
    /// one lists them all, a section's after the one before it.
    init(
        _ kind: EffectKind, _ name: String, _ category: EffectCategory, _ systemImage: String, sections: [ControlSection],
        reshapesTarget: Bool = false
    ) {
        self.init(kind, name, category, systemImage, controls: sections.flatMap(\.kinds), reshapesTarget: reshapesTarget)
        self.sections = sections
    }

    fileprivate func resolved() -> EffectDefinition {
        var resolved = self
        resolved.isLook = EffectPackageStore.categories.contains(category)
        resolved.drawsShape = category == .shapes && kind != .stroke && kind != .textAnimator
        if let package {
            resolved.readsBesidePixels = (package.kernelType != .color && !package.readsOnlyItsPixel) || !package.after.isEmpty
        } else {
            resolved.readsBesidePixels = category == .distortion
        }
        return resolved
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
    /// Whether it is a tone curve (`ToneCurve`), its points' numbers in
    /// turn, edited on its effect's graph rather than as numbers.
    var isCurve = false
    /// For a curve: the color its line is drawn in on the graph.
    var curveTint = CurveTint.white
    /// For an EQ band's control: the band.
    var equalizerBand: EqualizerBand?

    // Worked out from the rest when the registry is made (see
    // `ControlKind`).
    fileprivate(set) var hasNeutralDefault = true
    fileprivate(set) var defaultValue = ComponentValue(values: [])
    fileprivate(set) var legend: [String] = []

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
        equalizerBand = band
    }

    /// A tone curve, starting at `defaults` (the identity unless given).
    init(_ kind: ControlKind, _ name: String, _ effectKind: EffectKind, curve defaults: ToneCurve = .identity, tint: CurveTint) {
        self.kind = kind
        self.name = name
        self.effectKind = effectKind
        defaultValues = defaults.values
        range = 0...1
        dragStep = 0.01
        componentNames = []
        isCurve = true
        curveTint = tint
    }

    /// With what follows from the rest filled in; `owner` is the definition
    /// of `effectKind`.
    fileprivate func resolved(owner: EffectDefinition?) -> ControlDefinition {
        var resolved = self
        // A compressor's, limiter's or voice isolation's controls always
        // matter: at their defaults they still work. So do a shape's, which
        // draw it, a Keyframing effect's, which it makes keyframes from,
        // and a look's, which are what it looks like.
        if let owner {
            resolved.hasNeutralDefault = switch owner.kind {
            case .compressor, .limiter, .voiceIsolation: false
            default: !(owner.category == .keyframing || owner.isLook || owner.category == .shapes)
            }
        }
        resolved.defaultValue = ComponentValue(values: defaultValues)
        resolved.legend = componentNames ?? (!choiceOptions.isEmpty ? [] : isColor ? ["Red", "Green", "Blue", "Alpha"] : [name])
        return resolved
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
extension TextAnchor: ControlChoice {}
extension TextAnimatorUnit: ControlChoice {}
extension TextAnimatorShape: ControlChoice {}
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
