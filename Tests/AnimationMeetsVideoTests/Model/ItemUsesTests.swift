import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ItemUsesTests {
    private static func s(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private static func media(_ name: String = "Clip") -> MediaClip {
        MediaClip(
            name: name, kind: .video, url: nil, duration: s(5),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
    }

    private static func addTimeline(_ name: String, to project: inout EditingProject) -> UUID {
        project.addTimeline(name: name, frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
    }

    /// A clip of the asset and an effect taking it as its input each count,
    /// with the clip's place on its timeline; a range counts only what
    /// plays some of it.
    @Test func findsEveryUseOfAnAsset() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let shot = Self.media("Shot"), matte = Self.media("Matte")
        project.addMedia(matte)
        let placed = project.importClip(shot, intoTimeline: main)
        let clipID = try #require(placed).clipID
        var effect = Effect(kind: .matte)
        effect.input = EffectInput(source: .asset(matte.id), offset: Self.s(3))
        project.editClip(clipID, in: main) { $0.effects = [effect] }

        let ofShot = project.uses(of: .media(shot.id))
        #expect(ofShot.count == 1)
        #expect(ofShot.first?.timelineID == main && ofShot.first?.clipID == clipID && ofShot.first?.isEffectInput == false)
        #expect(ofShot.first?.start == .zero && ofShot.first?.duration.seconds == 5)

        let ofMatte = project.uses(of: .media(matte.id))
        #expect(ofMatte.map(\.effectID) == [effect.id])
        // The matte plays from 3 s, so a range before that holds no use.
        #expect(project.uses(of: .media(matte.id), within: CMTimeRange(start: .zero, end: Self.s(2))).isEmpty)
        #expect(project.uses(of: .media(matte.id), within: CMTimeRange(start: Self.s(4), end: Self.s(5))).count == 1)
    }

    /// Removing an asset deletes its clips (their layer stays) and takes it
    /// off the effects using it; other media stays.
    @Test func removingMediaTakesItsUsesWithIt() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let shot = Self.media("Shot"), matte = Self.media("Matte"), other = Self.media("Other")
        project.addMedia(matte)
        let placedShot = project.importClip(shot, intoTimeline: main)
        let placedOther = project.importClip(other, intoTimeline: main)
        let shotLayer = try #require(placedShot).layerID
        let otherClip = try #require(placedOther).clipID
        var effect = Effect(kind: .matte)
        effect.input = EffectInput(source: .asset(matte.id))
        project.editClip(otherClip, in: main) { $0.effects = [effect] }

        let removed = project.removeMedia([shot.id, matte.id])
        #expect(Set(removed) == [shot.id, matte.id])
        #expect(project.clips.map(\.id) == [other.id])
        #expect(project.timeline(id: main)?.layer(id: shotLayer)?.clips.isEmpty == true)
        let kept = try #require(project.clipAndLayer(otherClip, in: main)?.clip)
        #expect(kept.effects.first?.input == nil)
        #expect(!project.isUsed(.media(matte.id)))
    }

    /// Any timeline but the main one can go, and the clips embedding it and
    /// inputs taking it go with it; what it embedded stays.
    @Test func deletingATimelineTakesItsUsesWithIt() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let scene = Self.addTimeline("Scene", to: &project)
        let inner = Self.addTimeline("Inner", to: &project)
        let input = Self.addTimeline("Input", to: &project)
        _ = project.importClip(Self.media(), intoTimeline: inner)
        _ = project.importClip(Self.media(), intoTimeline: input)
        let nested = project.embedTimeline(inner, intoTimeline: scene)
        let embedded = project.embedTimeline(scene, intoTimeline: main)
        let host = try #require(embedded)
        #expect(nested != nil)
        var effect = Effect(kind: .matte)
        effect.input = EffectInput(source: .timeline(input))
        project.editClip(host.clipID, in: main) { $0.effects = [effect] }
        #expect(project.uses(of: .timeline(scene)).count == 1)
        #expect(project.uses(of: .timeline(input)).map(\.effectID) == [effect.id])

        #expect(!project.canDeleteTimeline(main))
        let deleted = project.deleteTimelines([main, scene, input])
        #expect(Set(deleted) == [scene, input])
        #expect(project.timeline(id: main)?.layers.allSatisfy(\.clips.isEmpty) == true)
        #expect(project.timeline(id: inner) != nil)
        #expect(project.timelines.map(\.id) == [main, inner])
    }
}
