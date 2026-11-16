import CoreMedia
import CoreGraphics
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// What the viewer's handles are drawn from: the drag under way, a drag
/// held elsewhere, or the project, and only once a picture's size is known.
@MainActor
struct ViewerHandlesOverlayTests {
    private struct Rig {
        var project: EditingProject
        let timelineID: UUID
        let clipID: UUID

        init() throws {
            var project = EditingProject.empty
            timelineID = project.rootTimelineID
            let added = project.addShapeLayer(.rectangle, to: timelineID)
            clipID = try #require(added).clipID
            self.project = project
        }

        var clip: TimelineClip? { project.clipAndLayer(clipID, in: timelineID)?.clip }

        /// The project with the clip's auto matte on, as a stand-in for
        /// any edit.
        var edited: EditingProject {
            var copy = project
            copy.editClip(clipID, in: timelineID) { $0.autoMatteEnabled = true }
            return copy
        }
    }

    @Test func withNothingHeldTheBoxIsTheProjectsClip() throws {
        let rig = try Rig()
        let clip = try #require(rig.clip)
        let drawn = ViewerHandlesOverlay.drawnClip(clip, drag: nil, held: nil, timelineID: rig.timelineID)
        #expect(drawn == clip)
    }

    @Test func aDragHeldInThePanelMovesTheBox() throws {
        let rig = try Rig()
        let clip = try #require(rig.clip)
        let drawn = ViewerHandlesOverlay.drawnClip(clip, drag: nil, held: rig.edited, timelineID: rig.timelineID)
        #expect(drawn.autoMatteEnabled)
    }

    @Test func theCanvasesOwnDragComesFirst() throws {
        let rig = try Rig()
        let clip = try #require(rig.clip)
        var dragged = clip
        dragged.startOffset = CMTime(value: 1, timescale: 1)
        let drag = ViewerCanvasState.Drag(handle: .move, clipID: clip.id, clip: dragged, readout: "", pointer: .zero, loupe: nil)
        let drawn = ViewerHandlesOverlay.drawnClip(clip, drag: drag, held: rig.edited, timelineID: rig.timelineID)
        #expect(drawn == dragged)
    }

    @Test func aPictureIsMeasuredOnceItsSizeIsReadOrCantBe() {
        let id = UUID()
        #expect(!ViewerHandlesOverlay.isMeasured(id, sizes: [:], unmeasurable: []))
        #expect(ViewerHandlesOverlay.isMeasured(id, sizes: [id: CGSize(width: 1920, height: 1080)], unmeasurable: []))
        #expect(ViewerHandlesOverlay.isMeasured(id, sizes: [:], unmeasurable: [id]))
    }
}
