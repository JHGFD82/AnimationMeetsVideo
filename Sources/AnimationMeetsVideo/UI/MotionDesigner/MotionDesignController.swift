import AppKit
import CoreMedia
import Observation
import SwiftUI

/// Opens the motion designer on a selection of clips. While it is open the
/// editor is darkened and takes no input (`isActive`); clicking it brings
/// the panel back. The panel has its own undo, and each change it makes
/// reaches the project at once, so the timeline follows and the editor's
/// player plays it; the editor's history holds them back meanwhile.
/// **Done** keeps them, as one undo step, and **Cancel** (or closing the
/// panel) puts the clips back as they were, asking first if anything
/// changed. One run at a time.
///
/// Only the timing of the clips the panel changed is written, onto the
/// project as it is at the time, so an edit made elsewhere while it is
/// open (in a timeline window, or an import finishing) stays, whether the
/// run is kept or cancelled. Such an edit is held back with the panel's,
/// and recorded as a step of its own before the panel's when it closes.
@MainActor @Observable
final class MotionDesignController {
    private(set) var session: MotionDesignSession?
    var isActive: Bool { session != nil }

    /// Applies an edit to the project: one undo step, or while the panel
    /// is open, part of the session's.
    @ObservationIgnored var onEdit: ((inout EditingProject) -> Void) -> Void = { _ in }
    /// The editor's history, which records the whole session as one step.
    @ObservationIgnored var history: ProjectHistory?
    /// The editor's player, which the panel's monitor shows and plays.
    @ObservationIgnored var playback: PlaybackModel?
    /// Stops the editor's own playback, so only the panel plays.
    @ObservationIgnored var onOpen: () -> Void = {}
    /// The scene analysis of each video, which sets the footage a clip may
    /// reach: its scene.
    @ObservationIgnored var sceneTracks: () -> [UUID: ChangeScoreTrack] = { [:] }

    @ObservationIgnored private var presentation: DraftPanelPresentation?

    /// Opens the panel on the clips with these IDs, or says why it can't.
    func open(clips ids: Set<UUID>, in timelineID: UUID, of project: EditingProject) {
        if session != nil { bringToFront(); return }
        let editorWindow = NSApp.mainWindow ?? NSApp.keyWindow
        let run: MotionRun
        let tracks = sceneTracks()
        let footage = { (clip: TimelineClip) -> CMTimeRange? in
            guard case .media(let id) = clip.source else { return nil }
            return project.sceneFootage(of: clip, track: tracks[id])
        }
        switch MotionRun.opening(ids, in: timelineID, of: project, footage: footage) {
        case .success(let opened): run = opened
        case .failure(let error): return explain(error, ids: ids, in: timelineID, over: editorWindow)
        }
        onOpen()
        let session = MotionDesignSession(run: run, project: project, playback: playback ?? PlaybackModel())
        session.onDraftChange = { [weak self] write in self?.onEdit(write) }
        history?.beginGesture(quietly: true)
        self.session = session

        let names = run.pieces.compactMap { project.resolvedInfo(for: $0.clip.source)?.name }
        let title = names.count == 1 ? "Motion Designer: \(names[0])" : "Motion Designer: \(names.count) Clips"
        presentation = DraftPanelPresentation(
            title: title, size: NSSize(width: 1120, height: 560),
            minimum: NSSize(width: 860, height: 420), undo: session.undoManager, over: editorWindow,
            content: MotionDesignView(
                session: session,
                onDone: { [weak self] in self?.done() },
                onCancel: { [weak self] in self?.requestClose() }
            ),
            onClose: { [weak self] in self?.requestClose() }
        )
        presentation?.onQuit = { [weak self] in self?.closeForQuitting() ?? true }
    }

    /// Before the app quits, which would save the retiming already in the
    /// project: asks whether to keep it or put the clips back, and closes;
    /// false to stay open.
    private func closeForQuitting() -> Bool {
        guard let session, let presentation else { return true }
        guard session.isChanged else {
            tearDown()
            return true
        }
        presentation.bringToFront()
        let alert = NSAlert()
        alert.messageText = "Keep your retiming before quitting?"
        alert.informativeText = "The motion designer is still open. Discarding puts the clips back as they were before it opened."
        alert.addButton(withTitle: "Keep Retiming")
        alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: done()
        case .alertSecondButtonReturn: revertAndClose()
        default: return false
        }
        return true
    }

    /// Why a selection can't open, on the editor window; a selection across
    /// layers can be nested into one and opened.
    private func explain(_ error: MotionRun.OpenError, ids: Set<UUID>, in timelineID: UUID, over editorWindow: NSWindow?) {
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
        presentation?.bringToFront()
    }

    /// Keeps the changes, already in the project, and closes.
    func done() {
        tearDown()
    }

    /// Cancel and the close button: closes, asking first when the draft
    /// differs from the project.
    func requestClose() {
        guard let session, let presentation else { return }
        guard session.isChanged else { return tearDown() }
        presentation.askToDiscard(
            "Discard your retiming?",
            detail: "The clips go back to how they were before the motion designer opened."
        ) { [weak self] in self?.revertAndClose() }
    }

    /// Puts the clips back as they were when the panel opened, and closes.
    private func revertAndClose() {
        if let session { onEdit(session.writeOpened) }
        tearDown()
    }

    /// Closes without asking: the project has moved on without the clips.
    func discardAndClose() {
        tearDown()
    }

    /// Closes, recording what was changed while it was open: first what
    /// was edited elsewhere, as a step of its own, then the panel's
    /// retiming on top, so undoing the retiming keeps the other edits.
    private func tearDown() {
        if let history, let session, let current = history.current?() {
            var elsewhere = current
            session.writeOpened(into: &elsewhere)
            history.endGesture(elsewhere)
            history.projectDidChange(current)
        } else {
            history?.endGesture()
        }
        session?.end()
        session = nil
        presentation?.end()
        presentation = nil
    }
}
