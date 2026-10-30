import AppKit
import Testing
@testable import AnimationMeetsVideo

/// Which views having the keyboard keep the arrow, Home and End keys from
/// the playhead (`TimelineView.keepsArrowKeys`).
@MainActor
struct TimelineArrowKeysTests {
    @Test func buttonsLeaveThemToThePlayhead() {
        #expect(!TimelineView.keepsArrowKeys(NSButton(title: "Export…", target: nil, action: nil)))
        #expect(!TimelineView.keepsArrowKeys(NSButton(checkboxWithTitle: "Snap", target: nil, action: nil)))
        #expect(!TimelineView.keepsArrowKeys(NSView()))
        #expect(!TimelineView.keepsArrowKeys(nil))
    }

    @Test func controlsThatUseThemKeepThem() {
        #expect(TimelineView.keepsArrowKeys(NSPopUpButton()))
        #expect(TimelineView.keepsArrowKeys(NSSlider()))
        #expect(TimelineView.keepsArrowKeys(NSSegmentedControl()))
        #expect(TimelineView.keepsArrowKeys(NSTableView()))
    }
}
