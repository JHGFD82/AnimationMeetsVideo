import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct EffectStackTests {
    private func second(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func project(hasAudio: Bool = true) -> (project: EditingProject, layerID: UUID, clipID: UUID) {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "m", kind: .video, url: nil, duration: second(10), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264", hasAudio: hasAudio
        )
        let placed = project.importClip(media, intoTimeline: project.rootTimelineID)!
        return (project, placed.layerID, placed.clipID)
    }

    private func stack(_ p: EditingProject, _ clipID: UUID) -> [Effect] {
        p.clipAndLayer(clipID, in: p.rootTimelineID)!.clip.effects
    }

    @Test func effectsAreAddedToTheEndOrAtAPlace() {
        var (p, _, clip) = project()
        let t = p.rootTimelineID
        let first = p.addEffect(.transform, toClip: clip, in: t)!
        let second = p.addEffect(.blending, toClip: clip, in: t)!
        let inserted = p.addEffect(.transform, toClip: clip, in: t, at: 0)!
        #expect(stack(p, clip).map(\.id) == [inserted, first, second])
        // Numbered by kind, so the two Transforms can be told apart.
        #expect(stack(p, clip).map(\.displayName) == ["Transform 2", "Transform", "Blending"])
    }

    @Test func clipsWithoutPicturesTakeNoEffects() {
        var (p, layerID, clip) = project()
        let t = p.rootTimelineID
        p.detachAudio(of: [clip], in: t, layer: layerID)
        let sound = p.timeline(id: t)!.layers.first { $0.kind == .sound }!.clips[0]
        #expect(p.addEffect(.transform, toClip: sound.id, in: t) == nil)
        #expect(!p.hasEffectStack(sound))
    }

    @Test func effectsMoveDuplicateAndGoAway() {
        var (p, _, clip) = project()
        let t = p.rootTimelineID
        let a = p.addEffect(.transform, toClip: clip, in: t)!
        let b = p.addEffect(.blending, toClip: clip, in: t)!
        let c = p.addEffect(.transform, toClip: clip, in: t)!

        p.moveEffect(c, ofClip: clip, in: t, toIndex: 0)
        #expect(stack(p, clip).map(\.id) == [c, a, b])
        p.moveEffect(c, ofClip: clip, in: t, toIndex: 2)
        #expect(stack(p, clip).map(\.id) == [a, b, c])

        let copy = p.duplicateEffect(a, ofClip: clip, in: t)!
        let effects = stack(p, clip)
        #expect(effects.map(\.id) == [a, copy, b, c])
        #expect(effects[1].controls.map(\.id) != effects[0].controls.map(\.id))
        #expect(effects[1].displayName == "Transform 3")

        p.removeEffect(b, fromClip: clip, in: t)
        #expect(stack(p, clip).map(\.id) == [a, copy, c])
    }

    @Test func controlsCanBeDeletedReorderedAndPutBack() {
        var effect = Effect(kind: .transform)
        let rotation = effect.control(.rotation)!.id
        effect.removeControl(effect.control(.opacity)!.id)
        #expect(effect.controls.map(\.kind) == [.position, .scale, .rotation])
        #expect(effect.missingControlKinds == [.opacity])

        effect.moveControl(rotation, toIndex: 0)
        #expect(effect.controls.map(\.kind) == [.rotation, .position, .scale])
        effect.addControl(.opacity)
        #expect(effect.controls.map(\.kind) == [.rotation, .position, .scale, .opacity])
        // A control of another effect, or one already there, isn't added.
        effect.addControl(.mode)
        effect.addControl(.opacity)
        #expect(effect.controls.count == 4)
    }

    @Test func resettingAnEffectKeepsItsIdentityAndClearsKeyframes() {
        var effect = Effect(kind: .transform, name: "Nudge")
        effect.controls[0].setComponent(0, to: 20, at: .zero)
        effect.controls[2].number.setAnimated(true, at: .zero)
        effect.movesAnchor = false
        let id = effect.id
        effect.reset()
        #expect(effect.id == id && effect.name == "Nudge")
        #expect(effect.isNoOp && effect.movesAnchor)
        #expect(effect.controls.allSatisfy { !$0.isAnimated })
    }

    @Test func easingActsOnEveryKeyframeAtTheTimeInSourceTime() {
        var (p, _, clip) = project()
        let t = p.rootTimelineID
        let id = p.addEffect(.transform, toClip: clip, in: t)!
        // Trimmed 2 s in and moved to 5 s: timeline time 6 s is source 3 s.
        p.editClip(clip, in: t) {
            $0.trimStart = second(2)
            $0.startOffset = second(5)
            $0.volume.setAnimated(true, at: second(3))
            $0.volume.set(-20, at: second(6))
        }
        p.editEffect(id, ofClip: clip, in: t) { effect in
            effect.controls[2].number.setAnimated(true, at: second(3))
            effect.controls[2].number.set(ComponentValue(values: [90]), at: second(6))
        }
        var changed = p.clipAndLayer(clip, in: t)!.clip
        let didEase = changed.easeKeyframes(atTimelineTime: second(6), .easyEase)
        #expect(didEase)
        #expect(changed.volume.keyframes[0].easeOut == .easy)
        #expect(changed.effects[0].controls[2].number.keyframes[0].easeOut == .easy)
        // Nothing at another time.
        var other = p.clipAndLayer(clip, in: t)!.clip
        let didEaseOther = other.easeKeyframes(atTimelineTime: second(7), .easyEase)
        #expect(!didEaseOther)
    }

    @Test func aClipsKeyframesStayOnThePictureWhenItIsMovedOrTrimmed() {
        var (p, layerID, clip) = project()
        let t = p.rootTimelineID
        let id = p.addEffect(.transform, toClip: clip, in: t)!
        p.editEffect(id, ofClip: clip, in: t) { effect in
            effect.controls[2].number.setAnimated(true, at: second(1))
            effect.controls[2].number.set(ComponentValue(values: [90]), at: second(3))
        }
        let before = stack(p, clip)[0].controls[2].number
        p.moveClip(clip, in: t, layer: layerID, to: second(4))
        #expect(stack(p, clip)[0].controls[2].number == before)
        p.trimClipStart(clip, in: t, layer: layerID, to: second(1))
        #expect(stack(p, clip)[0].controls[2].number == before)
        // A split gives each half the full stack, so each keeps its animation.
        let moved = p.clipAndLayer(clip, in: t)!.clip
        p.split(clip, in: t, layer: layerID, atTimelineTime: CMTimeAdd(moved.startOffset, second(2)))
        let halves = p.timeline(id: t)!.layers.first { $0.id == layerID }!.clips
        #expect(halves.count == 2)
        #expect(halves.allSatisfy { $0.effects[0].controls[2].number == before })
    }
}

@Suite struct ShapeDefaultTests {
    @Test func aNewShapesSizeIsItsDefaultAndResetGoesBackToIt() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.ellipse, to: timelineID)
        let shape = try #require(added)
        let frame = try #require(project.timeline(id: timelineID)?.frameSize)
        let effect = try #require(project.clipAndLayer(shape.clipID, in: timelineID)?.clip.effects.first)
        let size = try #require(effect.control(.shapeSize))
        let fresh = effect.freshControl(.shapeSize, in: frame)
        #expect(size.isAtDefault(like: fresh))
        // Not the kind's own default, which isn't fitted to any frame.
        #expect(!size.isAtDefault)
        var changed = size
        changed.setComponent(0, to: 10, at: .zero)
        #expect(!changed.isAtDefault(like: fresh))
        changed.reset(to: fresh)
        #expect(changed.number == size.number)
    }
}
