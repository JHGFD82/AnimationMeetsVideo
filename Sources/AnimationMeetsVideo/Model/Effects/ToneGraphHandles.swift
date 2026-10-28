import CoreMedia
import Foundation

// The tone graph an effect package can ask for (see
// docs/effect-packages.md, "Graph"): tones from black to white across,
// what they become up. Curves are drawn and edited as themselves; any
// other look's response is measured from its kernel (`ToneResponse`), and
// its handles move its number controls through the package's expressions.

extension EffectKind {
    /// The tone graph its package asks the effects panel for, if any.
    var toneGraph: EffectPackage.Graph? { definition.package?.graph }
}

extension EffectPackage.Graph.Handle {
    /// Where it is on the graph for `effect` at source time `time`: tones
    /// across and up, which may lie past 0...1.
    func place(in effect: Effect, of package: EffectPackage, at time: CMTime) -> (x: Double, y: Double) {
        let values = ControlReadings(effect: effect, package: package, time: time)
        return (x.number(values), y.number(values))
    }

    /// What dragging it to tones (`x`, `y`) sets each control to, all
    /// worked out from the controls as they were, so one set never reads
    /// another's new value. Values that aren't numbers are left out.
    func settings(draggedTo x: Double, _ y: Double, in effect: Effect, of package: EffectPackage, at time: CMTime) -> [(ControlKind, Double)] {
        let values = ControlReadings(effect: effect, package: package, time: time, extra: ["x": x, "y": y])
        return sets.compactMap { set in
            let value = set.value.number(values)
            return value.isFinite ? (set.control, value) : nil
        }
    }

    /// `effect` with it dragged to tones (`x`, `y`): each control it sets
    /// switched on and set at `time` (a keyframe there when animated).
    func dragging(_ effect: Effect, of package: EffectPackage, to x: Double, _ y: Double, at time: CMTime) -> Effect {
        var effect = effect
        for (kind, value) in settings(draggedTo: x, y, in: effect, of: package, at: time) {
            effect.changeControl(kind) { control in
                control.enabled = true
                control.setComponent(0, to: value, at: time)
            }
        }
        return effect
    }
}

/// What a graph's expressions read: each of the effect's controls at a
/// source time, at its default when it is off or deleted, as the renderer
/// reads them; and a handle's `x` and `y` while it is dragged.
struct ControlReadings: EffectExpression.Values {
    let effect: Effect
    let package: EffectPackage
    let time: CMTime
    var extra: [String: Double] = [:]

    private func definition(_ name: String) -> ControlDefinition? {
        let kind = ControlKind(package: package.id, control: name)
        return package.controls.first { $0.kind == kind }
    }

    func value(_ name: String) -> [Double] {
        if let value = extra[name] { return [value] }
        if name == "pi" { return [.pi] }
        guard let definition = definition(name) else { return [0] }
        guard let control = effect.control(definition.kind), control.enabled else { return definition.defaultValues }
        return control.values(at: time).enumerated().map { definition.kind.clamped($1, index: $0) }
    }

    func center(_ name: String) -> [Double] { value(name) }

    func index(_ name: String) -> Double {
        guard let definition = definition(name) else { return 0 }
        let choice = effect.control(definition.kind).flatMap { $0.enabled ? $0.choice : nil } ?? definition.defaultChoice
        return Double(definition.choiceOptions.firstIndex { $0.id == choice } ?? 0)
    }
}
