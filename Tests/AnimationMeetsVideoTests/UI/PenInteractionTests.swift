import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The pen in the viewer with real events (see `EventHarness`; run with
/// `UI_EVENTS=1`), and docs/pen-tool.md.
@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled), .eventsOneAtATime)
struct PenInteractionTests {
    private static let well = CGSize(width: 1032, height: 612)

    /// An empty timeline in a viewer's canvas with the pen picked, its
    /// history on an undo manager as the editor keeps it, and a play
    /// button on Space, as the viewer's rail has.
    @MainActor
    private final class Rig {
        let state: ProjectState
        let history: ProjectHistory
        let undoManager = UndoManager()
        let timelineID: UUID
        let playback = PlaybackModel()
        let playhead = PlayheadState()
        let effects = EffectsPanelState()
        let canvas = ViewerCanvasState()
        let framing = ViewerFraming()
        let frameSize: CGSize
        var selection: TimelineSelection?
        /// The window's, which the canvas maps with.
        var backingScale = 2.0
        /// Times the play button's Space shortcut went off.
        var plays = 0

        init() throws {
            let project = EditingProject.empty
            timelineID = project.rootTimelineID
            frameSize = try #require(project.timeline(id: timelineID)).frameSize
            state = ProjectState(project)
            history = ProjectHistory(project: project)
            history.undoManager = undoManager
            history.current = { [unowned state] in state.value }
            history.restore = { [unowned state] in state.value = $0 }
            canvas.tool = .pen
            canvas.select = { [unowned self] in selection = $0 }
        }

        var view: some View { Host(rig: self).environment(state).environment(\.projectHistory, history) }

        var mapping: ViewerMapping {
            framing.mapping(frameSize: frameSize, wellSize: PenInteractionTests.well, backingScale: backingScale)
        }

        /// A harness on the rig's view, whose window's scale it maps with.
        func harness() -> EventHarness {
            let harness = EventHarness(view, size: PenInteractionTests.well)
            backingScale = Double(harness.window.backingScaleFactor)
            return harness
        }

        /// Where a place in the frame (pixels from its middle) is in the
        /// well, as the canvas maps it now.
        func view(_ x: Double, _ y: Double) -> CGPoint {
            mapping.toView(CGPoint(x: frameSize.width / 2 + x, y: frameSize.height / 2 + y))
        }

        /// The first path in the timeline, and its control.
        var pathControl: EffectControl? {
            state.value.timeline(id: timelineID)?.layers.lazy.flatMap(\.clips).flatMap(\.effects)
                .first { PathHandles.applies(to: $0) }?.control(.path)
        }

        var path: FreePath? { pathControl?.freePath(at: .zero) }

        var layerCount: Int { state.value.timeline(id: timelineID)?.layers.count ?? 0 }

