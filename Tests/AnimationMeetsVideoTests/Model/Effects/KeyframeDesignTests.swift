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

    @Test func bakingForgetsWhatTheControlWasBefore() throws {
        var f = Fixture()
        let before = try #require(f.transform.control(.position)).number
        let made = f.set(.wiggler)
        let wiggler = try #require(made)
        f.project.bakeKeyframing(wiggler, ofClip: f.clipID, in: f.timelineID)
        let baked = try #require(f.transform.control(.position)).number
        #expect(baked != before)
        #expect(baked.keyframes.allSatisfy { $0.generatedBy == nil })
        // A method picked now starts from the baked keyframes, not from
        // the control as it was before the first one, and None puts the
        // baked ones back.
        let madeAgain = f.set(.oscillator)
        let oscillator = try #require(madeAgain)
        #expect(f.clip.effect(id: oscillator)?.keyframing?.base == baked)
        _ = f.set(nil)
        #expect(try #require(f.transform.control(.position)).number == baked)
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

    @Test func theStackDoesntListMethods() throws {
        var f = Fixture()
        let made = f.set(.wiggler)
        let id = try #require(made)
        #expect(f.clip.effects.contains { $0.id == id })
        #expect(f.clip.stackEffects.map(\.id) == [f.colorID, f.transformID])
    }

    @Test func deletingTheControlsEffectTakesItsMethodAway() throws {
        var f = Fixture()
        let made = f.set(.oscillator)
        let id = try #require(made)
        f.project.removeEffect(f.transformID, fromClip: f.clipID, in: f.timelineID)
        #expect(f.clip.effect(id: id) == nil)
        #expect(f.clip.effects.map(\.id) == [f.colorID])
    }

    @Test func removingTheControlTakesItsMethodAway() throws {
        var f = Fixture()
        let made = f.set(.oscillator)
        let id = try #require(made)
        let controlID = try #require(f.transform.control(.position)).id
        f.project.editEffect(f.transformID, ofClip: f.clipID, in: f.timelineID) { $0.removeControl(controlID) }
        #expect(f.clip.effect(id: id) == nil)
    }

    @Test func copyingAnEffectBringsItsMethodsAlong() throws {
        var f = Fixture()
        let made = f.set(.wiggler)
        let id = try #require(made)
        let bundle = try #require(f.project.bundle(ofEffects: [f.transformID], fromClip: f.clipID, in: f.timelineID))
        #expect(bundle.effects.map(\.effect.id).contains(id))
        // Pasted onto a second clip, the copy drives the copied Position.
        let media = MediaClip(
            name: "B.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264"
        )
        let imported = f.project.importClip(media, intoTimeline: f.timelineID)
        let other = try #require(imported).clipID
        let pasted = f.project.paste(bundle, ontoClip: other, in: f.timelineID)
        let clip = try #require(f.project.clipAndLayer(other, in: f.timelineID)?.clip)
        let transform = try #require(clip.effects.first { $0.kind == .transform && pasted.contains($0.id) })
        let wiggler = try #require(clip.effects.first { $0.kind == .wiggler })
        let position = try #require(transform.control(.position))
        #expect(wiggler.keyframing?.target == .control(effectID: transform.id, controlID: position.id))
        #expect(position.number.keyframes.contains { $0.generatedBy == wiggler.id })
    }

    @Test func duplicatingAnEffectBringsItsMethodsAlong() throws {
        var f = Fixture()
        let made = f.set(.wiggler)
        let id = try #require(made)
        let duplicated = f.project.duplicateEffect(f.transformID, ofClip: f.clipID, in: f.timelineID)
        let copyID = try #require(duplicated)
        let copy = try #require(f.clip.effect(id: copyID))
        let position = try #require(copy.control(.position))
        let drivers = f.clip.effects.filter { $0.kind == .wiggler }
        #expect(drivers.count == 2)
        let driver = try #require(drivers.first { $0.id != id })
        #expect(driver.keyframing?.target == .control(effectID: copyID, controlID: position.id))
        #expect(position.number.keyframes.allSatisfy { $0.generatedBy == driver.id })
        // The original still drives its own.
        #expect(f.project.keyframingEffect(driving: f.position, in: f.clip)?.id == id)
        // Changing the copy's method leaves the original's keyframes alone.
        let before = try #require(f.transform.control(.position)).number
        f.project.editEffect(driver.id, ofClip: f.clipID, in: f.timelineID) { effect in
            effect.changeControl(.seed) { $0.setComponent(0, to: 7, at: .zero) }
        }
        #expect(try #require(f.transform.control(.position)).number == before)
    }
}
