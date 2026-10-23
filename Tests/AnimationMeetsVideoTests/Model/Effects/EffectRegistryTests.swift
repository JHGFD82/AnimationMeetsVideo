import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct EffectRegistryTests {
    private let registry = EffectRegistry.current

    @Test func kindsAreReadBackFromTheNamesTheyAreSavedUnder() {
        for kind in EffectKind.all {
            #expect(EffectKind(rawValue: kind.rawValue) == kind)
            for control in kind.controlKinds {
                #expect(ControlKind(rawValue: control.rawValue) == control)
            }
        }
        #expect(EffectKind(rawValue: "glow") == nil)
        #expect(ControlKind(rawValue: "glowRadius") == nil)
    }

    /// Swift's effects and the shipped packages' together, in the order
    /// the library has always shown them.
    @Test func theLibraryKeepsItsOrder() {
        #expect(EffectKind.all.map(\.rawValue) == BuiltInEffects.libraryOrder)
        #expect(registry.problems.isEmpty)
    }

    @Test func everyControlAnEffectListsIsRegistered() {
        for kind in EffectKind.all {
            for control in kind.controlKinds {
                #expect(registry.control(named: control.rawValue) != nil, "\(kind.rawValue) lists \(control.rawValue)")
            }
        }
    }

    @Test func everyControlBelongsToAnEffectThatListsIt() {
        for control in BuiltInEffects.controls {
            #expect(control.effectKind.controlKinds.contains(control.kind), "\(control.kind.rawValue)")
        }
    }

    @Test func choicesStartOnOneOfTheirOptions() {
        for control in BuiltInEffects.controls where control.kind.isChoice {
            #expect(control.kind.choiceOptions.contains { $0.id == control.defaultChoice }, "\(control.kind.rawValue)")
            #expect(control.defaultValues.isEmpty)
        }
    }

    @Test func numbersStartWithinTheirRange() {
        for control in BuiltInEffects.controls where !control.kind.isChoice {
            #expect(!control.defaultValues.isEmpty, "\(control.kind.rawValue)")
            for (index, value) in control.defaultValues.enumerated() {
                #expect(control.kind.clamped(value, index: index) == value, "\(control.kind.rawValue)[\(index)]")
            }
        }
    }
}
