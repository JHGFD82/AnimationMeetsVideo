import Foundation

/// A titled group of an effect's controls, as the effects panel shows them
/// under a header: a Text effect's Character, Paragraph, Path, OpenType
/// and Fill & Stroke, a shape's Shape and Fill & Stroke.
struct ControlSection: Sendable, Equatable {
    let name: String
    /// The controls it holds, in the order the panel lists them.
    let kinds: [ControlKind]
    /// Whether the font's variation axes (`TextContent.variations`) are
    /// listed in it, after its controls: they are a Text effect's
    /// character settings, though not controls.
    var holdsFontAxes = false

    init(_ name: String, _ kinds: [ControlKind], holdsFontAxes: Bool = false) {
        self.name = name
        self.kinds = kinds
        self.holdsFontAxes = holdsFontAxes
    }
}

extension EffectKind {
    /// The groups its controls are listed in under headers; empty for one
    /// whose few controls need none.
    var sections: [ControlSection] { definition.sections }

    /// Whether the effects panel leaves out its choices, which can't be
    /// keyframed and are set in the inspector, where each shape and text
    /// lists every setting it has (see docs/effects.md, "The effects
    /// panel"). Other effects keep their choices in the panel, the only
    /// place they are set: a Blending's mode, a Text Animator's or a
    /// Keyframing effect's settings for what it animates.
    var choicesInInspector: Bool { isShape && self != .textAnimator }

    /// Whether the effects panel lists `control` of an effect of this
    /// kind: every number and color, which can be keyframed, and a choice
    /// only where the inspector doesn't set it.
    func panelLists(_ control: ControlKind) -> Bool {
        !(control.isChoice && choicesInInspector)
    }
}

extension Effect {
    /// The effect's controls as the effects panel lists them: under each
    /// of its kind's sections, those it has of the section's kinds in the
    /// effect's own order, a section with none left out unless it holds
    /// the font's axes; then, untitled, any it has that no section names.
    /// One group, untitled, for a kind without sections. Controls the
    /// panel doesn't list (`EffectKind.panelLists`) are left out.
    func panelSections() -> [(section: ControlSection?, controls: [EffectControl])] {
        let listed = controls.filter { kind.panelLists($0.kind) }
        let sections = kind.sections
        guard !sections.isEmpty else { return [(nil, listed)] }
        var groups: [(section: ControlSection?, controls: [EffectControl])] = []
        for section in sections {
            let members = listed.filter { section.kinds.contains($0.kind) }
            if !members.isEmpty || (section.holdsFontAxes && kind == .text) {
                groups.append((section, members))
            }
        }
        let named = Set(sections.flatMap(\.kinds))
        let rest = listed.filter { !named.contains($0.kind) }
        if !rest.isEmpty { groups.append((nil, rest)) }
        return groups
    }
}
