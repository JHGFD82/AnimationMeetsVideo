import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// How the effects panel groups an effect's controls under headers, and
/// which it lists.
@Suite struct ControlSectionsTests {
    @Test func aSectionedKindListsEveryControlOfItsSectionsOnce() {
        for kind in EffectKind.all where !kind.sections.isEmpty {
            let named = kind.sections.flatMap(\.kinds)
            #expect(named == kind.controlKinds, "\(kind.rawValue)")
            #expect(Set(named).count == named.count, "\(kind.rawValue) names a control twice")
        }
    }

    @Test func textIsGroupedAsTheInspectorGroupsIt() {
        let sections = EffectKind.text.sections
        #expect(sections.map(\.name) == ["Character", "Paragraph", "Path", "OpenType", "Fill & Stroke"])
        #expect(sections.filter(\.holdsFontAxes).map(\.name) == ["Character"])
        #expect(EffectKind.rectangle.sections.map(\.name) == ["Shape", "Fill & Stroke"])
    }

    /// Only what can be keyframed: a shape's choices are the inspector's.
    @Test func aShapeListsItsNumbersAndColorsOnly() {
        let text = Effect(kind: .text)
        let listed = text.panelSections().flatMap(\.controls)
        #expect(!listed.isEmpty)
        #expect(listed.allSatisfy { !$0.kind.isChoice })
        #expect(listed.map(\.kind) == text.controls.map(\.kind).filter { !$0.isChoice })
        #expect(text.panelSections().compactMap(\.section?.name) == ["Character", "Paragraph", "Path", "OpenType", "Fill & Stroke"])

        let rectangle = Effect(kind: .rectangle)
        let groups = rectangle.panelSections()
        #expect(groups.compactMap(\.section?.name) == ["Shape", "Fill & Stroke"])
        #expect(groups[1].controls.map(\.kind) == [.fill, .stroke, .strokeWidth, .dash])
        #expect(Effect(kind: .stroke).panelSections().flatMap(\.controls).map(\.kind) == [.stroke, .strokeWidth, .dash])
    }

    /// Where the panel is the only place to set a choice, it keeps it.
    @Test func otherEffectsKeepTheirChoices() {
        for kind in [EffectKind.blending, .matte, .textAnimator, .wiggler, .looper, .equalizer] {
            let effect = Effect(kind: kind)
            #expect(Set(effect.panelSections().flatMap(\.controls).map(\.id)) == Set(effect.controls.map(\.id)), "\(kind.rawValue)")
        }
    }

    /// A section keeps the effect's own order, and one left empty is
    /// left out; a kind without sections is one untitled group.
    @Test func sectionsFollowTheEffectsOrder() {
        var color = Effect(kind: .color)
        color.moveControl(color.controls[1].id, toIndex: 0)
        color.controls.removeAll { $0.kind == .temperature || $0.kind == .tint }
        let groups = color.panelSections()
        #expect(groups.map(\.section?.name) == ["Tone", "Lift, Gamma, Gain"])
        #expect(groups[0].controls.map(\.kind) == [.contrast, .exposure, .saturation])

        let transform = Effect(kind: .transform)
        #expect(transform.panelSections().count == 1)
        #expect(transform.panelSections()[0].section == nil)
    }
}
