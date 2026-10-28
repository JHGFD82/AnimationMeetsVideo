import Foundation

/// What a package effect couldn't keep of its controls when they were
/// fitted to its package as it now is (see docs/effect-packages.md,
/// "Changing one while the app runs"), for its note in the effects panel.
struct PackageControlChanges: Equatable, Sendable {
    /// Controls its package no longer has, by saved name, as they were
    /// saved: held, never drawn, and left out when the effect is saved.
    var held: [String: JSONValue] = [:]
    /// Controls set back to their defaults, by saved name, with why ("it is
    /// now 2 numbers").
    var reset: [String: String] = [:]

    var isEmpty: Bool { held.isEmpty && reset.isEmpty }

    /// "Saved with a control this package no longer has: `glow`. `offset`
    /// was reset: it is now 2 numbers."
    var note: String? {
        guard !isEmpty else { return nil }
        var sentences: [String] = []
        if !held.isEmpty {
            let names = held.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")
            sentences.append(
                (held.count == 1 ? "Saved with a control this package no longer has: " : "Saved with controls this package no longer has: ")
                    + names + "; saving leaves \(held.count == 1 ? "it" : "them") out."
            )
        }
        for (name, why) in reset.sorted(by: { $0.key < $1.key }) {
            sentences.append("`\(name)` was reset: \(why).")
        }
        return sentences.joined(separator: " ")
    }
}

extension Effect {
    /// Fits this effect's controls to its package as the registry has it
    /// now, for one read from a file, restored by undo, pasted, or in an
    /// open project when its package changes: a control the package no
    /// longer lists is held (`packageChanges`); a number control whose
    /// values are no longer the package's count goes back to its default;
    /// a choice no longer among its options goes back to the default
    /// option. With `old`, the package as it was, a control it has gained
    /// since is added at its default; otherwise one missing stays missing,
    /// as a deleted control does. Returns whether anything changed.
    @discardableResult
    mutating func fitToPackage(newSince old: EffectPackage? = nil) -> Bool {
        guard missing == nil, EffectRegistry.current.effect(named: kind.rawValue)?.package != nil else { return false }
        let listed = kind.controlKinds
        let before = self
        var kept: [EffectControl] = []
        for var control in controls {
            guard listed.contains(control.kind) else {
                packageChanges.held[control.kind.savedName] = Self.saved(control)
                continue
            }
            let definition = control.kind.definition
            if control.kind.isChoice {
                if let choice = control.choice, !definition.choiceOptions.contains(where: { $0.id == choice }) {
                    control.choice = definition.defaultChoice
                    packageChanges.reset[control.kind.savedName] = "\"\(choice)\" isn't one of its options now"
                }
            } else if !definition.isCurve {
                let count = definition.defaultValues.count
                let values = [control.number.value] + control.number.keyframes.map(\.value)
                if values.contains(where: { $0.values.count != count }) {
                    control.number = AnimatedValue(ComponentValue(values: definition.defaultValues))
                    packageChanges.reset[control.kind.savedName] = "it is now " + Self.describe(definition)
                }
            }
            kept.append(control)
        }
        if let old {
            let had = Set(old.definition.controlKinds)
            for (place, kind) in listed.enumerated() where !had.contains(kind) && !kept.contains(where: { $0.kind == kind }) {
                let after = kept.firstIndex { listed.firstIndex(of: $0.kind).map { $0 > place } ?? false } ?? kept.endIndex
                kept.insert(EffectControl(kind: kind, enabled: kind.startsEnabled), at: after)
            }
        }
        controls = kept
        return self != before
    }

    /// A control as a project file saves it, to hold.
    private static func saved(_ control: EffectControl) -> JSONValue {
        let data = (try? JSONEncoder().encode(ProjectFile.ControlEntry(control))) ?? Data("{}".utf8)
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
    }

    /// What a control's values are: "a color", "one number", "2 numbers".
    private static func describe(_ definition: ControlDefinition) -> String {
        let count = definition.defaultValues.count
        if definition.isColor { return "a color" }
        return count == 1 ? "one number" : "\(count) numbers"
    }
}

extension EditingProject {
    /// Fits every package effect to its package as it now is
    /// (`Effect.fitToPackage`), adding controls gained since `old`, the
    /// packages as they were by ID. Returns whether anything changed.
    @discardableResult
    mutating func fitPackageEffects(newSince old: [String: EffectPackage] = [:]) -> Bool {
        var changed = false
        for t in timelines.indices {
            for l in timelines[t].layers.indices {
                for c in timelines[t].layers[l].clips.indices {
                    for e in timelines[t].layers[l].clips[c].effects.indices {
                        let id = timelines[t].layers[l].clips[c].effects[e].kind.rawValue
                        guard id.contains(".") else { continue }
                        if timelines[t].layers[l].clips[c].effects[e].fitToPackage(newSince: old[id]) { changed = true }
                    }
                }
            }
        }
        return changed
    }
}
