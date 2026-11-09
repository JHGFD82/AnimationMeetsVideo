import CoreMedia
import SwiftUI

/// What the Edit menu and a clip's context menu do with a clip.
enum ClipboardCommand {
    case cut, copy, paste, duplicate
    /// Takes the clip, or the clips picked with it, into a timeline of
    /// their own, which stands in their place.
    case nest
    /// Deletes the clip, or the clips picked with it, without copying.
    case delete
}

// Cutting, copying, pasting and duplicating clips (see docs/timeline.md,
// "Copy, paste and duplicate").
extension TimelineView {
    /// The selected clip in this timeline, unless one of its transitions
    /// is selected instead.
    private var selectedClip: (layerID: UUID, clipID: UUID)? {
        guard let selection, selection.timelineID == timelineID, selection.transitionEdge == nil else { return nil }
        return (selection.layerID, selection.timelineClipID)
    }

    /// What the Edit menu does in this timeline. See `EditCommands`.
    var editActions: EditMenuActions {
        let clip = selectedClip
        let picked = !groupSelection.isEmpty
        let canPaste = EditorClipboard.shared.clip.map { project.canPaste($0, into: timelineID) }
            ?? EditorClipboard.shared.group.map { project.canPaste($0, into: timelineID) } ?? false
        let hasSelection = selection?.timelineID == timelineID || selectedLayerID != nil || selectedSectionID != nil || picked
        let onClip = { (command: ClipboardCommand) -> (() -> Void)? in
            if picked { return { groupClipboard(command) } }
            return clip.map { clip in { clipboard(command, layerID: clip.layerID, clipID: clip.clipID) } }
        }
        // Clips open in the motion designer can't be changed: what would
        // change one isn't offered (Copy still is).
        let ids = picked ? groupSelection : Set(clip.map { [$0.clipID] } ?? [])
        let changesLocked = !ids.isDisjoint(with: lockedClipIDs)
        let pasteLeavesLocked = canPaste && leavesLockedClips { project in
            if let group = EditorClipboard.shared.group {
                _ = project.paste(group, in: timelineID, at: playheadTime)
            } else if let bundle = EditorClipboard.shared.clip {
                _ = project.paste(bundle, in: timelineID, onto: clip?.layerID ?? selectedLayerID, at: playheadTime)
            }
        }
        let duplicateLeavesLocked = !changesLocked && leavesLockedClips { project in
            if picked { _ = project.duplicateClips(groupSelection, in: timelineID) }
            else if let clip { _ = project.duplicateClip(clip.clipID, in: timelineID) }
        }
        // A selected layer may hold one too (`menuSelection`).
        let canDelete = hasSelection && !changesLocked && (lockedClipIDs.isEmpty || menuSelection.canDelete)
        return EditMenuActions(
            cut: changesLocked ? nil : onClip(.cut),
            copy: onClip(.copy),
            paste: pasteLeavesLocked ? { clipboard(.paste, layerID: clip?.layerID ?? selectedLayerID, clipID: nil) } : nil,
            duplicate: duplicateLeavesLocked ? onClip(.duplicate) : nil,
            delete: canDelete ? { _ = deleteSelection() } : nil,
            state: [timelineID, clip?.clipID, selectedLayerID, selectedSectionID, hasSelection, canPaste, groupSelection,
                    changesLocked, pasteLeavesLocked, duplicateLeavesLocked, canDelete] as [AnyHashable?]
        )
    }

    /// Clips open in the motion designer, which nothing here may change.
    var lockedClipIDs: Set<UUID> { projectState?.lockedClipIDs ?? [] }

    /// Whether `edit` would leave the clips open in the motion designer
    /// alone, tried on a copy of the project; true with none open.
    private func leavesLockedClips(_ edit: (inout EditingProject) -> Void) -> Bool {
        guard let projectState, !projectState.lockedClipIDs.isEmpty else { return true }
        var trial = project
        edit(&trial)
        return projectState.allows(trial)
    }

    /// An Option-drag of a clip: a copy lands where the drag would have
    /// moved it, onto `target` or its own layer, or onto a new layer of
    /// `kind`, and is selected. The clip itself stays.
    func copyClip(_ clipID: UUID, from layerID: UUID, to start: CMTime, onto target: UUID?, newLayer kind: LayerKind?) {
        var placed: (layerID: UUID, clip: TimelineClip)?
        host.dispatch(.editProject { project in
            guard let bundle = project.clipBundle(clipID, in: timelineID) else { return }
            let pasted = if let kind {
                project.paste(bundle, in: timelineID, newLayer: kind, at: start)
            } else {
                project.paste(bundle, in: timelineID, onto: target ?? layerID, at: start)
            }
            guard let pasted, let clip = project.clipAndLayer(pasted.clipID, in: timelineID)?.clip else { return }
            placed = (pasted.layerID, clip)
        })
        if let placed { host.dispatch(.selectClip(layer: placed.layerID, clip: placed.clip)) }
    }

    /// Cuts, copies or duplicates a clip, or pastes the copied clip at the
    /// playhead, onto `layerID` when that layer takes it. A pasted or
    /// duplicated clip is selected, and a paste leaves the playhead at its
    /// end, so pasting again puts the next copy after it.
    func clipboard(_ command: ClipboardCommand, layerID: UUID?, clipID: UUID?) {
        // Several clips copied together paste together; a command on one of
        // several picked together is on all of them.
        if command == .paste, EditorClipboard.shared.group != nil { return pasteGroup() }
        if command != .paste, let clipID, groupSelection.contains(clipID) { return groupClipboard(command) }
        switch command {
        case .copy, .cut:
            let project = host.readProject()
            guard let layerID, let clipID, let bundle = project.clipBundle(clipID, in: timelineID) else { return }
            EditorClipboard.shared.copy(clip: bundle, effects: project.bundle(ofEffects: nil, fromClip: clipID, in: timelineID))
            if command == .cut { host.dispatch(.deleteClip(layer: layerID, clip: clipID)) }
        case .paste:
            guard let bundle = EditorClipboard.shared.clip else { return }
            var placed: (layerID: UUID, clip: TimelineClip)?
            host.dispatch(.editProject { project in
                guard let pasted = project.paste(bundle, in: timelineID, onto: layerID, at: playheadTime),
                      let clip = project.clipAndLayer(pasted.clipID, in: timelineID)?.clip
                else { return }
                placed = (pasted.layerID, clip)
            })
            guard let placed else { return NSSound.beep() }
            host.dispatch(.selectClip(layer: placed.layerID, clip: placed.clip))
            parkPlayhead(at: placed.clip.endOffset)
        case .nest:
            if let clipID { nest([clipID]) }
        case .delete:
            guard let layerID, let clipID else { return }
            host.dispatch(.deleteClip(layer: layerID, clip: clipID))
        case .duplicate:
            guard let layerID, let clipID else { return }
            var copy: TimelineClip?
            host.dispatch(.editProject { project in
                copy = project.duplicateClip(clipID, in: timelineID).flatMap { project.clipAndLayer($0, in: timelineID)?.clip }
            })
            if let copy { host.dispatch(.selectClip(layer: layerID, clip: copy)) }
        }
    }
}
