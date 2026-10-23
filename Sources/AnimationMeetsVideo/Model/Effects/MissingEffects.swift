import Foundation

/// An effect saved with a package that isn't installed where the project
/// is opened, or with a newer version of it (see docs/effect-packages.md,
/// "Missing effects"). It draws nothing and can't be edited, but is kept
/// as it was saved and written back the same, so installing the package
/// brings it back.
struct MissingEffect: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case notInstalled
        /// Its package is installed, but doesn't list a control it has.
        case needsNewerVersion
    }

    /// The kind it was saved as: its package's ID.
    var kind: String
    var reason: Reason
    /// The effect as it was read. Written back with only its ID and
    /// whether it is on changed.
    var saved: JSONValue
    /// What it is shown as: the name it was given, its package's name, or
    /// the last part of the ID.
    var name: String

    init(kind: String, reason: Reason, saved: JSONValue) {
        self.kind = kind
        self.reason = reason
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
        switch reason {
        case .notInstalled:
            "Not installed (\(kind)), so it draws nothing. Installing its effect package brings it back as it was."
        case .needsNewerVersion:
            "Saved with a newer version of its effect package (\(kind)), so it draws nothing until that version is installed."
        }
    }
}
