import Testing
@testable import AnimationMeetsVideo

@Suite struct BrowserSelectionTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func aClickSelectsOnlyThatItem() {
        var selection = BrowserSelection<String>()
        selection.commandClick("a")
        selection.click("c")
        #expect(selection.items == ["c"])
    }

    @Test func commandClickAddsAndTakesOut() {
        var selection = BrowserSelection<String>()
        selection.click("b")
        selection.commandClick("d")
        #expect(selection.items == ["b", "d"])
        selection.commandClick("b")
        #expect(selection.items == ["d"])
    }

    @Test func shiftClickSelectsTheRunFromTheLastClickInBrowserOrder() {
        var selection = BrowserSelection<String>()
        selection.click("d")
        selection.shiftClick("b", in: order)
        #expect(selection.ordered(in: order) == ["b", "c", "d"])
        // The anchor stays, so a second Shift-click re-extends from it.
        selection.shiftClick("e", in: order)
        #expect(selection.ordered(in: order) == ["d", "e"])
    }

    @Test func dragsCarryTheSelectionInBrowserOrderNotPickOrder() {
        var selection = BrowserSelection<String>()
        selection.click("e")
        selection.commandClick("a")
        selection.commandClick("c")
        #expect(selection.dragged(from: "c", in: order) == ["a", "c", "e"])
        // Dragging something not selected drags just it.
        #expect(selection.dragged(from: "b", in: order) == ["b"])
    }

    @Test func aRangeBelongsToOneItemAndAClickOutsideItSelectsTheWholeItem() {
        var selection = BrowserSelection<String>()
        selection.commandClick("a")
        selection.setRange(of: "b", from: 7, to: 3, duration: 10)
        #expect(selection.items == ["b"])
        #expect(selection.range == .init(item: "b", start: 3, end: 7))

        selection.click("b", at: 5)
        #expect(selection.range != nil)
        selection.click("b", at: 8)
        #expect(selection.range == nil)
        #expect(selection.items == ["b"])
    }

    @Test func aPressDragsWhatIsSelectedAndPicksARangeAnywhereElse() {
        var selection = BrowserSelection<String>()
        // Nothing selected: a drag across a clip picks part of it.
        #expect(!selection.pressDrags("a", at: 2))
        selection.click("a")
        selection.commandClick("b")
        #expect(selection.pressDrags("a", at: 2))
        #expect(selection.pressDrags("b", at: 2))
        #expect(!selection.pressDrags("c", at: 2))

        // A clip with a range drags only from inside it.
        selection.setRange(of: "c", from: 3, to: 7, duration: 10)
        #expect(selection.pressDrags("c", at: 5))
        #expect(!selection.pressDrags("c", at: 8))
        #expect(!selection.pressDrags("a", at: 2))

        selection.clear()
        #expect(!selection.pressDrags("a", at: 2))
    }

    @Test func commandOrShiftClickFromARangeSelectsTheWholeClips() {
        var selection = BrowserSelection<String>()
        selection.setRange(of: "b", from: 3, to: 7, duration: 10)
        selection.commandClick("d")
        #expect(selection.range == nil)
        #expect(selection.items == ["b", "d"])

        selection.setRange(of: "b", from: 3, to: 7, duration: 10)
        selection.shiftClick("d", in: order)
        #expect(selection.range == nil)
        #expect(selection.ordered(in: order) == ["b", "c", "d"])
    }

    @Test func rangesAreClampedToTheItem() {
        var selection = BrowserSelection<String>()
        selection.setRange(of: "a", from: -2, to: 12, duration: 10)
        #expect(selection.range == .init(item: "a", start: 0, end: 10))
    }

    @Test func itemsThatAreGoneAreDropped() {
        var selection = BrowserSelection<String>()
        selection.setRange(of: "c", from: 1, to: 2, duration: 5)
        selection.keep(only: ["a", "b"])
        #expect(selection.items.isEmpty)
        #expect(selection.range == nil)
        #expect(selection.anchor == nil)
    }

    /// Command-A takes every item whole, dropping a range, and Shift-click
    /// still extends from the item last clicked.
    @Test func selectAllTakesEveryItemAndKeepsTheAnchor() {
        var selection = BrowserSelection<String>()
        selection.setRange(of: "c", from: 1, to: 2, duration: 5)
        selection.selectAll(in: order)
        #expect(selection.items == Set(order))
        #expect(selection.range == nil)
        selection.shiftClick("e", in: order)
        #expect(selection.ordered(in: order) == ["c", "d", "e"])
    }
}
