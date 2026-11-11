import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled))
struct KeyframeDesignerInteractionTests {
    @MainActor private struct Fixture {
        let hud: KeyframeGraphHUDs
        let state: ProjectState
        let history: ProjectHistory
        let undo: UndoManager
        let key: KeyframeDesignerKey
        let target: KeyframingTarget
        let graph: ParameterKey

        init(method: EffectKind? = nil) throws {
            var project = EditingProject.empty
            let timelineID = project.rootTimelineID
            let added = project.addShapeLayer(.rectangle, to: timelineID)
            let shape = try #require(added)
            let effect = project.addEffect(.transform, toClip: shape.clipID, in: timelineID)
            let effectID = try #require(effect)
            let clip = try #require(project.clipAndLayer(shape.clipID, in: timelineID)?.clip)
            let control = try #require(clip.effect(id: effectID)?.control(.position))
            key = KeyframeDesignerKey(timelineID: timelineID, clipID: shape.clipID)
            target = .control(effectID: effectID, controlID: control.id)
            graph = try #require(KeyframeDesigner.parameterKey(of: target, in: clip, timelineID: timelineID))
            project.setKeyframing(method, driving: target, onClip: shape.clipID, in: timelineID)
            let state = ProjectState(project)
            let history = ProjectHistory(project: state.value)
            let undo = UndoManager()
            history.undoManager = undo
            history.current = { state.value }
            history.restore = { state.value = $0 }
            let hud = KeyframeGraphHUDs()
            hud.projectState = state
            hud.history = history
            hud.undoManager = undo
            hud.update(project: state.value)
            hud.onSeek = { [weak hud] in hud?.playhead = $0 }
            hud.onEdit = { [weak hud] change in
                change(&state.value)
                history.projectDidChange(state.value)
                hud?.update(project: state.held ?? state.value)
            }
            self.hud = hud
            self.state = state
            self.history = history
            self.undo = undo
        }

        func open() throws -> EventHarness {
            hud.showDesigner(key, target: target)
            let window = try #require(NSApp.windows.first { $0.title.hasPrefix("Keyframe Designer:") })
            window.setContentSize(CGSize(width: 900, height: 620))
            return EventHarness(window: window)
        }
    }

    @Test func anAudioBoxDragIsHeldAndUndoesInOneStep() async throws {
        let f = try Fixture(method: .audioKeys)
        defer { f.hud.closeAll() }
        let harness = try f.open()
        try await harness.settle(250)
        let before = f.state.value
        // Inside the default 40–120 Hz, -50 to -10 dB box, below the
        // transport and control picker. Both frequency and level change.
        let start = CGPoint(x: 405, y: 140)
        let middle = CGPoint(x: 430, y: 150)
        let end = CGPoint(x: 450, y: 160)
        try await harness.press(at: start, dragTo: middle)
        #expect(f.history.isInGesture)
        #expect(f.state.held != nil)
        #expect(f.state.value == before)
        // Longer than history's normal coalescing interval.
        try await harness.settle(700)
        harness.mouse(.leftMouseDragged, at: end)
        try await harness.settle()
        harness.mouse(.leftMouseUp, at: end)
        try await harness.settle(250)
        #expect(!f.history.isInGesture)
        #expect(f.state.held == nil)
        #expect(f.state.value != before)
        #expect(f.undo.canUndo)
        f.undo.undo()
        #expect(f.state.value == before)
        #expect(!f.undo.canUndo)
    }

    @Test func emptyAndSingleKeyframeGraphsKeepAddingAndSeeking() async throws {
        let f = try Fixture()
        defer { f.hud.closeAll() }
        let harness = try f.open()
        try await harness.settle()
        // The ruler remains operable even before the first keyframe.
        try await harness.press(at: CGPoint(x: 550, y: 155), dragTo: CGPoint(x: 570, y: 155))
        harness.mouse(.leftMouseUp, at: CGPoint(x: 570, y: 155))
        try await harness.settle()
        #expect(f.hud.playhead > .zero)
        let first = f.hud.playhead
        try await harness.click(at: CGPoint(x: 875, y: 95))
        #expect(f.state.value.components(of: f.graph)?.keyframes.count == 1)
        try await harness.press(at: CGPoint(x: 750, y: 155), dragTo: CGPoint(x: 770, y: 155))
        harness.mouse(.leftMouseUp, at: CGPoint(x: 770, y: 155))
        try await harness.settle()
        #expect(f.hud.playhead > first)
        try await harness.click(at: CGPoint(x: 875, y: 95))
        #expect(f.state.value.components(of: f.graph)?.keyframes.count == 2)
    }

    @Test func removingAudioKeysDuringADragReleasesTheProject() async throws {
        let f = try Fixture(method: .audioKeys)
        defer { f.hud.closeAll() }
        let harness = try f.open()
        try await harness.settle(250)
        try await harness.press(at: CGPoint(x: 405, y: 140), dragTo: CGPoint(x: 430, y: 150))
        #expect(f.state.isHolding)
        f.state.value.setKeyframing(nil, driving: f.target, onClip: f.key.clipID, in: f.key.timelineID)
        f.hud.update(project: f.state.value)
        try await harness.settle(250)
        #expect(!f.state.isHolding)
        #expect(f.state.held == nil)
        #expect(!f.history.isInGesture)
        harness.mouse(.leftMouseUp, at: CGPoint(x: 430, y: 150))
    }

    @Test func spaceLeavesFocusedButtonsAloneButPlaysFromTheGraph() async throws {
        let f = try Fixture()
        defer { f.hud.closeAll() }
        let harness = try f.open()
        try await harness.settle()
        var plays = 0
        f.hud.onTogglePlayback = { plays += 1 }
        // A native button exercises the same focus guard as the Control
        // picker, without opening a menu that tracks the mouse modally.
        let button = NSButton(title: "Test control", target: nil, action: nil)
        harness.window.contentView?.addSubview(button)
        let focused = harness.window.makeFirstResponder(button)
        #expect(focused)
        harness.key(code: 49, characters: " ")
        #expect(plays == 0)
        harness.window.makeFirstResponder(nil)
        harness.key(code: 49, characters: " ")
        #expect(plays == 1)
    }
}
