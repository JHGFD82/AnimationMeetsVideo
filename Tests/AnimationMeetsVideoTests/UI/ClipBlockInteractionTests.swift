import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// A clip block clicked, dragged and cancelled with real events (see
/// `EventHarness`; run with `UI_EVENTS=1`).
@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled))
struct ClipBlockInteractionTests {
    /// What the block asked for.
    @MainActor
    final class Calls {
        var selects = 0
        var blades: [CMTime] = []
        var moves: [CMTime] = []
        /// What the next move's edit answers: made, or refused.
        var movesAreMade = true
    }

    /// The tool, changed while the block is up.
    @MainActor @Observable
    final class Tool {
        var tool: TimelineTool
        init(_ tool: TimelineTool) { self.tool = tool }
    }

    /// A four-second clip at 50 points a second: 200 by 40 points, from
    /// the window's left edge.
    private struct Block: View {
        let tool: Tool
        let box: LiveClipHandlers
        var readout: DragTimecodeReadout?

        var body: some View {
            ClipBlockView(model: .sample(Self.clip, tool: tool.tool), handlers: box)
                .environment(readout)
        }

        static let clip = TimelineClip(id: clipID, source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))

        static let clipID = UUID()
    }

    private func harness(_ tool: Tool, _ calls: Calls, readout: DragTimecodeReadout? = nil) -> EventHarness {
        var handlers = ClipBlockHandlers.inert(
            onSelect: { calls.selects += 1 },
            onMove: { start, _ in
                calls.moves.append(start)
                return calls.movesAreMade
            }
        )
        handlers.onBlade = { calls.blades.append($0) }
        // Lands wherever it is asked to, on its own layer.
        handlers.resolveMove = { start, _ in ClipMovePreview(start: CMTimeMaximum(.zero, start), layerID: nil, offsetY: 0) }
        handlers.resolveTrimEnd = { end in
            var trimmed = Block.clip
            trimmed.trimEnd = end
            return trimmed
        }
        handlers.resolveSlip = { delta in
            var slipped = Block.clip
            slipped.trimStart = CMTimeAdd(slipped.trimStart, delta)
            slipped.trimEnd = CMTimeAdd(slipped.trimEnd, delta)
            return slipped
        }
        return EventHarness(Block(tool: tool, box: LiveClipHandlers(handlers), readout: readout), size: CGSize(width: 400, height: 40))
    }

    private let middle = CGPoint(x: 100, y: 20)

    /// The time a reading shows, in seconds; NaN for anything else.
    private static func seconds(_ value: DragTimecodeReadout.Value?) -> Double {
        guard case .time(let time) = value else { return .nan }
        return time.seconds
    }

    @Test func aClickSelectsWithTheArrowAndCutsWithTheBlade() async throws {
        let calls = Calls()
        let tool = Tool(.arrow)
        let harness = harness(tool, calls)
        try await harness.click(at: middle)
        #expect(calls.selects == 1)
        #expect(calls.blades.isEmpty)

        // The blade's hover overlay doesn't take its click.
        tool.tool = .blade
        try await harness.settle()
        try await harness.click(at: middle)
        #expect(calls.blades.count == 1)
        #expect(calls.selects == 1)
    }

    @Test func aDragMovesTheClip() async throws {
        let calls = Calls()
        let harness = harness(Tool(.arrow), calls)
        try await harness.press(at: middle, dragTo: CGPoint(x: 150, y: 20))
        harness.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 20))
        try await harness.settle(250)
        #expect(calls.moves.count == 1)
        #expect(abs((calls.moves.first?.seconds ?? 0) - 1) < 0.05)
        #expect(!DragEscape.isActive)
    }

    /// While moving, the box over the pointer shows where the clip will
    /// start and how far that is; Escape takes it away.
    @Test func aMoveShowsItsTimecodeOverThePointer() async throws {
        let readout = DragTimecodeReadout()
        let harness = harness(Tool(.arrow), Calls(), readout: readout)
        try await harness.press(at: middle, dragTo: CGPoint(x: 150, y: 20))
        let reading = try #require(readout.reading)
        #expect(abs(Self.seconds(reading.value) - 1) < 0.05)
        #expect(abs(reading.moved.seconds - 1) < 0.05)
        #expect(abs(reading.pointer.x - 150) < 1)
        harness.escape()
        try await harness.settle()
        #expect(readout.reading == nil)
        harness.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 20))
        try await harness.settle(250)
        #expect(readout.reading == nil)
    }

    /// Trimming the end shows where the end will be, and that it moved
    /// back; letting go takes the box away.
    @Test func aTrimShowsTheEdgesTimecode() async throws {
        let readout = DragTimecodeReadout()
        let harness = harness(Tool(.arrow), Calls(), readout: readout)
        try await harness.press(at: CGPoint(x: 200, y: 20), dragTo: CGPoint(x: 150, y: 20))
        let reading = try #require(readout.reading)
        #expect(abs(Self.seconds(reading.value) - 3) < 0.05)
        #expect(abs(reading.moved.seconds + 1) < 0.05)
        harness.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 20))
        try await harness.settle(250)
        #expect(readout.reading == nil)
    }

    /// Slipping shows only how far the footage moved: dragging right
    /// brings earlier frames in.
    @Test func aSlipShowsOnlyItsChange() async throws {
        let readout = DragTimecodeReadout()
        let harness = harness(Tool(.slip), Calls(), readout: readout)
        try await harness.press(at: middle, dragTo: CGPoint(x: 150, y: 20))
        let reading = try #require(readout.reading)
        #expect(reading.value == nil)
        #expect(abs(reading.moved.seconds + 1) < 0.05)
        harness.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 20))
        try await harness.settle(250)
        #expect(readout.reading == nil)
    }

    /// Escape mid-move: nothing is edited, and the next drag works.
    @Test func escapeCancelsAMoveAndTheNextDragStillMoves() async throws {
        let calls = Calls()
        let harness = harness(Tool(.arrow), calls)
        try await harness.press(at: middle, dragTo: CGPoint(x: 150, y: 20))
        #expect(DragEscape.isActive)
        harness.escape()
        try await harness.settle()
        #expect(!DragEscape.isActive)
        // Moving on after Escape, the button still down, does nothing.
        harness.mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 20))
        try await harness.settle()
        harness.mouse(.leftMouseUp, at: CGPoint(x: 200, y: 20))
        try await harness.settle(250)
        #expect(calls.moves.isEmpty)

        try await harness.press(at: middle, dragTo: CGPoint(x: 150, y: 20))
        harness.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 20))
        try await harness.settle(250)
        #expect(calls.moves.count == 1)
    }

    /// Escape and the button coming up in the same turn: not committed.
    @Test func escapeJustBeforeLettingGoCommitsNothing() async throws {
        let calls = Calls()
        let harness = harness(Tool(.arrow), calls)
        try await harness.press(at: middle, dragTo: CGPoint(x: 150, y: 20))
        harness.escape()
        harness.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 20))
        try await harness.settle(250)
        #expect(calls.moves.isEmpty)
        #expect(!DragEscape.isActive)
    }

    /// Outside a drag, Escape isn't the block's: the timeline's own
    /// Escape (select nothing) stands aside only while `isActive`.
    @Test func escapeOutsideADragIsLeftToTheTimeline() async throws {
        let calls = Calls()
        let harness = harness(Tool(.arrow), calls)
        try await harness.click(at: middle)
        #expect(!DragEscape.isActive)
        harness.escape()
        try await harness.settle()
        #expect(!DragEscape.isActive)
    }

    @Test func aRefusedMoveIsAskedForOnce() async throws {
        let calls = Calls()
        calls.movesAreMade = false
        let harness = harness(Tool(.arrow), calls)
        try await harness.press(at: middle, dragTo: CGPoint(x: 150, y: 20))
        harness.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 20))
        try await harness.settle(250)
        #expect(calls.moves.count == 1)
    }

    /// Back to the arrow from the slip tool, dragging moves the clip again.
    @Test func theArrowMovesAClipAfterTheSlipTool() async throws {
        let calls = Calls()
        let tool = Tool(.slip)
        let harness = harness(tool, calls)
        try await harness.press(at: middle, dragTo: CGPoint(x: 150, y: 20))
        harness.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 20))
        try await harness.settle(250)
        #expect(calls.moves.isEmpty)

        tool.tool = .arrow
        try await harness.settle()
        try await harness.press(at: middle, dragTo: CGPoint(x: 150, y: 20))
        harness.mouse(.leftMouseUp, at: CGPoint(x: 150, y: 20))
        try await harness.settle(250)
        #expect(calls.moves.count == 1)
    }
}
