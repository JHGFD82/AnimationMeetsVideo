import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// How an effect is described in a preset's contents.
@Suite struct EffectSummaryTests {
    @Test func aNewEffectHasNothingToSay() {
        let summary = Effect(kind: .feedback).summary
        #expect(summary.name == "Feedback")
        #expect(summary.kindName == nil)
        #expect(summary.settings.isEmpty)
    }

    @Test func onlyWhatDiffersFromANewEffectIsListed() {
        var grade = Effect(kind: .color, name: "Warm")
        grade.enabled = false
        grade.controls[3].number = AnimatedValue(ComponentValue(values: [25]))
        let summary = grade.summary
        #expect(summary.name == "Warm")
        #expect(summary.kindName == "Color")
        #expect(!summary.enabled)
        #expect(summary.settings == ["Temperature 25"])
    }

    @Test func choicesAndAnimationAreNamed() {
        var blend = Effect(kind: .blending)
        blend.controls[0].blendMode = .softLight
        var move = Effect(kind: .transform)
        move.controls[2].number.setAnimated(true, at: .zero)
        move.controls[2].enabled = false
        #expect(blend.summary.settings == ["Mode Soft Light"])
        #expect(move.summary.settings == ["Rotation animated (off)"])
    }
}
