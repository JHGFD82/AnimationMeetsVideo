import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The viewer's handles dragged, cancelled and nudged with real events (see
/// `EventHarness`; run with `UI_EVENTS=1`).
@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled))
struct ViewerCanvasInteractionTests {
    private static let well = CGSize(width: 1032, height: 612)

    /// A rectangle on a graphic clip under the playhead, selected, in a
    /// viewer's canvas.
    @MainActor
    private final class Rig {
        let state: ProjectState
        let timelineID: UUID
        let clipID: UUID
        let selection: TimelineSelection
        let playback = PlaybackModel()
        let playhead = PlayheadState()
        let effects = EffectsPanelState()
        let canvas = ViewerCanvasState()
        let framing = ViewerFraming()
        let frameSize: CGSize

        init() throws {
            var project = EditingProject.empty
            timelineID = project.rootTimelineID
            let added = project.addShapeLayer(.rectangle, to: timelineID)
            let shape = try #require(added)
            clipID = shape.clipID
            selection = TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID)
            frameSize = try #require(project.timeline(id: timelineID)).frameSize
            state = ProjectState(project)
        }

        var clip: TimelineClip? { state.value.clipAndLayer(clipID, in: timelineID)?.clip }

        var view: some View { Host(rig: self).environment(state) }

        /// A place inside the clip's box, in the canvas's points, where a
        /// press moves the clip: a quarter of the way in from its top left,
        /// clear of the anchor's crosshair at the middle (which a press
        /// there would take first) and of the scale handles on the edges.
        func boxInside() throws -> CGPoint {
            let clip = try #require(self.clip)
            let rect = TransformHandles.pictureRect(of: clip, in: state.value, frameSize: frameSize, pictureSize: nil, at: .zero)
            let mapping = ViewerMapping(frameSize: frameSize, wellSize: ViewerCanvasInteractionTests.well)
            return mapping.toView(CGPoint(x: rect.minX + rect.width / 4, y: rect.minY + rect.height / 4))
        }

        var pixelsPerPoint: Double {
            ViewerMapping(frameSize: frameSize, wellSize: ViewerCanvasInteractionTests.well).pixelsPerPoint
        }
    }

    /// The canvas as the editor holds it: the editor reads the project in
    /// its body, so every edit draws it again and hands the canvas a fresh
    /// binding. A binding kept in a view gives the value from when the view
    /// was last drawn, so built once, the canvas would edit from the clip
    /// as it first was every time.
    private struct Host: View {
        let rig: Rig

        var body: some View {
            let project = rig.state.value
            ViewerCanvas(
                framing: rig.framing, frameSize: rig.frameSize, playback: rig.playback,
                handles: ViewerHandlesSource(
                    project: Binding(get: { project }, set: { rig.state.value = $0 }), timelineID: rig.timelineID,
                    selection: rig.selection, effectsState: rig.effects, playhead: rig.playhead, state: rig.canvas
                )
            )
        }
    }

    private func withHandles(_ shown: Bool, _ body: () async throws -> Void) async rethrows {
        let key = Preferences.viewerHandles
        let remembered = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(shown, forKey: key)
        defer { UserDefaults.standard.set(remembered, forKey: key) }
        try await body()
    }

    private func position(_ clip: TimelineClip?) -> [Double]? {
        clip?.effects.first { $0.kind == .transform }?.control(.position)?.values(at: .zero)
    }

    @Test func nothingMovesWithShowHandlesOff() async throws {
        try await withHandles(false) {
            let rig = try Rig()
            let harness = EventHarness(rig.view, size: Self.well)
            let inside = try rig.boxInside()
            try await harness.press(at: inside, dragTo: CGPoint(x: inside.x + 50, y: inside.y))
            harness.mouse(.leftMouseUp, at: CGPoint(x: inside.x + 50, y: inside.y))
            try await harness.settle(200)
            #expect(rig.clip?.effects.contains { $0.kind == .transform } == false)
        }
    }

    @Test func aDragInsideTheBoxMovesTheClipAndAddsATransform() async throws {
        try await withHandles(true) {
            let rig = try Rig()
            let harness = EventHarness(rig.view, size: Self.well)
            try await harness.settle(200)
            let inside = try rig.boxInside()
            let end = CGPoint(x: inside.x + 50, y: inside.y - 20)
            try await harness.press(at: inside, dragTo: end)
            // Held while dragging: the project is as it was.
            #expect(rig.state.held != nil)
            harness.mouse(.leftMouseUp, at: end)
            try await harness.settle(200)
            let moved = try #require(position(rig.clip))
            #expect(abs(moved[0] - 50 * rig.pixelsPerPoint) <= 1)
            #expect(abs(moved[1] + 20 * rig.pixelsPerPoint) <= 1)
            #expect(rig.state.held == nil)
        }
    }

    @Test func aPressThatBarelyMovesChangesNothing() async throws {
        try await withHandles(true) {
            let rig = try Rig()
            let harness = EventHarness(rig.view, size: Self.well)
            try await harness.settle(200)
            let inside = try rig.boxInside()
            try await harness.press(at: inside, dragTo: CGPoint(x: inside.x + 2, y: inside.y), steps: 2)
            harness.mouse(.leftMouseUp, at: CGPoint(x: inside.x + 2, y: inside.y))
            try await harness.settle(200)
            #expect(rig.clip?.effects.contains { $0.kind == .transform } == false)
        }
    }

    @Test func escapePutsBackATransformTheDragAdded() async throws {
        try await withHandles(true) {
            let rig = try Rig()
            let before = rig.clip
            let harness = EventHarness(rig.view, size: Self.well)
            try await harness.settle(200)
            let inside = try rig.boxInside()
            let end = CGPoint(x: inside.x + 60, y: inside.y)
            try await harness.press(at: inside, dragTo: end)
            harness.escape()
            try await harness.settle()
            harness.mouse(.leftMouseUp, at: end)
            try await harness.settle(200)
            #expect(rig.clip == before)
        }
    }

    @Test func playingHidesTheHandlesAndTakesNoPresses() async throws {
        try await withHandles(true) {
            let rig = try Rig()
            let harness = EventHarness(rig.view, size: Self.well)
            rig.playback.togglePlayback()
            try await harness.settle(200)
            let inside = try rig.boxInside()
            try await harness.press(at: inside, dragTo: CGPoint(x: inside.x + 50, y: inside.y))
            harness.mouse(.leftMouseUp, at: CGPoint(x: inside.x + 50, y: inside.y))
            try await harness.settle(200)
            if rig.playback.isPlaying { rig.playback.togglePlayback() }
            #expect(rig.clip?.effects.contains { $0.kind == .transform } == false)
        }
    }

    @Test func aClickGivesTheKeysAndTheArrowsNudge() async throws {
        try await withHandles(true) {
            let rig = try Rig()
            let harness = EventHarness(rig.view, size: Self.well)
            try await harness.settle(200)
            try await harness.click(at: try rig.boxInside())
            harness.key(code: 124, characters: "\u{F703}")
            try await harness.settle()
            harness.key(code: 125, characters: "\u{F701}", flags: .shift)
            try await harness.settle(200)
            #expect(position(rig.clip) == [1, 10])
            // Tab picks Scale; ↑ scales up.
            harness.key(code: 48, characters: "\t")
            try await harness.settle()
            harness.key(code: 126, characters: "\u{F700}")
            try await harness.settle(200)
            #expect(rig.clip?.effects.first { $0.kind == .transform }?.control(.scale)?.values(at: .zero) == [101, 101])
        }
    }
}
