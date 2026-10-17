import AppKit
import Observation
import SwiftUI

/// Opens the beat match panel for a song. While it is open the editor
/// window is darkened and takes no input (`isActive`); clicking it brings
/// the panel back to the front. The panel edits a draft with its own undo;
/// **Confirm** writes it to the project as one undo step and turns on that
/// song's beat markers in the timeline, while **Cancel** (or closing the
/// panel) leaves the project as it was, asking first if anything changed.
/// One song at a time.
@MainActor @Observable
final class BeatMatchController {
    private(set) var session: BeatMatchSession?
    var isActive: Bool { session != nil }

    /// The last song confirmed, for the timeline to show its beats. The
    /// serial tells two confirmations of the same song apart.
    struct Confirmation: Equatable {
        var assetID: UUID
        var serial: Int
    }
    private(set) var confirmation: Confirmation?

    /// Applies an edit to the project, as one undo step.
    @ObservationIgnored var onEdit: ((inout EditingProject) -> Void) -> Void = { _ in }
    /// Stops the editor's own playback, so only the song plays.
    @ObservationIgnored var onOpen: () -> Void = {}

    @ObservationIgnored private var panel: BeatMatchPanel?
    @ObservationIgnored private var panelDelegate: BeatMatchPanelDelegate?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var editorWindow: NSWindow?

    /// Opens the panel for an asset, or brings it to the front if it is
    /// open for that asset already. Nothing happens for an offline asset.
    func open(assetID: UUID, in project: EditingProject) {
        if let session, session.assetID == assetID {
            bringToFront()
            return
        }
        if session != nil { discardAndClose() }
        guard let asset = project.mediaClip(id: assetID), let url = asset.url, asset.hasAudio else { return }
        onOpen()
        let session = BeatMatchSession(asset: asset, url: url)
        self.session = session

        editorWindow = NSApp.mainWindow ?? NSApp.keyWindow
        // A standard titled panel rather than a HUD, which has no zoom
        // button; the zoom button widens it to the screen.
        let panel = BeatMatchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.draftUndoManager = session.undoManager
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = NSSize(width: 820, height: 340)
        panel.title = "Beat Match: \(asset.name)"
        let host = BeatMatchHostingView(rootView: BeatMatchView(
            session: session,
            onConfirm: { [weak self] in self?.confirm() },
            onCancel: { [weak self] in self?.requestClose() }
        ))
        // The panel's size is the person's; the view fills whatever it is.
        host.sizingOptions = [.minSize]
        panel.contentView = host
        let delegate = BeatMatchPanelDelegate()
        delegate.shouldClose = { [weak self] in
            self?.requestClose()
            return false
        }
        panel.delegate = delegate
        panelDelegate = delegate
        if let frame = editorWindow?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        // The editor takes no input meanwhile, so a click on it means the
        // person is looking for the panel.
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: editorWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bringToFront() }
            },
        ]
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel if the song is gone from the project.
    func update(project: EditingProject) {
        guard let session, project.mediaClip(id: session.assetID) == nil else { return }
        discardAndClose()
    }

    func bringToFront() {
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Writes the draft to the project, as one undo step, shows the song's
    /// beats on the timeline, and closes.
    func confirm() {
        guard let session else { return }
        let assetID = session.assetID, map = session.map
        if session.isChanged {
            onEdit { project in
                guard let index = project.clips.firstIndex(where: { $0.id == assetID }) else { return }
                project.clips[index].beatMap = map
            }
        }
        confirmation = Confirmation(assetID: assetID, serial: (confirmation?.serial ?? 0) + 1)
        tearDown()
    }

    /// Cancel and the close button: closes, asking first when the draft
    /// differs from the project.
    func requestClose() {
        guard let session, let panel else { return }
        guard session.isChanged else { return tearDown() }
        let alert = NSAlert()
        alert.messageText = "Discard your changes to this song's beats?"
        alert.informativeText = "Nothing you did in Beat Match reaches the timeline until you confirm it."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            if response == .alertSecondButtonReturn {
                MainActor.assumeIsolated { self?.tearDown() }
            }
        }
    }

    /// Closes without asking: the project has moved on without the song.
    func discardAndClose() {
        tearDown()
    }

    private func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        session?.end()
        session = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        panelDelegate = nil
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}

/// The close button asks the controller, and the zoom button widens the
/// panel to the screen while keeping its height and place up and down.
private final class BeatMatchPanelDelegate: NSObject, NSWindowDelegate {
    var shouldClose: () -> Bool = { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { shouldClose() }
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let visible = window.screen?.visibleFrame ?? newFrame
        return NSRect(x: visible.minX, y: window.frame.minY, width: visible.width, height: window.frame.height)
    }
}

/// Undo in the panel undoes the draft, not the project.
private final class BeatMatchPanel: NSPanel {
    weak var draftUndoManager: UndoManager?
    override var undoManager: UndoManager? { draftUndoManager ?? super.undoManager }
}

/// Drags on the waveform belong to it, not to moving the panel, and the
/// first click goes through.
private final class BeatMatchHostingView: NSHostingView<BeatMatchView> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
