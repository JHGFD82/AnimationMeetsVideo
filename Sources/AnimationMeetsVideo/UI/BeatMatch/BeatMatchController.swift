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
            onEdit { project in
                guard let index = project.clips.firstIndex(where: { $0.id == assetID }) else { return }
                project.clips[index].beatMap = map
            }
        }
        if map.hasConfirmedBeats {
            confirmation = Confirmation(assetID: assetID, serial: (confirmation?.serial ?? 0) + 1)
        }
        tearDown()
    }

    /// Removes a song's beat map from the project, as one undo step,
    /// without opening the panel: the timeline goes back to the detected
    /// beats.
    func removeBeats(assetID: UUID) {
        onEdit { project in
            guard let index = project.clips.firstIndex(where: { $0.id == assetID }) else { return }
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
