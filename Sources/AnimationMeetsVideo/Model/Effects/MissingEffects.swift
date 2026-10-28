import Foundation

/// An effect saved with a package that isn't installed where the project
/// is opened (see docs/effect-packages.md, "Missing effects"). It draws
/// nothing and can't be edited, but is kept as it was saved and written
/// back the same, so installing the package brings it back. One whose
/// package is installed opens, its controls fitted to the package
/// (`Effect.fitToPackage`).
struct MissingEffect: Equatable, Sendable {
    /// The kind it was saved as: its package's ID.
    var kind: String
    /// The effect as it was read. Written back with only its ID and
    /// whether it is on changed.
    var saved: JSONValue
    /// What it is shown as: the name it was given, its package's name, or
    /// the last part of the ID.
    var name: String

    init(kind: String, saved: JSONValue) {
        self.kind = kind
        self.saved = saved
        let installed = EffectKind(rawValue: kind).map(\.name)
        let fromID = kind.split(separator: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? kind
        name = saved["name"]?.string ?? installed ?? fromID
    }

    /// The same, with its saved controls given new IDs, for a copy: IDs are
    /// how keyframing targets and selections find a control once the
    /// package is installed.
    func withNewControlIDs() -> MissingEffect {
        var copy = self
        if case .array(let controls)? = saved["controls"] {
            copy.saved["controls"] = .array(controls.map { control in
                var control = control
                if control["id"] != nil { control["id"] = .string(UUID().uuidString) }
                return control
            })
        }
        return copy
    }

    /// Why it does nothing, for the effects panel.
    var explanation: String {
        "Not installed (\(kind)), so it draws nothing. Installing its effect package brings it back as it was."
    }
}
