import AppKit
import Observation
import SwiftUI

/// Opens the beat match panel for a song and keeps it in step with the
/// project. While it is open the editor window is darkened and takes no
/// input (`isActive`); clicking it brings the panel back to the front. The
/// panel's undo is the project's, so every beat match edit can be undone
/// there or after. One song at a time.
@MainActor @Observable
final class BeatMatchController {
    private(set) var session: BeatMatchSession?
    var isActive: Bool { session != nil }

    /// Applies an edit to the project, as one undo step.
    @ObservationIgnored var onEdit: ((inout EditingProject) -> Void) -> Void = { _ in }
    /// Stops the editor's own playback, so only the song plays.
    @ObservationIgnored var onOpen: () -> Void = {}

    @ObservationIgnored private var panel: BeatMatchPanel?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var editorWindow: NSWindow?

    /// Opens the panel for an asset, or brings it to the front if it is
    /// open for that asset already. Nothing happens for an offline asset.
    func open(assetID: UUID, in project: EditingProject) {
        if let session, session.assetID == assetID {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        close()
        guard let asset = project.mediaClip(id: assetID), let url = asset.url, asset.hasAudio else { return }
        onOpen()
        let session = BeatMatchSession(asset: asset, url: url)
        session.onEdit = { [weak self] change in
            self?.onEdit { project in
                guard let index = project.clips.firstIndex(where: { $0.id == assetID }) else { return }
                change(&project.clips[index].beatMap)
            }
        }
        self.session = session

        editorWindow = NSApp.mainWindow ?? NSApp.keyWindow
        let panel = BeatMatchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.editorUndoManager = editorWindow?.undoManager
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = NSSize(width: 820, height: 340)
        panel.title = "Beat Match: \(asset.name)"
        let host = BeatMatchHostingView(rootView: BeatMatchView(session: session) { [weak self] in self?.close() })
        // The panel's size is the person's; the view fills whatever it is.
        host.sizingOptions = [.minSize]
        panel.contentView = host
        if let frame = editorWindow?.frame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelClosed() }
            },
            // The editor takes no input meanwhile, so a click on it means
            // the person is looking for the panel.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: editorWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel?.makeKeyAndOrderFront(nil) }
            },
        ]
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// Keeps the panel's map current, and closes it if the asset is gone.
    func update(project: EditingProject) {
        guard let session else { return }
        guard let asset = project.mediaClip(id: session.assetID) else {
            close()
            return
        }
        session.mapChanged(asset.beatMap)
    }

    func bringToFront() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
        panelClosed()
    }

    private func panelClosed() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        session?.end()
        session = nil
        panel = nil
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Undo in the panel goes to the editor's history.
private final class BeatMatchPanel: NSPanel {
    weak var editorUndoManager: UndoManager?
    override var undoManager: UndoManager? { editorUndoManager ?? super.undoManager }
}

/// Drags on the waveform belong to it, not to moving the panel, and the
/// first click goes through.
private final class BeatMatchHostingView: NSHostingView<BeatMatchView> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
