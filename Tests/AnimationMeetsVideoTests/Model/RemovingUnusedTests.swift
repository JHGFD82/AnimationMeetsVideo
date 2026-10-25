import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct RemovingUnusedTests {
    private static func media(_ name: String = "Clip") -> MediaClip {
        MediaClip(
            name: name, kind: .video, url: nil,
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
    }

    private static func addTimeline(_ name: String, to project: inout EditingProject) -> UUID {
        project.addTimeline(name: name, frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
    }

    /// Only media no timeline uses goes: one on a timeline, or an effect's
    /// input, stays.
    @Test func removesOnlyUnusedMedia() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let placed = Self.media("Placed"), matte = Self.media("Matte"), loose = Self.media("Loose")
        let added = project.importClip(placed, intoTimeline: main)
        let clipID = try #require(added).clipID
        project.addMedia(matte)
        project.addMedia(loose)
        var effect = Effect(kind: .matte)
        effect.input = EffectInput(source: .asset(matte.id))
        project.editClip(clipID, in: main) { $0.effects = [effect] }

        #expect(project.isUsed(media: placed.id))
        #expect(project.isUsed(media: matte.id))
        #expect(!project.isUsed(media: loose.id))

        let removed = project.removeUnusedMedia([placed.id, matte.id, loose.id])
        #expect(removed == [loose.id])
        #expect(project.clips.map(\.id) == [placed.id, matte.id])
    }

    /// The main timeline and one another embeds or takes as an input stay;
    /// a loose one goes, and the one it alone embedded is then free.
    @Test func deletesOnlyUnusedTimelines() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let scene = Self.addTimeline("Scene", to: &project)
        let input = Self.addTimeline("Input", to: &project)
        let loose = Self.addTimeline("Loose", to: &project)
        let inner = Self.addTimeline("Inner", to: &project)
        _ = project.importClip(Self.media(), intoTimeline: scene)
        _ = project.importClip(Self.media(), intoTimeline: input)
        _ = project.importClip(Self.media(), intoTimeline: inner)
        let placed = project.embedTimeline(scene, intoTimeline: main)
        let embedded = try #require(placed)
        let nested = project.embedTimeline(inner, intoTimeline: loose)
        #expect(nested != nil)
        var effect = Effect(kind: .matte)
        effect.input = EffectInput(source: .timeline(input))
        project.editClip(embedded.clipID, in: main) { $0.effects = [effect] }

        #expect(!project.canDeleteTimeline(main))
        #expect(!project.canDeleteTimeline(scene))
        #expect(!project.canDeleteTimeline(input))
        #expect(!project.canDeleteTimeline(inner))
        #expect(project.canDeleteTimeline(loose))

        let deleted = project.deleteUnusedTimelines([main, scene, input, loose, inner])
        #expect(deleted == [loose])
        #expect(project.timeline(id: loose) == nil)
        #expect(project.canDeleteTimeline(inner))
    }
}
