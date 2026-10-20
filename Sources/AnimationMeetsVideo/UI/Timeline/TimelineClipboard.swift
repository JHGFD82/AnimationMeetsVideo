import CoreMedia
import SwiftUI

/// What the Edit menu and a clip's context menu do with a clip.
enum ClipboardCommand {
    case cut, copy, paste, duplicate
    /// Takes the clip, or the clips picked with it, into a timeline of
    /// their own, which stands in their place.
    case nest
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
        return EditMenuActions(
            cut: onClip(.cut),
            copy: onClip(.copy),
            paste: canPaste ? { clipboard(.paste, layerID: clip?.layerID ?? selectedLayerID, clipID: nil) } : nil,
            duplicate: onClip(.duplicate),
            delete: hasSelection ? { _ = deleteSelection() } : nil,
            state: [timelineID, clip?.clipID, selectedLayerID, selectedSectionID, hasSelection, canPaste, groupSelection] as [AnyHashable?]
        )
    }

    /// An Option-drag of a clip: a copy lands where the drag would have
    /// moved it, onto `target` or its own layer, or onto a new layer of
    /// `kind`, and is selected. The clip itself stays.
    func copyClip(_ clipID: UUID, from layerID: UUID, to start: CMTime, onto target: UUID?, newLayer kind: LayerKind?) {
        var placed: (layerID: UUID, clip: TimelineClip)?
        onEditProject { project in
            guard let bundle = project.clipBundle(clipID, in: timelineID) else { return }
            let pasted = if let kind {
                project.paste(bundle, in: timelineID, newLayer: kind, at: start)
            } else {
                project.paste(bundle, in: timelineID, onto: target ?? layerID, at: start)
            }
            guard let pasted, let clip = project.clipAndLayer(pasted.clipID, in: timelineID)?.clip else { return }
            placed = (pasted.layerID, clip)
        }
        if let placed { onSelectClip(placed.layerID, placed.clip) }
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
            let project = readProject()
            guard let layerID, let clipID, let bundle = project.clipBundle(clipID, in: timelineID) else { return }
            EditorClipboard.shared.copy(clip: bundle, effects: project.bundle(ofEffects: nil, fromClip: clipID, in: timelineID))
            if command == .cut { onDeleteClip(layerID, clipID) }
        case .paste:
            guard let bundle = EditorClipboard.shared.clip else { return }
            var placed: (layerID: UUID, clip: TimelineClip)?
            onEditProject { project in
                guard let pasted = project.paste(bundle, in: timelineID, onto: layerID, at: playheadTime),
                      let clip = project.clipAndLayer(pasted.clipID, in: timelineID)?.clip
                else { return }
                placed = (pasted.layerID, clip)
            }
            guard let placed else { return NSSound.beep() }
            onSelectClip(placed.layerID, placed.clip)
            parkPlayhead(at: placed.clip.endOffset)
        case .nest:
            if let clipID { nest([clipID]) }
        case .duplicate:
            guard let layerID, let clipID else { return }
            var copy: TimelineClip?
            onEditProject { project in
                copy = project.duplicateClip(clipID, in: timelineID).flatMap { project.clipAndLayer($0, in: timelineID)?.clip }
            }
            if let copy { onSelectClip(layerID, copy) }
        }
    }
}
