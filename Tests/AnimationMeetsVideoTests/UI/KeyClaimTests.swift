import AppKit
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The keys a focused graph claims from the panels' key monitors.
@MainActor
@Suite struct KeyClaimTests {
    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )!
    }

    @Test func namedKeysAreReadByTheirKeyCode() {
        #expect(KeyClaim.key(of: key(51, "\u{7F}")) == .delete)
        #expect(KeyClaim.key(of: key(117, "\u{F728}")) == .deleteForward)
        #expect(KeyClaim.key(of: key(123, "\u{F702}")) == .leftArrow)
        #expect(KeyClaim.key(of: key(126, "\u{F700}")) == .upArrow)
        // Shift-Tab types a back-tab, and is still Tab.
        #expect(KeyClaim.key(of: key(48, "\u{19}", .shift)) == .tab)
        #expect(KeyClaim.key(of: key(24, "=")) == "=")
    }

    @Test func aClaimTakesItsKeysWithShiftButNotWithCommand() {
        let keys: Set<KeyEquivalent> = [.delete, .leftArrow, .tab, "+"]
        #expect(KeyClaim.claims(keys, key(51, "\u{7F}")))
        #expect(KeyClaim.claims(keys, key(123, "\u{F702}", .shift)))
        #expect(KeyClaim.claims(keys, key(48, "\u{19}", .shift)))
        #expect(!KeyClaim.claims(keys, key(51, "\u{7F}", .command)))
        #expect(!KeyClaim.claims(keys, key(124, "\u{F703}")))
        #expect(!KeyClaim.claims(keys, key(45, "n")))
    }

    @Test func aClaimOnlyHoldsWhileItsViewHasTheKeyboard() {
        let view = KeyClaim.ClaimView()
        view.keys = [.delete]
        #expect(!view.claims(key(51, "\u{7F}")))
        view.isActive = true
        #expect(view.claims(key(51, "\u{7F}")))
        view.isHidden = true
        #expect(!view.claims(key(51, "\u{7F}")))
    }
}

@Suite struct TabStepTests {
    @Test func tabStepsThroughThePartsAndThenLeaves() {
        #expect(TabStep.next(after: nil, of: 3, back: false) == 0)
        #expect(TabStep.next(after: 0, of: 3, back: false) == 1)
        #expect(TabStep.next(after: 2, of: 3, back: false) == nil)
    }

    @Test func shiftTabStartsFromTheLastAndLeavesBeforeTheFirst() {
        #expect(TabStep.next(after: nil, of: 3, back: true) == 2)
        #expect(TabStep.next(after: 1, of: 3, back: true) == 0)
        #expect(TabStep.next(after: 0, of: 3, back: true) == nil)
    }

    @Test func aViewWithNoPartsLetsTabGoOn() {
        #expect(TabStep.next(after: nil, of: 0, back: false) == nil)
    }
}
