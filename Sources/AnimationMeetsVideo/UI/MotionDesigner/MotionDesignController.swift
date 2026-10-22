import AppKit
import Observation
import SwiftUI

/// Opens the motion designer on a selection of clips. While it is open the
/// editor is darkened and takes no input (`isActive`); clicking it brings
/// the panel back. The panel edits a draft with its own undo; **Done**
/// writes the clips that changed to the project as one undo step, and
/// **Cancel** (or closing the panel) leaves the project as it was, asking
/// first if anything changed. One run at a time.
@MainActor @Observable
final class MotionDesignController {
    private(set) var session: MotionDesignSession?
    var isActive: Bool { session != nil }

    /// Applies an edit to the project, as one undo step.
    @ObservationIgnored var onEdit: ((inout EditingProject) -> Void) -> Void = { _ in }
    /// Stops the editor's own playback, so only the panel plays.
    @ObservationIgnored var onOpen: () -> Void = {}

    @ObservationIgnored private var panel: DraftPanel?
    @ObservationIgnored private var panelDelegate: DraftPanelDelegate?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var editorWindow: NSWindow?

    /// Opens the panel on the clips with these IDs, or says why it can't.
    func open(clips ids: Set<UUID>, in timelineID: UUID, of project: EditingProject) {
        if session != nil { bringToFront(); return }
        editorWindow = NSApp.mainWindow ?? NSApp.keyWindow
        let run: MotionRun
        switch MotionRun.opening(ids, in: timelineID, of: project) {
        case .success(let opened): run = opened
        case .failure(let error): return explain(error, ids: ids, in: timelineID)
        }
        onOpen()
        let session = MotionDesignSession(run: run, project: project)
        self.session = session

        let names = run.pieces.compactMap { project.resolvedInfo(for: $0.clip.source)?.name }
        let title = names.count == 1 ? "Motion Designer: \(names[0])" : "Motion Designer: \(names.count) Clips"
        let panel = DraftPanel.make(
            title: title, size: NSSize(width: 1120, height: 560),
            minimum: NSSize(width: 860, height: 420), undo: session.undoManager, over: editorWindow
        )
        let host = DraftPanelHostingView(rootView: MotionDesignView(
            session: session,
            onDone: { [weak self] in self?.done() },
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

    /// Why a selection can't open, on the editor window; a selection across
    /// layers can be nested into one and opened.
    private func explain(_ error: MotionRun.OpenError, ids: Set<UUID>, in timelineID: UUID) {
        let alert = NSAlert()
        switch error {
        case .nothingSelected:
            return
        case .severalLayers:
            alert.messageText = "These clips are on different layers"
            alert.informativeText = "The motion designer retimes clips on one layer. Put them in a new timeline to design them together as one clip."
            alert.addButton(withTitle: "Put in New Timeline")
            alert.addButton(withTitle: "Cancel")
        case .musicLayer:
            alert.messageText = "Songs can't be retimed here"
            alert.informativeText = "The motion designer retimes footage to the music. Select clips on a video or sound layer."
            alert.addButton(withTitle: "OK")
        case .reversed:
            alert.messageText = "A clip plays backwards"
            alert.informativeText = "The motion designer works on clips that play forwards. Turn off Reverse in the clip's Time settings to design it."
            alert.addButton(withTitle: "OK")
        }
        let nest = { [weak self] in
            self?.onEdit { project in
                _ = project.nestClips(ids, in: timelineID, named: project.newNestedTimelineName())
            }
        }
        if let window = editorWindow {
            alert.beginSheetModal(for: window) { response in
                if error == .severalLayers, response == .alertFirstButtonReturn { MainActor.assumeIsolated { nest() } }
            }
        } else if alert.runModal() == .alertFirstButtonReturn, error == .severalLayers {
            nest()
        }
    }

    /// Closes the panel if a clip of the run is gone from the project.
    func update(project: EditingProject) {
        guard let session else { return }
        let present = Set(project.timeline(id: session.run.timelineID)?.layers.flatMap(\.clips).map(\.id) ?? [])
        if !session.run.pieces.allSatisfy({ present.contains($0.id) }) { discardAndClose() }
    }

    func bringToFront() {
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Writes the changed clips to the project, as one undo step, and closes.
    func done() {
        guard let session else { return }
        if session.isChanged {
            onEdit { project in session.write(into: &project) }
        }
        tearDown()
    }

    /// Cancel and the close button: closes, asking first when the draft
    /// differs from the project.
    func requestClose() {
        guard let session, let panel else { return }
        guard session.isChanged else { return tearDown() }
        let alert = NSAlert()
        alert.messageText = "Discard your retiming?"
        alert.informativeText = "Nothing you did in the motion designer reaches the timeline until you press Done."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        alert.beginSheetModal(for: panel) { [weak self] response in
            if response == .alertSecondButtonReturn {
                MainActor.assumeIsolated { self?.tearDown() }
            }
        }
    }

    /// Closes without asking: the project has moved on without the clips.
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
