import AppKit
import SwiftUI

// The floating panel a draft editor works in, as Beat Match and the motion
// designer do: it undoes the draft rather than the project, its close
// button asks the editor, and drags inside it belong to its views.

/// Undo in the panel undoes the draft, not the project.
final class DraftPanel: NSPanel {
    weak var draftUndoManager: UndoManager?
    override var undoManager: UndoManager? { draftUndoManager ?? super.undoManager }

    /// A titled, resizable floating panel in the editor's dark appearance,
    /// centred on `window` when given.
    static func make(title: String, size: NSSize, minimum: NSSize, undo: UndoManager, over window: NSWindow?) -> DraftPanel {
        // A standard titled panel rather than a HUD, which has no zoom
        // button; the zoom button widens it to the screen.
        let panel = DraftPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.draftUndoManager = undo
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = minimum
        panel.title = title
        if let frame = window?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        return panel
    }
}

/// The close button asks the editor, and the zoom button widens the panel
/// to the screen while keeping its height and place up and down.
final class DraftPanelDelegate: NSObject, NSWindowDelegate {
    var shouldClose: () -> Bool = { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { shouldClose() }
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let visible = window.screen?.visibleFrame ?? newFrame
        return NSRect(x: visible.minX, y: window.frame.minY, width: visible.width, height: window.frame.height)
    }
}

/// Drags on the panel's views belong to them, not to moving the panel, and
/// the first click goes through.
final class DraftPanelHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
