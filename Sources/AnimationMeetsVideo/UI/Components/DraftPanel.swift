import AppKit
import SwiftUI

// The floating panel a draft editor works in, as Beat Match and the motion
// designer do: it undoes the draft rather than the project, its close
// button asks the editor, and drags inside it belong to its views.

extension View {
    /// Publishes an editor's menu commands, except while a draft panel
    /// (Beat Match or the motion designer) works over the editor: the
    /// menus would act on the project behind the panel, cutting clips the
    /// designer has open, or closing it. The commands rest meanwhile.
    func focusedSceneValueUnlessDrafting<Value>(_ key: WritableKeyPath<FocusedValues, Value?>, _ value: Value?) -> some View {
        modifier(RestsWhileDrafting(key: key, value: value))
    }
}

private struct RestsWhileDrafting<Value>: ViewModifier {
    let key: WritableKeyPath<FocusedValues, Value?>
    let value: Value?
    @Environment(BeatMatchController.self) private var beatMatch: BeatMatchController?
    @Environment(MotionDesignController.self) private var motionDesign: MotionDesignController?

    func body(content: Content) -> some View {
        let drafting = beatMatch?.isActive == true || motionDesign?.isActive == true
        content.focusedSceneValue(key, drafting ? nil : value)
    }
}

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
        Self.open.append(self)
        DragPress.watchPresses()
        panel.makeKeyAndOrderFront(nil)
    }

    func bringToFront() {
        panel.makeKeyAndOrderFront(nil)
    }

    /// Asks on the panel whether to throw away the draft's changes, and
    /// calls `discard` if so.
    func askToDiscard(_ question: String, detail: String, then discard: @escaping () -> Void) {
        let alert = Self.discardAlert(question, detail: detail)
        alert.beginSheetModal(for: panel) { response in
            if response == .alertSecondButtonReturn { MainActor.assumeIsolated { discard() } }
        }
    }

    /// Asks at once, with the panel in front, whether to throw away the
    /// draft's changes, for quitting, which can't wait on a sheet.
    func askToDiscardNow(_ question: String, detail: String) -> Bool {
        bringToFront()
        return Self.discardAlert(question, detail: detail).runModal() == .alertSecondButtonReturn
    }

    private static func discardAlert(_ question: String, detail: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        return alert
    }

    // MARK: Quitting

    /// The panels open now, in the order they opened.
    private static var open: [DraftPanelPresentation] = []
    /// Asked before the app quits: closes the panel, after asking whether
    /// to throw away its changes, and says whether quitting may go on.
    var onQuit: () -> Bool = { true }

    /// Asks each open panel before the app quits, so a draft isn't lost,
    /// or a retiming not yet kept saved, without a word. False when one
    /// is to stay open, which keeps the app open.
    static func confirmQuitting() -> Bool {
        for presentation in open where !presentation.onQuit() { return false }
        return true
    }

    /// Closes the panel and gives the editor its input back.
    func end() {
        Self.open.removeAll { $0 === self }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        inputBlock?.end()
        inputBlock = nil
        panel.delegate = nil
        panel.close()
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Which press of the mouse button a drag in a draft panel follows. A
/// sheet opened over the panel mid-drag (Cancel's question, say) takes
/// the button's release, so the drag's end is never heard: its state
/// stayed live, and the next click on the view carried the old drag on.
/// A drag let go when a sheet opens (`abandon`) ignores the rest of its
/// press, and any change from a press since the last one heard starts
/// afresh (`begins`), whether or not the end of the last was heard.
struct DragPress {
    /// Presses of the left button in the app, counted before they reach
    /// any view, once a draft panel has opened.
    @MainActor private(set) static var count = 0
    @MainActor private static var monitor: Any?

    @MainActor static func watchPresses() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated { count += 1 }
            return event
        }
    }

    private var press: Int?
    /// Whether the press under way was let go of, and is ignored.
    private(set) var isAbandoned = false
    /// Where the press began, in the view's coordinates.
    private(set) var origin: CGPoint = .zero

    /// At each change of a drag: true for the first change of a press,
    /// with `origin` set to where it began. A press after one whose end
    /// went unheard may reach the gesture as a change of the old one;
    /// its origin is then where the pointer is now.
    @MainActor mutating func begins(_ value: DragGesture.Value) -> Bool {
        if let press, press == Self.count { return false }
        origin = press == nil ? value.startLocation : value.location
        press = Self.count
        isAbandoned = false
        return true
    }

    /// How far the pointer is from where the press began.
    func translation(_ value: DragGesture.Value) -> CGSize {
        CGSize(width: value.location.x - origin.x, height: value.location.y - origin.y)
    }

    /// Lets go of the press under way: the rest of it is ignored.
    mutating func abandon() {
        isAbandoned = true
    }

    /// The press ended, and was heard to.
    mutating func end() {
        press = nil
        isAbandoned = false
    }
}

extension View {
    /// Runs `action` when a sheet is about to open over a draft panel,
    /// which will take the release of a drag under way there.
    func onDraftPanelSheet(perform action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: NSWindow.willBeginSheetNotification)) { note in
            if note.object is DraftPanel { action() }
        }
    }
}

extension NSEvent {
    /// Whether a control with the keyboard focus in the event's window
    /// takes this key itself, so a draft panel's keys leave it alone: the
    /// arrows for a slider, stepper, pop-up or segmented control, and
    /// Space for a button, pop-up, checkbox or segmented control (most of
    /// which have the focus only with keyboard navigation on). Space on a
    /// slider or stepper does nothing of its own, so it still plays.
    @MainActor var isForFocusedControl: Bool {
        guard let responder = window?.firstResponder else { return false }
        switch keyCode {
        case 123, 124, 125, 126:
            return responder is NSSlider || responder is NSStepper || responder is NSPopUpButton || responder is NSSegmentedControl
        case 49:
            return responder is NSButton || responder is NSSegmentedControl
        default:
            return false
        }
    }
}
