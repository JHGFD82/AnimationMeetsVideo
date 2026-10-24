import CoreMedia
import Foundation

/// An effect read from an effect package (see docs/effect-packages.md): a
/// look drawn by one Core Image kernel, with its controls and how their
/// values become the kernel's arguments. `EffectPackageStore` reads and
/// checks them; once installed in the `EffectRegistry` an effect of its
/// kind is like any other.
struct EffectPackage: Sendable {
    /// The package format this app reads.
    static let formatVersion = 1
    static let fileExtension = "amveffect"

    enum KernelType: String, CaseIterable, Sendable {
        case color, warp, general
    }

    /// What a general kernel reads past the picture's edges.
    enum Edges: String, CaseIterable, Sendable {
        case clear, clamped
    }

    /// A picture the kernel reads besides the one reaching it (see
    /// docs/effect-packages.md, "Pictures besides the clip's").
    struct Picture: Sendable {
        enum Source: String, CaseIterable, Sendable {
            /// One dropped from the browser onto the effect.
            case input
            /// The clip's picture before the earlier step Against names.
            case against
            /// The picture reaching the step `delay` earlier.
            case moment
            /// The motion from this frame to the footage's frame `ahead`
            /// frames later, as a picture: red across, green up, in output
            /// pixels.
            case motion
        }

        var id: String
        var source: Source
        /// For a moment: how long before, in seconds, at each pass.
        var delay: EffectExpression?
        /// For a moment: whether one the composition doesn't have is the
        /// picture reaching the step, rather than transparent.
        var missingIsPicture = false
        /// For the motion: how many frames ahead it is measured to.
        var ahead: EffectExpression?
    }

    /// Running the kernel once per copy or band (see
    /// docs/effect-packages.md, "Repeating").
    struct Repeat: Sendable {
        var count: EffectExpression
        /// Which copy or band a pass draws; nil for the pass itself.
        var index: EffectExpression?
        var countWhilePlaying: EffectExpression?
        var indexWhilePlaying: EffectExpression?
        /// Whether the first pass draws over nothing, rather than over the
        /// picture reaching the step.
        var startsClear = false
    }

    /// Whether the effects panel warns that it can flash more than three
    /// times a second (see docs/psychedelic-effects.md, "Safety: flashing").
    enum Flashing: Sendable {
        case never
        case always
        /// While this isn't 0, with each control at its largest value.
        case when(EffectExpression)
    }

    /// A built-in Core Image filter applied to the kernel's result.
    struct Filter: Sendable {
        var name: String
        /// Applied only while this is not 0.
        var when: EffectExpression?
        /// By the filter's input key, in a fixed order.
        var parameters: [(key: String, value: EffectExpression)]
    }

    let url: URL
    let id: String
    let version: Int
    let name: String
    let category: EffectCategory
    let systemImage: String
    /// A hash of effect.json and the kernel, the same at every launch, so a
    /// render cached before either changed isn't shown after.
    let contentHash: String
    let kernelType: KernelType
    let kernelFunction: String
    /// The kernel's file in the package, for its compiler's messages.
    let kernelFile: String
    let kernelSource: String
    /// The package's own controls, in order, without Amount.
    let controls: [ControlDefinition]
    /// Where among `controls` the standard Amount control goes, if the
    /// effect has it: last unless effect.json places it.
    let amountIndex: Int?
    let arguments: [EffectExpression]
    let generates: Bool
    let changesEveryFrame: Bool
    let dependsOnPixelSize: Bool
    let flashes: Flashing
    /// The speeds: while one isn't 0 the effect changes on its own.
    let rateControls: Set<ControlKind>
    let reach: EffectExpression?
    /// What the kernel reads besides its picture, in order after it.
    let pictures: [Picture]
    /// When it does anything, from `hasInput` and `hasAgainst`; nil for
    /// always.
    let drawsWhen: EffectExpression?
    let repeats: Repeat?

    /// Whether it draws from moments of the footage besides this one.
    var readsMoments: Bool { pictures.contains { $0.source == .moment } }

    /// How many frames ahead in the footage `effect`, of this kind, reads
    /// the motion to, for the composition to have that frame; nil for one
    /// that doesn't read motion. With each control at its largest, as
    /// moments are planned; it is counted in frames, so no frame's length
    /// is needed.
    func framesAhead(of effect: Effect) -> Int? {
        guard let ahead = pictures.first(where: { $0.source == .motion })?.ahead else { return nil }
        return max(1, Int(ahead.number(LargestValues(effect: effect, package: self, frameDuration: 0))))
    }
    let edges: Edges
    let after: [Filter]

    var kind: EffectKind { EffectKind(package: id) }

    var hasAmount: Bool { amountIndex != nil }

    var takesInput: Bool { pictures.contains { $0.source == .input } }

    var readsAgainst: Bool { pictures.contains { $0.source == .against } }

