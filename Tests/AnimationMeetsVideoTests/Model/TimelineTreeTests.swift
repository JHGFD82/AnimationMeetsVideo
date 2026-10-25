import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct TimelineTreeTests {
    private static func media() -> MediaClip {
        MediaClip(
            name: "Clip", kind: .video, url: nil,
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
    }

    private static func addTimeline(_ name: String, to project: inout EditingProject) -> UUID {
        project.addTimeline(name: name, frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
    }

    /// Main embeds Scene, which embeds Detail; Loose is embedded nowhere.
    @Test func listsEachTimelineUnderTheOnesEmbeddingIt() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let scene = Self.addTimeline("Scene", to: &project)
        let detail = Self.addTimeline("Detail", to: &project)
        let loose = Self.addTimeline("Loose", to: &project)
        _ = project.importClip(Self.media(), intoTimeline: detail)
        _ = project.importClip(Self.media(), intoTimeline: scene)
        let detailEmbedded = project.embedTimeline(detail, intoTimeline: scene)
        let sceneEmbedded = project.embedTimeline(scene, intoTimeline: main)
        #expect(detailEmbedded != nil)
        #expect(sceneEmbedded != nil)

        #expect(project.topLevelTimelines == [main, loose])
        #expect(project.embeddedTimelines(in: main) == [scene])
        #expect(project.embeddedTimelines(in: scene) == [detail])

        let nodes = TimelinesList.nodes(of: project)
        try #require(nodes.map(\.timelineID) == [main, loose])
        let sceneNode = try #require(nodes[0].children?.first)
        #expect(sceneNode.timelineID == scene)
        #expect(sceneNode.children?.map(\.timelineID) == [detail])
        #expect(nodes[1].children == nil)
    }

    /// Detail is embedded in both Main and Scene, which Main embeds too: it
    /// is listed once, under Main, the shallower of the two.
    @Test func listsATimelineEmbeddedTwiceOnce() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let scene = Self.addTimeline("Scene", to: &project)
        let detail = Self.addTimeline("Detail", to: &project)
        _ = project.importClip(Self.media(), intoTimeline: detail)
        _ = project.importClip(Self.media(), intoTimeline: scene)
        _ = project.embedTimeline(detail, intoTimeline: main)
        _ = project.embedTimeline(detail, intoTimeline: scene)
        _ = project.embedTimeline(scene, intoTimeline: main)

        func all(_ nodes: [TimelinesList.Node]) -> [UUID] {
            nodes.flatMap { [$0.timelineID] + all($0.children ?? []) }
        }
        let nodes = TimelinesList.nodes(of: project)
        #expect(all(nodes).sorted { $0.uuidString < $1.uuidString } == [main, scene, detail].sorted { $0.uuidString < $1.uuidString })
        #expect(Set(nodes.first?.children?.map(\.timelineID) ?? []) == [detail, scene])
        let sceneNode = nodes.first?.children?.first { $0.timelineID == scene }
        #expect(sceneNode?.children == nil)
    }

    /// The tab lists the tree as flat rows, each at its depth, so nested
    /// rows take clicks as top-level ones do; a collapsed row hides all
    /// that is under it.
    @Test func theTreeIsListedAsRowsAtTheirDepth() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let scene = Self.addTimeline("Scene", to: &project)
        let detail = Self.addTimeline("Detail", to: &project)
        let loose = Self.addTimeline("Loose", to: &project)
        _ = project.importClip(Self.media(), intoTimeline: detail)
        _ = project.importClip(Self.media(), intoTimeline: scene)
        _ = project.embedTimeline(detail, intoTimeline: scene)
        _ = project.embedTimeline(scene, intoTimeline: main)
        let nodes = TimelinesList.nodes(of: project)

        let open = TimelinesList.rows(of: nodes, collapsed: [])
        #expect(open.map(\.timelineID) == [main, scene, detail, loose])
        #expect(open.map(\.depth) == [0, 1, 2, 0])
        #expect(open.map(\.hasChildren) == [true, true, false, false])

        #expect(TimelinesList.rows(of: nodes, collapsed: [scene]).map(\.timelineID) == [main, scene, loose])
        #expect(TimelinesList.rows(of: nodes, collapsed: [main]).map(\.timelineID) == [main, loose])
    }

    /// Embedding a range plays only it, the rest kept past the clip's trims;
    /// the browser underlines what is embedded, and a timeline is drawn
    /// from those it nests and those its effects take.
    @Test func embeddingARangeAndWhatATimelineIsDrawnFrom() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        let scene = Self.addTimeline("Scene", to: &project)
        let detail = Self.addTimeline("Detail", to: &project)
        let loose = Self.addTimeline("Loose", to: &project)
        _ = project.importClip(Self.media(), intoTimeline: scene)
        _ = project.importClip(Self.media(), intoTimeline: detail)
        _ = project.importClip(Self.media(), intoTimeline: loose)

        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 2, timescale: 1))
        let embedded = project.embedTimeline(scene, intoTimeline: main, range: range)
        let placed = try #require(embedded)
        let clip = try #require(project.clipAndLayer(placed.clipID, in: main)?.clip)
        #expect(clip.trimStart == range.start && clip.trimEnd == range.end && clip.startOffset == .zero)
        #expect(project.usedRanges(ofTimeline: scene) == [range])
        #expect(project.usedRanges(ofTimeline: loose).isEmpty)
        // A range wholly past the end embeds nothing.
        let past = project.embedTimeline(scene, intoTimeline: main, range: CMTimeRange(start: CMTime(value: 9, timescale: 1), duration: CMTime(value: 1, timescale: 1)))
        #expect(past == nil)

        var input = Effect(kind: .matte)
        input.input = EffectInput(source: .timeline(detail))
        project.editClip(placed.clipID, in: main) { $0.effects = [input] }
        #expect(project.timelinesDrawn(from: main) == [main, scene, detail])
        #expect(project.timelinesDrawn(from: scene) == [scene])
    }

    @Test func aDuplicateHasNewIDsAndItsOwnName() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        _ = project.importClip(Self.media(), intoTimeline: main)
        let added = project.addAdjustmentLayer(to: main)
        let adjustment = try #require(added)
        let original = try #require(project.timeline(id: main))
        let below = try #require(original.layers.last?.id)
        project.updateLayer(adjustment.layerID, in: main) { $0.clips[0].reach = below }

        let duplicated = project.duplicateTimeline(main)
        let copyID = try #require(duplicated)
        let copy = try #require(project.timeline(id: copyID))
        #expect(copy.name == "\(original.name) copy")
        #expect(project.timelines.firstIndex(id: copyID) == 1)
        #expect(Set(copy.layers.map(\.id)).isDisjoint(with: original.layers.map(\.id)))
        let originalClips = Set(original.layers.flatMap(\.clips).map(\.id))
        #expect(Set(copy.layers.flatMap(\.clips).map(\.id)).isDisjoint(with: originalClips))
        // The copy's adjustment clip reaches the copy of the layer, not the original.
        #expect(copy.layers[0].clips[0].reach == copy.layers.last?.id)

        let duplicatedAgain = project.duplicateTimeline(main)
        let again = try #require(duplicatedAgain)
        #expect(project.timeline(id: again)?.name == "\(original.name) copy 2")
    }
}
