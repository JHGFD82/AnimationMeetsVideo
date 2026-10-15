import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ReadingStackTests {
    private func blending(against: UUID? = nil) -> Effect {
        var effect = Effect(kind: .blending)
        effect.controls[0].blendMode = .multiply
        effect.against = against
        return effect
    }

    private func scale(_ percent: Double) -> Effect {
        var effect = Effect(kind: .transform, controls: [EffectControl(kind: .scale)])
        effect.controls[0].number = AnimatedValue(ComponentValue(values: [percent, percent]))
        return effect
    }

    private func media() -> MediaClip {
        MediaClip(name: "m", kind: .video, url: nil, duration: CMTime(value: 10, timescale: 1), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
    }

    /// Two layers on the root, the top one holding the clip.
    private func stack(of effects: [Effect]) -> (project: EditingProject, clip: UUID) {
        var project = EditingProject.empty
        project.importClip(media(), intoTimeline: project.rootTimelineID)
        let top = project.importClip(media(), intoTimeline: project.rootTimelineID)!
        project.editClip(top.clipID, in: project.rootTimelineID) { $0.effects = effects }
        return (project, top.clipID)
    }

    private func note(_ project: EditingProject, _ clipID: UUID, at index: Int, timeline: UUID? = nil) -> EffectNote? {
        let t = timeline ?? project.rootTimelineID
        let (clip, layer) = project.clipAndLayer(clipID, in: t)!
        return project.note(forEffectAt: index, in: clip, on: layer, of: project.timeline(id: t)!)
    }

    @Test func showingUpToAnEffectCutsTheStackAndDropsTransitionsWithoutTouchingTheProject() {
        let a = scale(50), b = blending(), c = scale(200)
        var (project, clipID) = stack(of: [a, b, c])
        project.editClip(clipID, in: project.rootTimelineID) {
            $0.transitionIn = ClipTransition(kind: .crossDissolve, duration: CMTime(value: 1, timescale: 1))
        }
        let shown = project.showing(upTo: b.id, ofClip: clipID, in: project.rootTimelineID)
        let clip = shown.clipAndLayer(clipID, in: shown.rootTimelineID)!.clip
        #expect(clip.effects.map(\.id) == [a.id, b.id])
        #expect(clip.transitionIn == nil && clip.transitionOut == nil)
        let original = project.clipAndLayer(clipID, in: project.rootTimelineID)!.clip
        #expect(original.effects.count == 3 && original.transitionIn != nil)
        #expect(project.hasEffect(c.id, ofClip: clipID, in: project.rootTimelineID))
        #expect(!project.hasEffect(UUID(), ofClip: clipID, in: project.rootTimelineID))
    }

    @Test func aBlendAgainstAnEffectThatIsGoneOrBelowItIsNoted() {
        let shrink = scale(50)
        // Against an effect above it: nothing to say.
        var (project, clip) = stack(of: [shrink, blending(against: shrink.id)])
        #expect(note(project, clip, at: 1) == nil)
        // Against one that was dragged below it, or deleted.
        let below = stack(of: [blending(against: shrink.id), shrink])
        #expect(note(below.project, below.clip, at: 0)?.dims == true)
        let gone = stack(of: [blending(against: UUID())])
        #expect(note(gone.project, gone.clip, at: 0)?.dims == true)
        // A disabled step has no note, it is simply off.
        project.editEffect(project.clipAndLayer(clip, in: project.rootTimelineID)!.clip.effects[1].id, ofClip: clip, in: project.rootTimelineID) { $0.enabled = false }
        #expect(note(project, clip, at: 1) == nil)
    }

    @Test func theBottomClipOfANestedTimelineHasNothingToBlendWith() {
        var project = EditingProject.empty
        let inner = project.addTimeline(name: "Inner", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        let bottom = project.importClip(media(), intoTimeline: inner)!
        let top = project.importClip(media(), intoTimeline: inner)!
        for id in [bottom.clipID, top.clipID] {
            project.editClip(id, in: inner) { $0.effects = [blending()] }
        }
        // On its own, an inner timeline is drawn over black: no note.
        #expect(note(project, bottom.clipID, at: 0, timeline: inner) == nil)
        project.embedTimeline(inner, intoTimeline: project.rootTimelineID)
        #expect(project.isNested(inner))
        #expect(note(project, bottom.clipID, at: 0, timeline: inner)?.dims == true)
        // The clip above it has the other layer to blend with.
        #expect(note(project, top.clipID, at: 0, timeline: inner) == nil)
    }

    @Test func passThroughCantApplyStepsThatNeedOnePicture() {
        var project = EditingProject.empty
        let inner = project.addTimeline(name: "Inner", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        project.importClip(media(), intoTimeline: inner)
        let placed = project.embedTimeline(inner, intoTimeline: project.rootTimelineID)!
        var opacity = Effect(kind: .transform, controls: [EffectControl(kind: .opacity)])
        opacity.controls[0].number = AnimatedValue(ComponentValue(values: [50]))
        var grade = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
        grade.controls[0].number = AnimatedValue(ComponentValue(values: [1]))
        project.editClip(placed.clipID, in: project.rootTimelineID) { $0.effects = [opacity, grade, scale(80)]; $0.passThrough = true }

        // Opacity is applied to each layer inside: said, not dimmed.
        #expect(note(project, placed.clipID, at: 0)?.dims == false)
        #expect(note(project, placed.clipID, at: 1)?.dims == true)
        #expect(note(project, placed.clipID, at: 2) == nil)
        // Without Pass Through, nothing to say.
        project.editClip(placed.clipID, in: project.rootTimelineID) { $0.passThrough = false }
        #expect(note(project, placed.clipID, at: 0) == nil)
        #expect(note(project, placed.clipID, at: 1) == nil)
        // A wipe and the film dissolve can't be drawn per layer.
        project.editClip(placed.clipID, in: project.rootTimelineID) { $0.passThrough = true }
        let clip = project.clipAndLayer(placed.clipID, in: project.rootTimelineID)!.clip
        #expect(project.note(for: ClipTransition(kind: .wipeLeft, duration: CMTime(value: 1, timescale: 1)), of: clip)?.dims == true)
        #expect(project.note(for: ClipTransition(kind: .filmDissolve, duration: CMTime(value: 1, timescale: 1)), of: clip)?.dims == true)
        #expect(project.note(for: ClipTransition(kind: .crossDissolve, duration: CMTime(value: 1, timescale: 1)), of: clip) == nil)
    }

    @Test func thumbnailsShowTheClipAfterEachEffect() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await fixture.addClip(luma: 200)
        var darken = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
        darken.controls[0].number = AnimatedValue(ComponentValue(values: [-3]))
        let shrink = scale(50)
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.effects = [shrink, darken] }

        let images = await EffectThumbnails.render(
            project: fixture.project, timelineID: fixture.timelineID, clipID: placed.clipID,
            at: CMTime(value: 12, timescale: 24), width: 64
        )
        let afterShrink = try #require(images[shrink.id])
        let afterDarken = try #require(images[darken.id])
        #expect(afterShrink.width == 64 && afterShrink.height == 36)

        func level(_ image: CGImage, x: Double, y: Double) throws -> Int {
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: -x * Double(image.width), y: -(1 - y) * Double(image.height), width: Double(image.width), height: Double(image.height)))
            return Int(pixel[1])
        }
        #expect(try level(afterShrink, x: 0.5, y: 0.5) > 100)
        // The shrunk picture leaves the corners bare.
        #expect(try level(afterShrink, x: 0.04, y: 0.06) < 10)
        #expect(try level(afterDarken, x: 0.5, y: 0.5) < (try level(afterShrink, x: 0.5, y: 0.5)) / 2)
    }
}
