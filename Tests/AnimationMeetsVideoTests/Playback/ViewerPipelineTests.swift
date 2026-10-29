import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The viewer's build and swap logic (`ViewerPipeline`), driven with a fake
/// player, renderer and builder: no view, player item or composition is made.
@MainActor @Suite struct ViewerPipelineTests {
    /// Holds what waits on it until opened, or until `release` lets one
    /// waiter through.
    @MainActor final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var isOpen = false
        var waiters: Int { waiting.count }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func releaseOne() {
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume()
        }

        func open() {
            isOpen = true
            let all = waiting
            waiting = []
            all.forEach { $0.resume() }
        }
    }

    final class FakePlayer: ViewerPlayer {
        var isPlaying = false
        var resumeTime: CMTime = .zero
        var shownValues = 0
        var storedValues = 0
        var unrendered = 0
        var cleared = 0
        /// The keys swapped in, in order, once each swap's frame showed.
        var swapped: [StructureKey] = []
        var swapsStarted = 0
        /// Each swap waits here: the new item's frame being ready.
        let readiness = Gate()

        init() { readiness.open() }

        func showValues(_ clips: [UUID: TimelineClip]) { shownValues += 1 }
        func storeValues(_ clips: [UUID: TimelineClip]) { storedValues += 1 }
        func playWithoutRenders() -> Bool {
            unrendered += 1
            return true
        }
        func swap(to composed: ComposedTimeline, key: StructureKey, frameRate: Double, at time: CMTime) async -> Bool {
            swapsStarted += 1
            await readiness.wait()
            swapped.append(key)
            return true
        }
        func clearItem() { cleared += 1 }
    }

    final class FakeRenderer: ViewerRenderer {
        var cache: RenderCache? { nil }
        var updates = 0
        var interacting: [Bool] = []
        var isInteracting: Bool { interacting.last ?? false }
        func update(project: EditingProject, timelineID: UUID, segments: [RenderSegment]) { updates += 1 }
        func setInteracting(_ interacting: Bool) { self.interacting.append(interacting) }
        func setPlaying(_ playing: Bool) {}
        func noteActivity() {}
    }

    /// A builder whose builds wait at `gate`, recording what each was of.
    @MainActor final class FakeBuilder {
        let gate = Gate()
        var built: [ViewerSource] = []
        var started: [ViewerSource] = []

        var build: ViewerPipeline.Builder {
            { [self] source, _ in
                started.append(source)
                await gate.wait()
                try Task.checkCancellation()
                built.append(source)
                return ComposedTimeline(composition: AVMutableComposition(), videoComposition: nil)
            }
        }
    }

    @MainActor struct Harness {
        let player = FakePlayer()
        let renderer = FakeRenderer()
        let builder = FakeBuilder()
        let pipeline: ViewerPipeline
        var project: EditingProject
        let timelineID: UUID
        let clipID: UUID

        init(coalescing: Duration = .zero, planDelay: Duration = .milliseconds(20), clock: any Clock<Duration> = ContinuousClock()) {
            var project = EditingProject.empty
            let media = MediaClip(
                name: "m", kind: .video, url: URL(fileURLWithPath: "/tmp/none.mov"), duration: CMTime(value: 4, timescale: 1),
                frameRate: 24, colorSpace: .rec709, codecName: "H.264"
            )
            clipID = project.importClip(media, intoTimeline: project.rootTimelineID)!.clipID
            timelineID = project.rootTimelineID
            self.project = project
            pipeline = ViewerPipeline(
                player: player, renderer: renderer, coalescing: coalescing, planDelay: planDelay, clock: clock,
                build: builder.build
            )
        }

        func source(_ project: EditingProject? = nil) -> ViewerSource {
            let project = project ?? self.project
            return ViewerSource(project: project, renderProject: project, timelineID: timelineID)
        }

        /// Moves the clip, a change of structure.
        mutating func move(to seconds: Double) {
            project.editClip(clipID, in: timelineID) { $0.startOffset = CMTime(seconds: seconds, preferredTimescale: 600) }
        }

        /// Changes the clip's anchor point, a change of values alone.
        mutating func nudge(_ x: Double) {
            project.editClip(clipID, in: timelineID) { $0.anchorPoint = AnimatedValue(Vector2(x: x, y: 0)) }
        }

        var key: StructureKey { StructureKey(project: project) }
    }

    /// Waits until `condition` holds, for at most two seconds.
    private func eventually(_ what: String = "", _ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting: \(what)")
    }

    /// Lets the pipeline handle every event sent, then do whatever it
    /// would do next.
    private func settle(_ h: Harness) async throws {
        try await eventually("events handled") { h.pipeline.eventsHandled == h.pipeline.eventsSent }
        try await Task.sleep(for: .milliseconds(40))
    }

    @Test func aBurstOfStructuralEditsBuildsTheFirstAndTheLast() async throws {
        var h = Harness()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.builder.gate.waiters == 1 }
        h.builder.gate.open()
        try await eventually { h.player.swapped.count == 1 }
        let before = h.pipeline.buildsStarted

        h.builder.gate.isOpen = false
        for step in 1...10 {
            h.move(to: Double(step) / 10)
            h.pipeline.show(h.source())
        }
        // The first edit's build has started; the rest arrive while it runs.
        try await eventually { h.builder.gate.waiters == 1 && h.pipeline.eventsHandled == h.pipeline.eventsSent }
        h.builder.gate.open()
        try await eventually { h.player.swapped.count == 2 }
        try await settle(h)
        #expect(h.pipeline.buildsStarted - before <= 2)
        #expect(h.player.swapped.last == h.key)
        #expect(h.player.swapped.count == 2)
        #expect(h.pipeline.phase == .ready)
    }

    @Test func aBurstWithinTheCoalescingPauseBuildsOnce() async throws {
        var h = Harness(coalescing: .milliseconds(60))
        h.builder.gate.open()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.player.swapped.count == 1 }
        for step in 1...10 {
            h.move(to: Double(step) / 10)
            h.pipeline.show(h.source())
        }
        try await eventually { h.player.swapped.count == 2 }
        try await settle(h)
        #expect(h.pipeline.buildsStarted == 2)
        #expect(h.player.swapped.last == h.key)
    }

    @Test func aStaleResultIsDropped() async throws {
        var h = Harness()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.builder.gate.waiters == 1 }
        let first = h.key
        h.move(to: 1)
        h.pipeline.show(h.source())
        try await settle(h)
        // The first build goes on: it isn't cancelled by the edit.
        #expect(h.builder.gate.waiters == 1)
        h.builder.gate.releaseOne()
        try await eventually { h.builder.started.count == 2 }
        #expect(h.player.swapsStarted == 0)
        h.builder.gate.open()
        try await eventually { h.player.swapped.count == 1 }
        try await settle(h)
        #expect(h.player.swapped == [h.key])
        #expect(!h.player.swapped.contains(first))
    }

    @Test func valueEditsDrawWithoutSwapping() async throws {
        // The plan delay is waited on a clock that moves only when told, so
        // the edits are a burst however slowly the machine runs them.
        let clock = ManualClock()
        var h = Harness(planDelay: .milliseconds(500), clock: clock)
        h.builder.gate.open()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.player.swapped.count == 1 }
        let builds = h.pipeline.buildsStarted
        for step in 1...20 {
            h.nudge(Double(step))
            h.pipeline.show(h.source())
        }
        try await eventually { h.player.shownValues == 20 }
        try await settle(h)
        // The edits are drawn as they come, and none builds.
        #expect(h.pipeline.buildsStarted == builds)
        clock.advance(by: .milliseconds(499))
        try await settle(h)
        #expect(h.pipeline.buildsStarted == builds)
        // The renderer's plan is made again once they pause; nothing swaps.
        clock.advance(by: .milliseconds(1))
        try await eventually { h.pipeline.buildsStarted == builds + 1 && h.renderer.updates == 2 }
        try await settle(h)
        #expect(h.pipeline.buildsStarted == builds + 1)
        #expect(h.player.swapsStarted == 1)
        #expect(h.renderer.updates == 2)
    }

    @Test func aRenderFinishingDuringABuildIsBuiltNext() async throws {
        let h = Harness()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.builder.gate.waiters == 1 }
        h.pipeline.send(.renderFinished)
        try await settle(h)
        h.builder.gate.open()
        // The first is current and shown; the render's build follows.
        try await eventually { h.player.swapped.count == 2 }
        try await settle(h)
        #expect(h.pipeline.buildsStarted == 2)
        #expect(h.player.swapped.count == 2)
    }

    @Test func aRenderFinishingWhilePlayingWaitsForAPause() async throws {
        let h = Harness()
        h.builder.gate.open()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.player.swapped.count == 1 }
        h.player.isPlaying = true
        h.pipeline.send(.playbackStateChanged(isPlaying: true))
        h.pipeline.send(.renderFinished)
        try await settle(h)
        #expect(h.pipeline.buildsStarted == 1)
        h.player.isPlaying = false
        h.pipeline.send(.playbackStateChanged(isPlaying: false))
        try await eventually { h.player.swapped.count == 2 }
    }

    @Test func nothingSwapsDuringAGestureAndTheRendererWaitsForWhatFollows() async throws {
        var h = Harness()
        h.builder.gate.open()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.player.swapped.count == 1 }

        h.pipeline.send(.gestureBegan)
        try await eventually { h.renderer.isInteracting }
        // A stretch from a render gives way to its clips at the start.
        #expect(h.player.unrendered == 1)
        h.builder.gate.isOpen = false
        h.move(to: 2)
        h.pipeline.show(h.source())
        try await eventually { h.builder.gate.waiters == 1 }
        // The gesture ends with the build still under way.
        h.pipeline.send(.gestureEnded)
        try await settle(h)
        #expect(h.renderer.isInteracting)
        h.player.readiness.isOpen = false
        h.builder.gate.open()
        try await eventually { h.player.swapsStarted == 2 }
        // Still waiting for the new item's frame: the renderer waits too.
        #expect(h.renderer.isInteracting)
        h.player.readiness.open()
        try await eventually { h.player.swapped.count == 2 }
        try await eventually { !h.renderer.isInteracting }
        #expect(h.player.swapped.last == h.key)
    }

    @Test func aBuildFinishedDuringAGestureSwapsWhenItEnds() async throws {
        var h = Harness()
        h.builder.gate.open()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.player.swapped.count == 1 }
        h.pipeline.send(.gestureBegan)
        h.move(to: 2)
        h.pipeline.show(h.source())
        try await eventually { h.builder.built.count == 2 }
        try await settle(h)
        #expect(h.player.swapsStarted == 1)
        h.pipeline.send(.gestureEnded)
        try await eventually { h.player.swapped.count == 2 }
    }

    @Test func aTimelineChangedDuringABuildBuildsOnlyTheNewOne() async throws {
        var h = Harness()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.builder.gate.waiters == 1 }

        let other = h.project.addTimeline(name: "B", frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
        _ = h.project.importClip(
            MediaClip(
                name: "n", kind: .video, url: URL(fileURLWithPath: "/tmp/other.mov"), duration: CMTime(value: 2, timescale: 1),
                frameRate: 24, colorSpace: .rec709, codecName: "H.264"
            ),
            intoTimeline: other
        )
        let otherSource = ViewerSource(project: h.project, renderProject: h.project, timelineID: other)
        h.pipeline.send(.timelineChanged(otherSource, at: .zero))
        try await eventually { h.builder.started.count == 2 }
        h.builder.gate.open()
        try await eventually { h.player.swapped.count == 1 }
        try await settle(h)
        // The first timeline's build was stopped and never shown.
        #expect(h.builder.built.map(\.timelineID) == [other])
        #expect(h.player.swapped == [StructureKey(project: h.project)])
    }

    @Test func aSwapWaitsForTheNewItemsFrame() async throws {
        var h = Harness()
        h.builder.gate.open()
        h.player.readiness.isOpen = false
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.player.swapsStarted == 1 }
        try await settle(h)
        #expect(h.player.swapped.isEmpty)
        #expect(h.pipeline.phase != .ready)
        // An edit meanwhile is built, and swapped once this one is done.
        h.move(to: 1)
        h.pipeline.show(h.source())
        try await eventually { h.builder.built.count == 2 }
        try await settle(h)
        #expect(h.player.swapsStarted == 1)
        h.player.readiness.open()
        try await eventually { h.player.swapped.count == 2 }
        #expect(h.player.swapped.last == h.key)
        #expect(h.pipeline.phase == .ready)
    }

    @Test func anEmptiedTimelineLetsTheItemGoWithoutBuilding() async throws {
        var h = Harness()
        h.builder.gate.open()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.player.swapped.count == 1 }
        h.project.deleteClip(h.clipID, in: h.timelineID, layer: h.project.timeline(id: h.timelineID)!.layers[0].id)
        h.pipeline.show(h.source())
        try await eventually { h.player.cleared == 1 }
        try await settle(h)
        #expect(h.pipeline.buildsStarted == 1)
        #expect(h.pipeline.phase == .idle)
    }

    /// A rename or a volume changes nothing the picture shows: nothing is
    /// drawn, planned or built.
    @Test func anEditThePictureDoesntShowIsIgnored() async throws {
        var h = Harness()
        h.builder.gate.open()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.player.swapped.count == 1 }
        let layer = h.project.timeline(id: h.timelineID)!.layers[0].id
        h.project.renameLayer(layer, in: h.timelineID, to: "Renamed")
        h.pipeline.show(h.source())
        try await settle(h)
        #expect(h.player.shownValues == 0)
        #expect(h.pipeline.buildsStarted == 1)
    }

    @Test func aHeldStepOfStructureIsLetGo() async throws {
        var h = Harness()
        h.builder.gate.open()
        h.pipeline.send(.appeared(h.source(), at: .zero))
        try await eventually { h.player.swapped.count == 1 }
        var held = h.project
        held.editClip(h.clipID, in: h.timelineID) { $0.anchorPoint = AnimatedValue(Vector2(x: 3, y: 0)) }
        #expect(h.pipeline.showHeld(h.source(held)))
        h.move(to: 3)
        #expect(!h.pipeline.showHeld(h.source()))
        try await eventually { h.player.shownValues == 1 }
        try await settle(h)
        // A held step is drawn, never planned or built.
        #expect(h.pipeline.buildsStarted == 1)
    }
}