    var definition: EffectDefinition {
        var kinds = controls.map(\.kind)
        if let amountIndex { kinds.insert(.amount, at: amountIndex) }
        var definition = EffectDefinition(
            kind, name, category, systemImage, controls: kinds, takesInput: takesInput, readsAgainst: readsAgainst,
            dependsOnPixelSize: dependsOnPixelSize, generates: generates
        )
        definition.package = self
        return definition
    }

    /// FNV-1a over the manifest and the kernel source, in hex.
    static func contentHash(_ manifest: Data, _ source: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in manifest + Data(source.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Whether `id` is one a package may take: letters, digits and
    /// hyphens, in parts joined by dots, each part starting with a letter.
    static func isValidID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            guard let first = part.first, first.isASCII, first.isLetter else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Whether `id` is one a control may take: a name an expression can
    /// use, so letters and digits starting with a letter.
    static func isValidControlID(_ id: String) -> Bool {
        guard let first = id.first, first.isASCII, first.isLetter else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

extension EffectPackage {
    /// The earlier moments `effect`, of this kind, draws from, for the
    /// composition to have frames there: each pass's delay, rounded to a
    /// frame, with each control at the largest value it takes.
    func momentDelays(of effect: Effect, frame: CMTime) -> [CMTime] {
        guard readsMoments, frame.seconds > 0 else { return [] }
        var values = LargestValues(effect: effect, package: self, frameDuration: frame.seconds)
        let count = repeats.map { max(0, Int($0.count.number(values))) } ?? 1
        var delays: Set<CMTime> = []
        for n in 0..<count {
            values.extra = ["pass": Double(n), "passes": Double(count)]
            values.extra["index"] = repeats?.index?.number(values) ?? Double(n)
            for picture in pictures where picture.source == .moment {
                let frames = ((picture.delay?.number(values) ?? 0) / frame.seconds).rounded()
                if frames > 0 { delays.insert(CMTimeMultiply(frame, multiplier: Int32(frames))) }
            }
        }
        return delays.sorted()
    }
}

/// What a package's moments are planned from: each control at the largest
/// value it takes across its keyframes, as it is set when not animated, at
/// its default when off.
struct LargestValues: EffectExpression.Values {
    let effect: Effect
    let package: EffectPackage
    let frameDuration: Double
    var extra: [String: Double] = [:]

    private func definition(_ name: String) -> ControlDefinition? {
        effect.kind.controlKind(savedAs: name).flatMap { kind in package.controls.first { $0.kind == kind } }
    }

    func value(_ name: String) -> [Double] {
        if name == "frameDuration" { return [frameDuration] }
        if let value = extra[name] { return [value] }
        guard let definition = definition(name) else { return [0] }
        guard let control = effect.control(definition.kind), control.enabled else { return definition.defaultValues }
        let values = control.number.isAnimated ? control.number.keyframes.map(\.value.values) : [control.number.value.values]
        let largest = values.max { ($0.first ?? 0) < ($1.first ?? 0) } ?? definition.defaultValues
        return largest.enumerated().map { definition.kind.clamped($1, index: $0) }
    }

    func center(_ name: String) -> [Double] { value(name) }

    func index(_ name: String) -> Double {
        guard let definition = definition(name) else { return 0 }
        let choice = effect.control(definition.kind).flatMap { $0.enabled ? $0.choice : nil } ?? definition.defaultChoice
        return Double(definition.choiceOptions.firstIndex { $0.id == choice } ?? 0)
    }
}

/// What a package's `drawsWhen` reads: whether the effect has its
/// pictures.
struct PictureFlags: EffectExpression.Values {
    var hasInput: Bool
    var hasAgainst: Bool
    var hasMotion = false

    func value(_ name: String) -> [Double] {
        switch name {
        case "hasInput": [hasInput ? 1 : 0]
        case "hasAgainst": [hasAgainst ? 1 : 0]
        case "hasMotion": [hasMotion ? 1 : 0]
        default: [0]
        }
    }

    func center(_ name: String) -> [Double] { [0, 0] }

    func index(_ name: String) -> Double { 0 }
}

extension EffectKind {
    /// The kind of the package effect `id`.
    init(package id: String) {
        self.init(builtIn: id)
    }

    /// The control the kind lists that is saved as `name`.
    func controlKind(savedAs name: String) -> ControlKind? {
        controlKinds.first { $0.savedName == name }
    }
}

extension ControlKind {
    /// Control `id` of package effect `package`. Each package's controls are
    /// its own: two packages' `radius` are different controls.
    init(package: String, control id: String) {
        self.init(builtIn: "\(package)/\(id)")
    }

    /// What it is saved as in a project: for a package's control, its ID
    /// within the package.
    var savedName: String {
        rawValue.split(separator: "/").last.map(String.init) ?? rawValue
    }
}
