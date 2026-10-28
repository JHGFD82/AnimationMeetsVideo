import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// Whether a clip edit a drag lets go of was made (`TimelineView.clipEdit`),
/// which decides whether the block waits for it or springs back at once.
@MainActor
struct ClipEditResultTests {
    /// Applies moves to its project at once, as the editor's host does.
    private final class Host: TimelineHost {
        var project: EditingProject

        init(_ project: EditingProject) {
            self.project = project
        }

        func dispatch(_ action: TimelineAction) {
            if case .moveClip(let layerID, let clipID, let target, let start) = action {
                project.moveClip(clipID, in: project.rootTimelineID, layer: layerID, onto: target, to: start)
            }
        }
        func dropScenes(_ payloads: [MediaDragPayload], onLayer: UUID?, at: CMTime, kind: LayerKind?) -> Bool { false }
        func dropFiles(_ urls: [URL], onLayer: UUID?, at: CMTime, kind: LayerKind?) {}
        func sceneTracks() -> [UUID: ChangeScoreTrack] { [:] }
        func readProject() -> EditingProject { project }
    }

    private let playback = PlaybackModel()
    private let playhead = PlayheadState()
    private let effectsState = EffectsPanelState()

    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    private func setUp() throws -> (AnimationMeetsVideo.TimelineView, Host, layer: UUID, sound: UUID, clip: UUID) {
        var project = EditingProject.empty
        let media = MediaClip(name: "Shot", kind: .video, url: nil, duration: seconds(10), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        project.addMedia(media)
        let clip = TimelineClip(source: .media(media.id), startOffset: seconds(1), trimStart: .zero, trimEnd: seconds(2))
        let video = TimelineLayer(kind: .video, clips: [clip])
        let sound = TimelineLayer(kind: .sound, clips: [])
        project.timelines[0].layers = [video, sound]
        let host = Host(project)
        let view = AnimationMeetsVideo.TimelineView(
            project: project, timeline: try #require(project.timeline(id: project.rootTimelineID)),
            timelineID: project.rootTimelineID, selection: nil, beatTracks: [:], beatClicks: playback.beatClicks,
            playback: playback, playhead: playhead, host: host, showsEffectsLibrary: .constant(false),
            showsSidePanel: .constant(true), showsEffects: false, showsMeter: .constant(false), effectsState: effectsState
        )
        return (view, host, video.id, sound.id, clip.id)
    }

    @Test func aMoveThatLandsWasMade() throws {
        let (view, host, layer, _, clip) = try setUp()
        let made = view.clipEdit(clip) { host.dispatch(.moveClip(layer: layer, clip: clip, toLayer: nil, start: seconds(4))) }
        #expect(made)
        #expect(host.project.clipAndLayer(clip, in: host.project.rootTimelineID)?.clip.startOffset == seconds(4))
    }

    /// Video can't go onto a sound layer: the project refuses, the clip
    /// stays, and the block is told so.
    @Test func aRefusedMoveWasNotMade() throws {
        let (view, host, layer, sound, clip) = try setUp()
        let made = view.clipEdit(clip) { host.dispatch(.moveClip(layer: layer, clip: clip, toLayer: sound, start: seconds(4))) }
        #expect(!made)
        #expect(host.project.clipAndLayer(clip, in: host.project.rootTimelineID)?.layer.id == layer)
    }

    @Test func aMoveToWhereItIsChangesNothing() throws {
        let (view, host, layer, _, clip) = try setUp()
        let made = view.clipEdit(clip) { host.dispatch(.moveClip(layer: layer, clip: clip, toLayer: nil, start: seconds(1))) }
        #expect(!made)
    }
}
