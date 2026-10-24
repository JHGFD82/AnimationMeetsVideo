import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct PasteSourcesTests {
    private static func media(_ name: String) -> MediaClip {
        MediaClip(
            name: name, kind: .video, url: URL(fileURLWithPath: "/Footage/\(name).mov"),
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
    }

    @Test func aClipPastedIntoAnotherProjectBringsItsMedia() throws {
        var source = EditingProject.empty
        let placed = source.importClip(Self.media("Interview"), intoTimeline: source.rootTimelineID)
        let clipID = try #require(placed).clipID
        let bundle = try #require(source.clipBundle(clipID, in: source.rootTimelineID))

        var target = EditingProject.empty
        #expect(target.canPaste(bundle, into: target.rootTimelineID))
        let pasted = target.paste(bundle, in: target.rootTimelineID, onto: nil, at: .zero)
        #expect(pasted != nil)
        #expect(target.clips.map(\.name) == ["Interview"])
        #expect(target.clips.first?.id == source.clips.first?.id)
    }

    @Test func aNestedTimelineComesWithWhatItPlays() throws {
        var source = EditingProject.empty
        let nested = source.addTimeline(name: "Chorus", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        _ = source.importClip(Self.media("Take 1"), intoTimeline: nested)
        let embedded = source.embedTimeline(nested, intoTimeline: source.rootTimelineID)
        let clipID = try #require(embedded).clipID
        let bundle = try #require(source.clipBundle(clipID, in: source.rootTimelineID))

        var target = EditingProject.empty
        #expect(target.canPaste(bundle, into: target.rootTimelineID))
        let pasted = target.paste(bundle, in: target.rootTimelineID, onto: nil, at: .zero)
        #expect(pasted != nil)
        #expect(target.timeline(id: nested)?.name == "Chorus")
        #expect(target.clips.map(\.name) == ["Take 1"])
    }

    @Test func pastingInTheSameProjectAddsNothing() throws {
        var project = EditingProject.empty
        let placed = project.importClip(Self.media("Interview"), intoTimeline: project.rootTimelineID)
        let clipID = try #require(placed).clipID
        let bundle = try #require(project.clipBundle(clipID, in: project.rootTimelineID))
        let pasted = project.paste(bundle, in: project.rootTimelineID, onto: nil, at: .zero)
        #expect(pasted != nil)
        #expect(project.clips.count == 1)
        #expect(project.timelines.count == 1)
    }
}
