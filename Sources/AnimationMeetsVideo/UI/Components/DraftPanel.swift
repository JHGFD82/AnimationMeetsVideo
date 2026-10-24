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

/// A draft editor's panel while it is open over the editor window. The
/// editor takes no input meanwhile, not even hovering, so a click on it,
/// or the editor becoming key, means the person is looking for the panel
/// and brings it back. The close button calls `onClose` and leaves the
/// panel open, for the editor to ask first or end it. Ending it closes
/// the panel and gives the editor back.
@MainActor
final class DraftPanelPresentation {
    let panel: DraftPanel
    private let delegate = DraftPanelDelegate()
    private var observers: [NSObjectProtocol] = []
    private weak var editorWindow: NSWindow?
    /// Keeps the pointer out of the editor while the panel is open.
    private var inputBlock: WindowInputBlock?

    init<Content: View>(
        title: String, size: NSSize, minimum: NSSize, undo: UndoManager,
        over editorWindow: NSWindow?, content: Content, onClose: @escaping () -> Void
    ) {
        self.editorWindow = editorWindow
        panel = DraftPanel.make(title: title, size: size, minimum: minimum, undo: undo, over: editorWindow)
        let host = DraftPanelHostingView(rootView: content)
        // The panel's size is the person's; the view fills whatever it is.
        host.sizingOptions = [.minSize]
        panel.contentView = host
        delegate.shouldClose = {
            onClose()
            return false
        }
        panel.delegate = delegate
        inputBlock = WindowInputBlock(window: editorWindow) { [weak self] in self?.bringToFront() }
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: editorWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bringToFront() }
            },
        ]
        panel.makeKeyAndOrderFront(nil)
    }

    func bringToFront() {
        panel.makeKeyAndOrderFront(nil)
    }

    /// Asks on the panel whether to throw away the draft's changes, and
    /// calls `discard` if so.
    func askToDiscard(_ question: String, detail: String, then discard: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        alert.beginSheetModal(for: panel) { response in
            if response == .alertSecondButtonReturn { MainActor.assumeIsolated { discard() } }
        }
    }

    /// Closes the panel and gives the editor its input back.
    func end() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        inputBlock?.end()
        inputBlock = nil
        panel.delegate = nil
        panel.close()
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}