        func undo() async throws {
            undoManager.undo()
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// The canvas as the editor holds it, drawn again on every edit, and
    /// the play button's shortcut.
    private struct Host: View {
        let rig: Rig

        var body: some View {
            let project = rig.state.value
            ZStack {
                Button("Play") { rig.plays += 1 }
                    .keyboardShortcut(.space, modifiers: [])
                    .opacity(0)
                ViewerCanvas(
                    framing: rig.framing, frameSize: rig.frameSize, playback: rig.playback,
                    handles: ViewerHandlesSource(
                        project: Binding(get: { project }, set: { value in
                            rig.state.value = value
                            rig.history.projectDidChange(rig.state.value)
                        }),
                        timelineID: rig.timelineID, selection: rig.selection, effectsState: rig.effects, playhead: rig.playhead,
                        state: rig.canvas
                    )
                )
            }
        }
    }

    private func withHandles(_ shown: Bool, _ body: () async throws -> Void) async rethrows {
        let key = Preferences.viewerHandles
        let remembered = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(shown, forKey: key)
        defer { UserDefaults.standard.set(remembered, forKey: key) }
        try await body()
    }

    private func space(_ harness: EventHarness, down: Bool) {
        harness.key(code: 49, characters: " ", type: down ? .keyDown : .keyUp)
    }

    @Test func clicksPlacePointsWithShowHandlesOff() async throws {
        try await withHandles(false) {
            let rig = try Rig()
            let harness = rig.harness()
            try await harness.settle(200)
            try await harness.click(at: rig.view(-200, -100))
            try await harness.click(at: rig.view(200, -100))
            try await harness.click(at: rig.view(0, 150))
            let path = try #require(rig.path)
            #expect(path.vertices.count == 3)
            #expect(!path.closed)
            let first = path.vertices[0].point
            #expect(abs(first.x + 200) <= 2 && abs(first.y + 100) <= 2)
            // It made a shape layer, selected with its Path.
            #expect(rig.layerCount == 1)
            #expect(rig.selection != nil)
            #expect(rig.effects.selectedEffectID != nil)
        }
    }

    @Test func eachPointIsAnUndoStepAndUndoAfterClosingReopens() async throws {
        let rig = try Rig()
        let harness = rig.harness()
        try await harness.settle(200)
        try await harness.click(at: rig.view(-200, -100))
        try await harness.click(at: rig.view(200, -100))
        try await harness.click(at: rig.view(0, 150))
        try await harness.click(at: rig.view(-200, -100))
        #expect(rig.path?.closed == true)
        #expect(rig.undoManager.undoActionName == "Close Path")
        try await rig.undo()
        #expect(rig.path?.closed == false)
        #expect(rig.path?.vertices.count == 3)
        // Drawn on again: the next click adds a point.
        try await harness.click(at: rig.view(-250, 100))
        #expect(rig.path?.vertices.count == 4)
        try await rig.undo()
        try await rig.undo()
        #expect(rig.path?.vertices.count == 2)
        #expect(rig.undoManager.undoActionName == "Add Point")
        try await rig.undo()
        try await rig.undo()
        // The first point's step made the layer: nothing is left.
        #expect(rig.layerCount == 0)
    }

    @Test func escapeCancelsThePointThenTheDrawThenThePen() async throws {
        let rig = try Rig()
        let harness = rig.harness()
        try await harness.settle(200)
        try await harness.click(at: rig.view(-200, -100))
        try await harness.click(at: rig.view(200, -100))
        // Mid-drag: that point goes.
        try await harness.press(at: rig.view(0, 150), dragTo: rig.view(60, 150))
        harness.escape()
        try await harness.settle()
        harness.mouse(.leftMouseUp, at: rig.view(60, 150))
        try await harness.settle(200)
        #expect(rig.path?.vertices.count == 2)
        // Mid-draw: the draw goes, as a step of its own.
        harness.escape()
        try await harness.settle(200)
        #expect(rig.layerCount == 0)
        #expect(rig.undoManager.undoActionName == "Cancel Path")
        try await rig.undo()
        #expect(rig.path?.vertices.count == 2)
        // Nothing drawn (Return ended it): the arrow comes back.
        harness.key(code: 36, characters: "\r")
        try await harness.settle(200)
        harness.escape()
        try await harness.settle(200)
        #expect(rig.canvas.tool == .arrow)
    }

    @Test func spaceIsTheHandAndNeverPlays() async throws {
        let rig = try Rig()
        let harness = rig.harness()
        try await harness.settle(200)
        // Zoomed in, so the picture can move.
        rig.framing.apply(rig.mapping.zoomed(to: 2, about: CGPoint(x: Self.well.width / 2, y: Self.well.height / 2)))
        try await harness.settle()
        let before = rig.mapping.toView(.zero)
        space(harness, down: true)
        try await harness.settle()
        try await harness.press(at: CGPoint(x: 500, y: 300), dragTo: CGPoint(x: 560, y: 330))
        harness.mouse(.leftMouseUp, at: CGPoint(x: 560, y: 330))
        try await harness.settle()
        space(harness, down: false)
        try await harness.settle(200)
        let after = rig.mapping.toView(.zero)
        #expect(abs(after.x - before.x - 60) <= 1 && abs(after.y - before.y - 30) <= 1)
        #expect(rig.layerCount == 0)
        #expect(rig.plays == 0)
        // A tap doesn't play either, with the pen picked.
        space(harness, down: true)
        space(harness, down: false)
        try await harness.settle(200)
        #expect(rig.plays == 0)
        #expect(!rig.playback.isPlaying)
    }

    @Test func aScrollAndAZoomBetweenPointsLeaveBothOnThePicture() async throws {
        let rig = try Rig()
        let harness = rig.harness()
        try await harness.settle(200)
        try await harness.click(at: rig.view(-100, 0))
        // Moved as a scroll moves it, then zoomed in with ⌘=, an event the
        // canvas takes itself and is drawn again after.
        rig.framing.apply(rig.mapping.scrolled(by: CGVector(dx: 40, dy: -20)))
        harness.key(code: 24, characters: "=", flags: .command)
        try await harness.settle(200)
        #expect(rig.mapping.effectiveZoom > 1.1)
        try await harness.settle(200)
        try await harness.click(at: rig.view(100, 0))
        let points = try #require(rig.path?.vertices.map(\.point))
        #expect(points.count == 2)
        #expect(abs(points[0].x + 100) <= 2 && abs(points[1].x - 100) <= 2)
        #expect(abs(points[1].y) <= 2)
    }

    @Test func pPicksThePenAndPutsTheArrowBack() async throws {
        let rig = try Rig()
        rig.canvas.tool = .arrow
        let harness = rig.harness()
        try await harness.settle(200)
        harness.key(code: 35, characters: "p")
        try await harness.settle()
        #expect(rig.canvas.tool == .pen)
        harness.key(code: 35, characters: "p")
        try await harness.settle()
        #expect(rig.canvas.tool == .arrow)
    }

    @Test func playingTakesNoPresses() async throws {
        let rig = try Rig()
        let harness = rig.harness()
        rig.playback.togglePlayback()
        try await harness.settle(200)
        try await harness.click(at: rig.view(0, 0))
        if rig.playback.isPlaying { rig.playback.togglePlayback() }
        #expect(rig.layerCount == 0)
    }
}
