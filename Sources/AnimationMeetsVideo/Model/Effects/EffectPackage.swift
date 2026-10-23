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
    let kernelSource: String
    /// The package's own controls, in order, without Amount.
    let controls: [ControlDefinition]
    /// Whether the standard Amount control comes last.
    let hasAmount: Bool
    let arguments: [EffectExpression]
    let generates: Bool
    let changesEveryFrame: Bool
    let dependsOnPixelSize: Bool
    let flashes: Bool
    /// The speeds: while one isn't 0 the effect changes on its own.
    let rateControls: Set<ControlKind>
    let reach: EffectExpression?
    let edges: Edges
    let after: [Filter]

    var kind: EffectKind { EffectKind(package: id) }

    var definition: EffectDefinition {
        var definition = EffectDefinition(
            kind, name, category, systemImage, controls: controls.map(\.kind) + (hasAmount ? [.amount] : []),
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
