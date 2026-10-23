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

    @ObservationIgnored private var panel: DraftPanel?
    @ObservationIgnored private var panelDelegate: DraftPanelDelegate?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var editorWindow: NSWindow?
    /// Keeps the pointer out of the editor while the panel is open.
    @ObservationIgnored private var inputBlock: WindowInputBlock?

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
        let panel = DraftPanel.make(
            title: "Beat Match: \(asset.name)", size: NSSize(width: 1060, height: 480),
            minimum: NSSize(width: 820, height: 340), undo: session.undoManager, over: editorWindow
        )
        let host = DraftPanelHostingView(rootView: BeatMatchView(
            session: session,
            onConfirm: { [weak self] in self?.confirm() },
            onCancel: { [weak self] in self?.requestClose() }
        ))
        // The panel's size is the person's; the view fills whatever it is.
        host.sizingOptions = [.minSize]
        panel.contentView = host
        let delegate = DraftPanelDelegate()
        delegate.shouldClose = { [weak self] in
            self?.requestClose()
            return false
        }
        panel.delegate = delegate
        panelDelegate = delegate
        // The editor takes no input meanwhile, not even hovering, so a
        // click on it means the person is looking for the panel.
        inputBlock = WindowInputBlock(window: editorWindow) { [weak self] in self?.bringToFront() }
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
        inputBlock?.end()
        inputBlock = nil
        session?.end()
        session = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        panelDelegate = nil
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}
