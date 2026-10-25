import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite struct UsesFinderTests {
    private static func s(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private static func media(_ name: String) -> MediaClip {
        MediaClip(name: name, kind: .video, url: nil, duration: s(5), frameRate: 24, colorSpace: .rec709, codecName: "Stub")
    }

    /// Main holds two clips of Shot, and Titles a clip whose matte takes it
    /// as its input.
    private static func project() throws -> (EditingProject, MediaClip) {
        var project = EditingProject.empty
        let shot = media("Shot")
        _ = project.importClip(shot, intoTimeline: project.rootTimelineID)
        _ = project.addPieces([MediaPiece(assetID: shot.id, start: .zero, end: s(2))], intoTimeline: project.rootTimelineID, at: s(7))
        let titles = project.addTimeline(name: "Titles", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        let imported = project.importClip(media("Card"), intoTimeline: titles)
        let placed = try #require(imported)
        var matte = Effect(kind: .matte)
        matte.input = EffectInput(source: .asset(shot.id))
        project.editClip(placed.clipID, in: titles) { $0.effects = [matte] }
        return (project, shot)
    }

    /// The question says how many uses, where, and what goes with them.
    @Test func theQuestionCountsTheUses() throws {
        let (project, shot) = try Self.project()
        let uses = project.uses(of: .media(shot.id))
        let request = RemovalRequest(
            removing: [shot.name], noun: "clip", action: "Remove", uses: uses, in: project, queries: [], perform: {}
        )
        #expect(request.title == "Remove “Shot” from the project?")
        #expect(request.message == "It is used 3 times, in Main and Titles. Removing it also deletes those 2 clips and "
            + "takes it off the effect using it as an input. You can undo this.")
        let two = RemovalRequest(
            removing: ["A", "B"], noun: "timeline", action: "Delete", uses: Array(uses.prefix(1)), in: project, queries: [], perform: {}
        )
        #expect(two.title == "Delete 2 timelines?")
        #expect(two.message == "They are used once, in Main. Deleting them also deletes that clip. You can undo this.")
    }

    /// Each use is a row with its timeline, layer, place and how it is
    /// used, and rows go when what they use goes.
    @Test func rowsFollowTheProject() throws {
        var (project, shot) = try Self.project()
        let finder = UsesFinder()
        finder.update(project: project)
        finder.showWithoutPanel([UsesFinder.Query(item: .media(shot.id), range: nil, name: shot.name)])
        #expect(finder.title == "Uses of Shot")
        let rows = finder.rows
        #expect(rows.map(\.timelineName) == ["Main", "Main", "Titles"])
        // Top layer first: the piece added later went on a new one.
        #expect(rows.map(\.layerName) == ["Video 1", "Video 2", "Video 1"])
        #expect(rows.map(\.effectName) == [nil, nil, "Matte"])
        #expect(rows.first?.start == Self.s(7).compactTimecode(frameRate: 24))
        #expect(rows.first?.end == Self.s(9).compactTimecode(frameRate: 24))
        #expect(rows.first?.duration == Self.s(2).compactTimecode(frameRate: 24))
        #expect(UsesFinderView.summary(rows) == "3 uses in 2 timelines")

        project.removeMedia([shot.id])
        finder.update(project: project)
        #expect(finder.queries.isEmpty)
        #expect(finder.rows.isEmpty)
    }
}
