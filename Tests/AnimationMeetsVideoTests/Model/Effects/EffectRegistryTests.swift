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
        #expect(EffectKind(rawValue: "shimmer") == nil)
        #expect(ControlKind(rawValue: "shimmerRadius") == nil)
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

    /// What the registry works out once for each kind is what reading its
    /// definition would give.
    @Test func whatIsWorkedOutAgreesWithTheDefinitions() {
        for kind in registry.effects.map(\.kind) {
            let definition = kind.definition
            #expect(kind.isLook == EffectPackageStore.categories.contains(definition.category), "\(kind.rawValue)")
            #expect(kind.drawsShape == (kind.isShape && kind != .stroke && kind != .textAnimator), "\(kind.rawValue)")
            for control in kind.controlKinds where control.effectKind == kind {
                let neutral = switch kind {
                case .compressor, .limiter, .voiceIsolation: false
                default: !(kind.isKeyframing || kind.isLook || kind.isShape)
                }
                #expect(control.hasNeutralDefault == neutral, "\(control.rawValue)")
                #expect(control.definition.defaultValue.values == control.defaultValues, "\(control.rawValue)")
                #expect(control.equalizerBand == EqualizerBand.allCases.first { $0.controlKind == control }, "\(control.rawValue)")
            }
        }
        #expect(EffectKind.all == registry.effects.filter { !$0.isHidden }.map(\.kind))
    }

    /// A fresh control is the one a new effect, sized to the frame, holds.
    @Test func aFreshControlIsANewEffectsControl() {
        let frame = CGSize(width: 1920, height: 1080)
        for kind in EffectKind.all {
            var made = Effect(kind: kind)
            made.sizeShape(to: frame)
            for control in made.controls {
                let fresh = made.freshControl(control.kind, in: frame)
                #expect(fresh.number == control.number && fresh.choice == control.choice, "\(control.kind.rawValue)")
                #expect(control.isAtDefault == control.isAtDefault(like: EffectControl(kind: control.kind)))
            }
        }
    }
}
