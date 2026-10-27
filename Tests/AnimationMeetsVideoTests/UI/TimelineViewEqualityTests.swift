import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// When the editor's `.equatable()` lets `TimelineView` skip a redraw
/// (SwiftUI has a `TimelineView` too, hence the module name below).
@MainActor
struct TimelineViewEqualityTests {
    private final class Host: TimelineHost {
        func dispatch(_ action: TimelineAction) {}
        func dropScenes(_ payloads: [MediaDragPayload], onLayer: UUID?, at: CMTime, kind: LayerKind?) -> Bool { false }
        func dropFiles(_ urls: [URL], onLayer: UUID?, at: CMTime, kind: LayerKind?) {}
        func sceneTracks() -> [UUID: ChangeScoreTrack] { [:] }
        func readProject() -> EditingProject { .empty }
    }

    private let playback = PlaybackModel()
    private let playhead = PlayheadState()
    private let host = Host()
    private let effectsState = EffectsPanelState()

    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    private func view(of project: EditingProject, timelineID: UUID? = nil) throws -> AnimationMeetsVideo.TimelineView {
        let id = timelineID ?? project.rootTimelineID
        return AnimationMeetsVideo.TimelineView(
            project: project,
            timeline: try #require(project.timeline(id: id)),
            timelineID: id,
            selection: nil,
            beatTracks: [:],
            beatClicks: playback.beatClicks,
            playback: playback,
            playhead: playhead,
            host: host,
            showsEffectsLibrary: .constant(false),
            showsSidePanel: .constant(true),
            showsEffects: false,
            showsMeter: .constant(false),
            effectsState: effectsState
        )
    }

    @Test func aMovedPlayheadIsTheSameView() throws {
        let state = ProjectState(.empty)
        let before = try view(of: state.value)
        playhead.time = seconds(4)
        let after = try view(of: state.value)
        #expect(before == after)
    }

    @Test func aValueEditedInAnotherTimelineIsTheSameView() throws {
        let state = ProjectState(.empty)
        state.value.timelines.append(Timeline(
            name: "Other", layers: [TimelineLayer(kind: .sound, clips: [])],
            frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709
        ))
        let before = try view(of: state.value)
        // A keyframed value: not part of the structure this timeline draws.
        state.value.timelines[1].layers[0].volume = AnimatedValue(-6.0)
        let after = try view(of: state.value)
        #expect(before.project.editCount != after.project.editCount)
        #expect(before == after)
    }

    @Test func anotherTimelineRenamedIsANewView() throws {
        let state = ProjectState(.empty)
        state.value.timelines.append(Timeline(
            name: "Other", layers: [], frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709
        ))
        let before = try view(of: state.value)
        // Nested clips show other timelines' names, which the structure keeps.
        state.value.timelines[1].name = "Renamed"
        let after = try view(of: state.value)
        #expect(before != after)
    }

    @Test func anEditOfItsTimelineIsANewView() throws {
        let state = ProjectState(.empty)
        let before = try view(of: state.value)
        _ = state.value.addSection(in: state.value.rootTimelineID, from: .zero, to: seconds(2))
        let after = try view(of: state.value)
        #expect(before != after)
    }

    @Test func anotherHostIsANewView() throws {
        let state = ProjectState(.empty)
        let before = try view(of: state.value)
        let other = Host()
        let after = AnimationMeetsVideo.TimelineView(
            project: before.project, timeline: before.timeline, timelineID: before.timelineID, selection: nil,
            beatTracks: [:], beatClicks: playback.beatClicks, playback: playback, playhead: playhead, host: other,
            showsEffectsLibrary: .constant(false), showsSidePanel: .constant(true), showsEffects: false,
            showsMeter: .constant(false), effectsState: effectsState
        )
        #expect(before != after)
    }
}
