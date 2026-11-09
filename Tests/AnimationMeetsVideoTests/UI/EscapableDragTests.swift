import Testing
@testable import AnimationMeetsVideo

/// How a drag that Escape cancels begins, is cancelled and ends
/// (`EscapableDrag`), with the key and the button stood in for. Each test
/// is synchronous, so none runs between another's steps and sees its
/// `DragEscape.isActive`.
@MainActor
struct EscapableDragTests {
    @Test func escapeCancelsOnceAndTheRestIsIgnored() {
        let drag = EscapableDrag()
        var cancels = 0
        #expect(drag.follow { cancels += 1 })
        #expect(drag.isRunning)
        #expect(DragEscape.isActive)
        drag.pressEscape()
        #expect(cancels == 1)
        // Escape is the timeline's again, though the button is down.
        #expect(!DragEscape.isActive)
        drag.pressEscape()
        #expect(cancels == 1)
        #expect(!drag.follow { cancels += 1 })
        #expect(!drag.end())
        #expect(!drag.isRunning)
    }

    @Test func aDragNotCancelledCommits() {
        let drag = EscapableDrag()
        #expect(drag.follow {})
        #expect(drag.follow {})
        #expect(drag.end())
        #expect(!DragEscape.isActive)
    }

    @Test func aClickThatNeverMovedCommits() {
        #expect(EscapableDrag().end())
    }

    @Test func aCancelledDragWhoseEndIsLostDoesntHoldUpTheNext() {
        let drag = EscapableDrag()
        _ = drag.follow {}
        drag.pressEscape()
        // The button comes up, and the gesture's end is never heard.
        drag.releaseButton()
        var cancels = 0
        #expect(drag.follow { cancels += 1 })
        drag.pressEscape()
        #expect(cancels == 1)
        #expect(!drag.end())
    }

    @Test func aCancelledDragsEndHeardAfterTheButtonIsStillCancelled() {
        let drag = EscapableDrag()
        _ = drag.follow {}
        drag.pressEscape()
        drag.releaseButton()
        #expect(!drag.end())
    }

    @Test func theButtonComingUpStopsEscapeBeingTheDrags() {
        let drag = EscapableDrag()
        _ = drag.follow {}
        drag.releaseButton()
        #expect(!DragEscape.isActive)
        #expect(drag.end())
    }
}
