import Foundation

/// What an effect is and how it is set, in words: what the browser shows
/// of a preset's effects when the pointer rests on it.
struct EffectSummary: Equatable {
    var name: String
    /// The kind's name, when the effect was given a name of its own.
    var kindName: String?
    var systemImage: String
    var enabled: Bool
    /// The controls that differ from a new effect of the kind, in the
    /// effect's order: "Segments 8", "Mode Soft Light", "Rotation animated".
    var settings: [String]
}

extension Effect {
    var summary: EffectSummary {
        let fresh = Effect(kind: kind)
        let settings = controls.compactMap { control -> String? in
            let start = fresh.controls.first { $0.kind == control.kind }
            var text: String
            if control.kind.isChoice {
                guard control.choice != (start?.choice ?? control.kind.defaultChoice) else { return nil }
                let option = control.kind.choiceOptions.first { $0.id == control.choice }
                text = "\(control.kind.name) \(option?.name ?? control.choice ?? "")"
            } else if control.isAnimated {
                text = "\(control.kind.name) animated"
            } else {
                let values = control.number.value.values
                guard values != (start?.number.value.values ?? control.kind.defaultValues) else { return nil }
                // A colour's four numbers say little, a curve's points less;
                // that it was set is enough.
                text = control.kind.isColor || control.kind.isCurve
                    ? "\(control.kind.name) set"
                    : "\(control.kind.name) \(values.map(Self.format).joined(separator: ", "))\(control.kind.unit)"
            }
            if !control.enabled { text += " (off)" }
            return text
        }
        return EffectSummary(
            name: displayName,
            kindName: name == nil || name == kind.name ? nil : kind.name,
            systemImage: kind.systemImage,
            enabled: enabled,
            settings: settings
        )
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}
