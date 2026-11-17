import AppKit
import Testing
@testable import AnimationMeetsVideo

/// What a draft panel keeps from the window it works over: clicks and
/// hovering, but not scrolling or pinching, which only look around.
@MainActor
struct WindowInputBlockTests {
    @Test func aDraftPanelLetsScrollingAndPinchingThrough() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let block = WindowInputBlock(window: window) {}
        defer { block.end() }

        #expect(WindowInputBlock.isBlocked(window))
        #expect(!WindowInputBlock.blocks(.scrollWheel, in: window))
        #expect(!WindowInputBlock.blocks(.magnify, in: window))
        #expect(WindowInputBlock.blocks(.leftMouseDown, in: window))
        #expect(WindowInputBlock.blocks(.rightMouseDown, in: window))
        #expect(WindowInputBlock.blocks(.mouseMoved, in: window))
    }

    @Test func nothingIsKeptOnceItEnds() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let block = WindowInputBlock(window: window) {}
        block.end()

        #expect(!WindowInputBlock.isBlocked(window))
        #expect(!WindowInputBlock.blocks(.leftMouseDown, in: window))
    }
}
