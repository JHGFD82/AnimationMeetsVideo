import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// `EditingProject.structure` decides when the browser and the timeline's
/// other layers can skip redrawing, so it must change exactly when what
/// they draw or act on does.
@Suite struct ProjectStructureTests {
    private func project() throws -> (EditingProject, shape: UUID, footage: UUID) {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(
            name: "Footage", kind: .video, url: URL(fileURLWithPath: "/dev/null"),
            duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let imported = project.importClip(media, intoTimeline: t)
        let footage = try #require(imported)
        let added = project.addShapeLayer(.rectangle, to: t)
        let shape = try #require(added)
        return (project, shape.clipID, footage.clipID)
    }

    @Test func draggingAValueLeavesTheStructureAlone() throws {
        var (edited, shape, footage) = try project()
        let before = edited.structure
        let t = edited.rootTimelineID
        edited.editClip(shape, in: t) { clip in
            clip.effects[0].controls[0].number = AnimatedValue(ComponentValue(values: [123, 45]))
        }
        edited.editClip(footage, in: t) { clip in
            clip.anchorPoint = AnimatedValue(Vector2(x: 10, y: 20))
            clip.volume = AnimatedValue(-6)
            clip.pan = AnimatedValue(30)
        }
        #expect(edited.structure == before)
    }

    @Test func whatTheRowsActOnChangesTheStructure() throws {
        let (original, shape, footage) = try project()
        let t = original.rootTimelineID
        let before = original.structure

        var moved = original
        moved.editClip(footage, in: t) { $0.startOffset = CMTime(seconds: 2, preferredTimescale: 600) }
        #expect(moved.structure != before)

        var trimmed = original
        trimmed.editClip(footage, in: t) { $0.trimEnd = CMTime(seconds: 4, preferredTimescale: 600) }
        #expect(trimmed.structure != before)

        var added = original
        _ = added.addEffect(.color, toClip: shape, in: t)
        #expect(added.structure != before)

        // A Matte's input decides what a timeline can be nested in.
        var input = original
        _ = input.addEffect(.matte, toClip: footage, in: t)
        let withMatte = input.structure
        let nested = input.addTimeline(name: "Inner", frameSize: CGSize(width: 64, height: 36), frameRate: 24, colorSpace: .rec709)
        input.editClip(footage, in: t) { clip in
            if let index = clip.effects.firstIndex(where: { $0.kind == .matte }) {
                clip.effects[index].input = EffectInput(source: .timeline(nested))
            }
        }
        #expect(input.structure != withMatte)

        var media = original
        media.addMedia(MediaClip(
            name: "More", kind: .audio, url: nil, duration: CMTime(seconds: 1, preferredTimescale: 600),
            frameRate: 0, colorSpace: .rec709, codecName: "AAC"
        ))
        #expect(media.structure != before)
    }

    @Test func theBrowserComparesWhatItShows() throws {
        let (project, shape, _) = try project()
        let t = project.rootTimelineID
        let shown = BrowserPanel.Shown(structure: project.structure, activeTimelineID: t, selection: nil)
        var dragged = project
        dragged.editClip(shape, in: t) { $0.effects[0].controls[0].number = AnimatedValue(ComponentValue(values: [1, 2])) }
        #expect(BrowserPanel.Shown(structure: dragged.structure, activeTimelineID: t, selection: nil) == shown)
        let selected = TimelineSelection(timelineID: t, layerID: UUID(), timelineClipID: shape)
        #expect(BrowserPanel.Shown(structure: project.structure, activeTimelineID: t, selection: selected) != shown)
    }
}
