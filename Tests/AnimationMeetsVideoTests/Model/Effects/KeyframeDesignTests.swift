import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }

/// What the Keyframe Designer asks of the model: a method picked for a
/// control puts a Keyframing effect just above it, another method swaps
/// it, and None takes it away (see docs/keyframing-effects.md).
@MainActor struct KeyframeDesignTests {
    /// A 24 fps clip four seconds long, holding Color over a Transform.
    private struct Fixture {
        var project = EditingProject.empty
        let timelineID: UUID
        let clipID: UUID
        let colorID: UUID
        let transformID: UUID

        init() {
            let media = MediaClip(
                name: "A.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
                colorSpace: .rec709, codecName: "H.264"
            )
            timelineID = project.rootTimelineID
            clipID = project.importClip(media, intoTimeline: timelineID)!.clipID
            let id = clipID
            project.editClip(id, in: timelineID) { $0.trimStart = .zero; $0.trimEnd = seconds(4); $0.startOffset = .zero }
            colorID = project.addEffect(.color, toClip: clipID, in: timelineID)!
            transformID = project.addEffect(.transform, toClip: clipID, in: timelineID)!
        }

        var clip: TimelineClip { project.clipAndLayer(clipID, in: timelineID)!.clip }
        var transform: Effect { clip.effect(id: transformID)! }
        var position: KeyframingTarget { .control(effectID: transformID, controlID: transform.control(.position)!.id) }

        mutating func set(_ kind: EffectKind?) -> UUID? {
            project.setKeyframing(kind, driving: position, onClip: clipID, in: timelineID)
        }
    }

    @Test func aMethodGoesJustAboveTheControlsEffectAndWritesToIt() throws {
        var f = Fixture()
        let made = f.set(.wiggler)
        let id = try #require(made)
        let order = f.clip.effects.map(\.id)
        #expect(order == [f.colorID, id, f.transformID])
        let wiggler = try #require(f.clip.effect(id: id))
        #expect(wiggler.kind == .wiggler)
        #expect(wiggler.keyframing?.target == f.position)
        #expect(f.project.keyframingEffect(driving: f.position, in: f.clip)?.id == id)
        let position = try #require(f.transform.control(.position))
        #expect(position.number.keyframes.contains { $0.generatedBy == id })
    }

    @Test func anotherMethodTakesItsPlaceKeepingHowItApplies() throws {
        var f = Fixture()
        let madeWiggler = f.set(.wiggler)
        let wiggler = try #require(madeWiggler)
        f.project.editEffect(wiggler, ofClip: f.clipID, in: f.timelineID) { effect in
            effect.keyframing?.combine = .replace
            effect.keyframing?.component = 1
        }
        let madeOscillator = f.set(.oscillator)
        let oscillator = try #require(madeOscillator)
        #expect(oscillator != wiggler)
        #expect(f.clip.effect(id: wiggler) == nil)
        let effect = try #require(f.clip.effect(id: oscillator))
        #expect(effect.kind == .oscillator)
        #expect(effect.keyframing?.combine == .replace)
        #expect(effect.keyframing?.component == 1)
        #expect(f.clip.effects.map(\.id) == [f.colorID, oscillator, f.transformID])
        // Only the oscillator's keyframes are on the control now.
        let keyframes = try #require(f.transform.control(.position)).number.keyframes
        #expect(!keyframes.isEmpty)
        #expect(keyframes.allSatisfy { $0.generatedBy == oscillator })
    }

    @Test func noneTakesTheMethodAwayAndPutsTheControlBack() throws {
        var f = Fixture()
        let before = try #require(f.transform.control(.position)).number
        _ = f.set(.wiggler)
        _ = f.set(.beatKeys)
        let none = f.set(nil)
        #expect(none == nil)
        #expect(!f.clip.effects.contains { $0.kind.isKeyframing })
        #expect(try #require(f.transform.control(.position)).number == before)
    }

    @Test func pickingTheSameMethodChangesNothing() throws {
        var f = Fixture()
        let made = f.set(.smoother)
        let first = try #require(made)
        let project = f.project
        let again = f.set(.smoother)
        #expect(again == first)
        #expect(f.project == project)
    }

    @Test func theDesignerOffersNumericControlsOnly() {
        let f = Fixture()
        let controls = EditingProject.designableControls(of: f.transform)
        #expect(!controls.isEmpty)
        #expect(controls.allSatisfy { !$0.kind.isChoice && !$0.kind.isCurve })
        #expect(EditingProject.designableControls(of: Effect.make(.wiggler, among: [])).isEmpty)
    }

    @Test func keyframingEffectsAreNotInTheLibrary() {
        #expect(!EffectsListPanel.kinds.contains { $0.isKeyframing })
        #expect(EffectsListPanel.kinds.contains(.transform))
    }
}
