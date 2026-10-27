import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// How a clip block's drags begin, end and are cancelled (`ClipDragBook`),
/// and how wide its trim handles are.
@MainActor
struct ClipDragTests {
    /// Switching from the slip tool back to the arrow still moves clips:
    /// the one drag gesture is on for both, and moves with the arrow.
    @Test func theArrowMovesClipsAfterTheSlipTool() {
        var tool = TimelineTool.slip
        #expect(ClipDragBook.Kind(tool: tool) == .slip)
        #expect(ClipDragBook.gestureMask(for: tool) == .all)
        tool = .arrow
        #expect(ClipDragBook.Kind(tool: tool) == .move)
        #expect(ClipDragBook.gestureMask(for: tool) == .all)
    }

    /// Off is `.subviews`, never `.none`, which would also switch off the
    /// gestures inside the block.
    @Test func theBladeSwitchesTheDragOffButNotTheGesturesInside() {
        #expect(ClipDragBook.Kind(tool: .blade) == nil)
        #expect(ClipDragBook.gestureMask(for: .blade) == .subviews)
        for tool in TimelineTool.allCases {
            #expect(ClipDragBook.gestureMask(for: tool) != .none)
        }
    }

    @Test func aCancelledDragIgnoresTheRestUntilTheButtonComesUp() {
        let book = ClipDragBook()
        var escaped = 0
        book.begin(.move) { escaped += 1 }
        #expect(book.kind == .move)
        #expect(DragEscape.isActive)

        book.cancel()
        #expect(book.isCancelled)
        #expect(book.kind == .move)
        #expect(!DragEscape.isActive)

        book.finish()
        #expect(book.kind == nil)
        #expect(!book.isCancelled)

        // The next drag starts afresh.
        book.begin(.trim) {}
        #expect(book.kind == .trim)
        #expect(!book.isCancelled)
        book.finish()
        #expect(!DragEscape.isActive)
        #expect(escaped == 0)
    }

    @Test func onlyChangesAreSentUp() {
        var sent = LastSent<CMTime?>(nil)
        let one = CMTime(value: 1, timescale: 1), two = CMTime(value: 2, timescale: 1)
        // Nothing was showing, so clearing it again sends nothing.
        let sends = [nil, one, one, two, nil, nil].map { sent.changes(to: $0) }
        #expect(sends == [false, true, false, true, true, false])
    }

    @Test func narrowClipsKeepTheirMiddleToMove() {
        #expect(ClipBlockView.trimHandleWidth(forClipWidth: 200) == ClipBlockView.trimHandleWidth)
        #expect(ClipBlockView.trimHandleWidth(forClipWidth: 24) == ClipBlockView.trimHandleWidth)
        #expect(ClipBlockView.trimHandleWidth(forClipWidth: 20) == 5)
        #expect(ClipBlockView.trimHandleWidth(forClipWidth: 4) == 2)
    }
}
