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

    @ObservationIgnored private var presentation: DraftPanelPresentation?

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

        presentation = DraftPanelPresentation(
            title: "Beat Match: \(asset.name)", size: NSSize(width: 1060, height: 480),
            minimum: NSSize(width: 820, height: 340), undo: session.undoManager,
            over: NSApp.mainWindow ?? NSApp.keyWindow,
            content: BeatMatchView(
                session: session,
                onConfirm: { [weak self] in self?.confirm() },
                onCancel: { [weak self] in self?.requestClose() }
            ),
            onClose: { [weak self] in self?.requestClose() }
        )
        presentation?.onQuit = { [weak self] in self?.closeForQuitting() ?? true }
        presentation?.onHide = { [weak session] in session?.player.pause() }
    }

    /// Before the app quits: closes, asking first when the draft differs
    /// from the project; false to stay open.
    private func closeForQuitting() -> Bool {
        guard let session, let presentation else { return true }
        if session.isChanged, !presentation.askToDiscardNow(
            "Quit and discard your changes to this song's beats?",
            detail: "Nothing you did in Beat Match reaches the timeline until you confirm it."
        ) { return false }
        tearDown()
        return true
    }

    /// Closes the panel if the song is gone from the project.
    func update(project: EditingProject) {
        guard let session, project.mediaClip(id: session.assetID) == nil else { return }
        discardAndClose()
    }

    func bringToFront() {
        presentation?.bringToFront()
    }

    /// Writes the draft to the project, as one undo step, shows the song's
    /// beats on the timeline, and closes. A draft emptied by Start Over
    /// removes the song's beats instead (the panel's Remove Beats).
    func confirm() {
        guard let session else { return }
        let assetID = session.assetID
        let map = session.map.isEmpty ? BeatMap() : session.map
        if session.isChanged {
            // The song's beats changed elsewhere while the panel was open
            // (a script, another window of the project, the file on disk):
            // asked first, rather than written over, which the draft, made
            // from the map as it was, did.
            var changedMeanwhile = false
            onEdit { project in
                changedMeanwhile = !Self.write(map, over: session.original, assetID: assetID, in: &project)
            }
            if changedMeanwhile {
                guard confirmReplacingChangedBeats(session.assetName) else { return }
                onEdit { project in
                    guard let index = project.clips.firstIndex(id: assetID) else { return }
                    project.clips[index].beatMap = map
                }
            }
        }
        if map.hasConfirmedBeats {
            confirmation = Confirmation(assetID: assetID, serial: (confirmation?.serial ?? 0) + 1)
        }
        tearDown()
    }

    /// Writes `map` as the song's beat map if the song still has
    /// `original`, the map the panel opened on; returns false, changing
    /// nothing, when it has another.
    static func write(_ map: BeatMap, over original: BeatMap, assetID: UUID, in project: inout EditingProject) -> Bool {
        guard let index = project.clips.firstIndex(id: assetID) else { return true }
        guard project.clips[index].beatMap == original else { return false }
        project.clips[index].beatMap = map
        return true
    }

    /// Asks whether to replace beats changed elsewhere while the panel was
    /// open; settable so tests can answer.
    @ObservationIgnored var confirmReplacingChangedBeats: (String) -> Bool = { name in
        let alert = NSAlert()
        alert.messageText = "The Beats of \u{201C}\(name)\u{201D} Changed Meanwhile"
        alert.informativeText = "While the panel was open, the song\u{2019}s beats were changed elsewhere (by a script, in another window, or in the project file). Confirming replaces those changes with the panel\u{2019}s."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Replace Them")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Removes a song's beat map from the project, as one undo step,
    /// without opening the panel: the timeline goes back to the detected
    /// beats.
    func removeBeats(assetID: UUID) {
        onEdit { project in
            guard let index = project.clips.firstIndex(id: assetID) else { return }
            project.clips[index].beatMap = BeatMap()
        }
    }

    /// Cancel and the close button: closes, asking first when the draft
    /// differs from the project.
    func requestClose() {
        guard let session, let presentation else { return }
        guard session.isChanged else { return tearDown() }
        presentation.askToDiscard(
            "Discard your changes to this song's beats?",
            detail: "Nothing you did in Beat Match reaches the timeline until you confirm it."
        ) { [weak self] in self?.tearDown() }
    }

    /// Closes without asking: the project has moved on without the song.
    func discardAndClose() {
        tearDown()
    }

    private func tearDown() {
        session?.end()
        session = nil
        presentation?.end()
        presentation = nil
    }
}
