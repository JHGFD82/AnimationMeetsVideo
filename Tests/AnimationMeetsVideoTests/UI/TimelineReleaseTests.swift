import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// A timeline, and the editor surface around it, let go of what they hold
/// once their window closes. Closures they hand to objects in their own
/// state hold them in turn (the timeline's auto-scroll, the surface's
/// timeline host and graph panels), and kept would keep them alive, with
/// their project.
@MainActor
@Suite(.serialized) struct TimelineReleaseTests {
    private final class Host: TimelineHost {
        func dispatch(_ action: TimelineAction) {}
        func dropScenes(_ payloads: [MediaDragPayload], onLayer: UUID?, at: CMTime, kind: LayerKind?) -> Bool { false }
        func dropFiles(_ urls: [URL], onLayer: UUID?, at: CMTime, kind: LayerKind?) {}
        func sceneTracks() -> [UUID: ChangeScoreTrack] { [:] }
        func readProject() -> EditingProject { .empty }
    }

    /// The surface as the editor has it, with the objects the editor puts
    /// in its environment.
    private struct Surface: View {
        @Bindable var state: ProjectState
        let playback: PlaybackModel
        @State private var renderer = RenderScheduler()
        @State private var imports = MediaImports()
        @State private var beatMatch = BeatMatchController()
        @State private var motionDesign = MotionDesignController()
        @State private var skim = BrowserSkim()
        @State private var sceneSplitter = SceneSplitter()
        @State private var usesFinder = UsesFinder()

        var body: some View {
            TimelineEditorSurface(
                project: $state.value, timelineID: state.value.rootTimelineID, selection: .constant(nil),
                playback: playback, analysis: AssetAnalysis()
            )
            .environment(state)
            .environment(renderer).environment(imports).environment(beatMatch).environment(motionDesign)
            .environment(skim).environment(sceneSplitter).environment(usesFinder)
        }
    }

    @Test func aClosedTimelineLetsGoOfItsHost() async {
        weak var released: Host?
        do {
            let host = Host()
            released = host
            let project = ProjectState(.empty).value
            let playback = PlaybackModel()
            await showAndClose(AnimationMeetsVideo.TimelineView(
                project: project, timeline: project.timelines[0], timelineID: project.rootTimelineID, selection: nil,
                beatTracks: [:], beatClicks: playback.beatClicks, playback: playback, playhead: PlayheadState(), host: host,
                showsEffectsLibrary: .constant(false), showsSidePanel: .constant(false), showsEffects: false,
                showsMeter: .constant(false), effectsState: EffectsPanelState()
            ))
            #expect(released != nil)
        }
        await settle(seconds: 0.5)
        #expect(released == nil)
    }

    @Test func aClosedSurfaceLetsGoOfItsProject() async {
        weak var released: ProjectState?
        do {
            let state = ProjectState(.empty)
            released = state
            await showAndClose(Surface(state: state, playback: PlaybackModel()))
        }
        await settle(seconds: 0.5)
        #expect(released == nil)
    }

    /// Shows `content` in a window for a moment, then closes the window.
    private func showAndClose(_ content: some View) async {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let view = NSHostingView(rootView: content.frame(width: bounds.width, height: bounds.height))
        view.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        NSApplication.shared.setActivationPolicy(.accessory)
        window.makeKeyAndOrderFront(nil)
        await settle(seconds: 1)
        window.contentView = nil
        window.close()
        await settle(seconds: 1)
    }

    private func settle(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            try? await Task.sleep(for: .milliseconds(10))
            autoreleasepool { RunLoop.main.run(until: Date()) }
        } while Date() < end
    }
}
