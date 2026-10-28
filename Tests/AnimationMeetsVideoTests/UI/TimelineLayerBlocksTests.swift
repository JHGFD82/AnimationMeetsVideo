import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// How an area lays out its layers (`TimelineView.blocks(for:)`), which the
/// header column, the tracks and the drags all go by.
@MainActor
struct TimelineLayerBlocksTests {
    private final class Host: TimelineHost {
        let project: EditingProject

        init(_ project: EditingProject) {
            self.project = project
        }

        func dispatch(_ action: TimelineAction) {}
        func dropScenes(_ payloads: [MediaDragPayload], onLayer: UUID?, at: CMTime, kind: LayerKind?) -> Bool { false }
        func dropFiles(_ urls: [URL], onLayer: UUID?, at: CMTime, kind: LayerKind?) {}
        func sceneTracks() -> [UUID: ChangeScoreTrack] { [:] }
        func readProject() -> EditingProject { project }
    }

    private let playback = PlaybackModel()
    private let playhead = PlayheadState()
    private let effectsState = EffectsPanelState()

    private func view(of project: EditingProject) throws -> AnimationMeetsVideo.TimelineView {
        AnimationMeetsVideo.TimelineView(
            project: project, timeline: try #require(project.timeline(id: project.rootTimelineID)),
            timelineID: project.rootTimelineID, selection: nil, beatTracks: [:], beatClicks: playback.beatClicks,
            playback: playback, playhead: playhead, host: Host(project), showsEffectsLibrary: .constant(false),
            showsSidePanel: .constant(true), showsEffects: false, showsMeter: .constant(false), effectsState: effectsState
        )
    }

    /// Each layer starts where the one above it ends, and only the area's
    /// own layers are counted; an adjustment layer keeps its fixed row.
    @Test func layersStackTopToBottomWithinTheirArea() throws {
        var project = EditingProject.empty
        let top = TimelineLayer(kind: .video, clips: [])
        let sound = TimelineLayer(kind: .sound, clips: [])
        let bottom = TimelineLayer(kind: .video, clips: [])
        project.timelines[0].layers = [top, sound, bottom]
        _ = project.addAdjustmentLayer(to: project.rootTimelineID, from: .zero)
        let view = try view(of: project)
        let layout = view.shownAreaLayout

        let blocks = view.blocks(for: .video)
        #expect(blocks.count == 3)
        #expect(blocks.map(\.index) == [0, 1, 2])
        #expect(blocks[0].layer.isAdjustment)
        #expect(blocks[0].clipRowHeight == AnimationMeetsVideo.TimelineView.adjustmentRowHeight)
        #expect(blocks.map(\.id).suffix(2) == [top.id, bottom.id])
        #expect(blocks[1].clipRowHeight == layout.height(of: top.id, kind: .video))
        #expect(blocks[0].top == 0)
        for (above, below) in zip(blocks, blocks.dropFirst()) {
            #expect(below.top == above.bottom)
            #expect(above.height == above.clipRowHeight + view.separatorHeight)
        }

        let sounds = view.blocks(for: .sound)
        #expect(sounds.map(\.id) == [sound.id])
        #expect(sounds[0].top == 0)
        #expect(sounds[0].height == layout.height(of: sound.id, kind: .sound) + view.separatorHeight)
    }
}
