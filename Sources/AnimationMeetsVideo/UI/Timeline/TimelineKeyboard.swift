import AppKit
import CoreMedia
import SwiftUI

// Keys, the Timeline menu and deleting what is selected in a timeline.
extension TimelineView {
    /// Delete removes the selected layer, else the selected transition,
    /// else the selected clip.
    func deleteSelection() -> Bool {
        // The effects panel has the key while it is the active panel and
        // something in it is selected.
        if activePanel?.current == .sidePanel, showsEffects, effectsState.hasSelection { return false }
        if !groupSelection.isEmpty {
            deleteGroup()
            return true
        }
        if let selectedSectionID, timeline.sections.contains(where: { $0.id == selectedSectionID }) {
            onEditProject { $0.deleteSection(selectedSectionID, in: timelineID) }
            self.selectedSectionID = nil
            return true
        }
        if let selectedLayerID, timeline.layer(id: selectedLayerID) != nil {
            deleteLayer(selectedLayerID)
            return true
        }
        guard let selection, selection.timelineID == timelineID else { return false }
        if let edge = selection.transitionEdge {
            onRemoveTransition(selection.layerID, selection.timelineClipID, edge)
        } else {
            onDeleteClip(selection.layerID, selection.timelineClipID)
        }
        return true
    }

    /// The timeline's keys, listed in docs/accessibility.md. L shows or
    /// hides volume rows, on the selected clip's layer or on every layer
    /// with sound when nothing is selected.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let handled = handleNavigationKey(event, flags: flags) { return handled }
        // With the browser active, Escape, Command-A and Delete are its
        // own: they stop its skimming and remove its media, and must not
        // reach the timeline's selection, greyed out behind it.
        if activePanel?.current == .browser,
           [53, 51, 117].contains(event.keyCode) || (event.keyCode == 0 && flags == .command) {
            return false
        }
        // Escape lets go of whatever is selected.
        if event.keyCode == 53, flags.isEmpty, !ValueDragSession.isActive, hasAnythingSelected {
            clearSelection()
            return true
        }
        // Command-A picks every clip together.
        if event.keyCode == 0, flags == .command { return selectAllClips() }
        // Delete and Forward Delete, without modifiers.
        if [51, 117].contains(event.keyCode), flags.isDisjoint(with: [.command, .control, .option, .shift]) {
            return deleteSelection()
        }
        // F9 eases, as in After Effects: Easy Ease, Shift for Ease In,
        // Command-Shift for Ease Out.
        if event.keyCode == 101, flags.isDisjoint(with: [.control, .option]) {
            let preset: KeyframeEase.Preset = flags.contains(.shift)
                ? (flags.contains(.command) ? .easeOut : .easeIn)
                : .easyEase
            return easeKeyframesAtPlayhead(preset)
        }
        // Control-Option-H holds, as After Effects' Toggle Hold Keyframe.
        if event.keyCode == 4, flags == [.control, .option] {
            return easeKeyframesAtPlayhead(.hold)
        }
        guard flags.isDisjoint(with: [.command, .control, .option]),
              let key = event.charactersIgnoringModifiers?.lowercased().first
        else {
            return false
        }
        switch key {
        // Shift turns , and . into < and >: ten frames.
        case ",": return nudgeSelection(byFrames: -1)
        case ".": return nudgeSelection(byFrames: 1)
        case "<": return nudgeSelection(byFrames: -10)
        case ">": return nudgeSelection(byFrames: 10)
        case "=", "+": zoomAroundPlayhead(by: zoomStep); return true
        case "-": zoomAroundPlayhead(by: 1 / zoomStep); return true
        case "\\": fitToWindow(); return true
        default: break
        }
        if key == "e", flags == .shift {
            setShowsEffects(!showsEffects)
            return true
        }
        if key == "n", !flags.contains(.shift) {
            snapping.toggle()
            return true
        }
        if let chosen = TimelineTool(shortcutKey: key), !flags.contains(.shift) {
            tool = chosen
            return true
        }
        if key == "l" { return toggleVolumeRows() }
        if key == "v", !flags.contains(.shift) { return toggleSelectedClipsEnabled() }
        // Shift-F, as Final Cut's Reveal in Browser.
        if key == "f", flags == .shift { return showSelectedClipInBrowser() }
        return false
    }

    /// Picks the selected clip's footage in the browser's Clips tab. False
    /// without a clip of media selected.
    func showSelectedClipInBrowser() -> Bool {
        guard let selection, selection.timelineID == timelineID,
              let piece = timeline.layer(id: selection.layerID)?.clips.first(where: { $0.id == selection.timelineClipID })?.footagePiece
        else { return false }
        NotificationCenter.default.post(name: .revealInBrowser, object: piece)
        return true
    }

    /// Turns the selected clips off, or on again when all of them are off:
    /// the clips picked together, else the selected clip. False with none.
    @discardableResult
    func toggleSelectedClipsEnabled() -> Bool {
        var ids = groupSelection
        if ids.isEmpty, let selection, selection.timelineID == timelineID { ids = [selection.timelineClipID] }
        guard !ids.isEmpty else { return false }
        var changed = false
        onEditProject { changed = $0.toggleEnabled(ofClips: ids, in: timelineID) }
        return changed
    }

    // MARK: - Playhead keys and the Timeline menu

    /// What the Timeline menu does in this timeline. See `TimelineCommands`.
    var actions: TimelineActions {
        TimelineActions(
            togglePlayback: { playback.togglePlayback() },
            step: { stepPlayhead(byFrames: $0) },
            goToStart: { parkPlayhead(at: .zero) },
            goToEnd: { parkPlayhead(at: timeline.duration) },
            previousEdit: { _ = jumpToEdit(forward: false) },
            nextEdit: { _ = jumpToEdit(forward: true) },
            splitAtPlayhead: { _ = splitAtPlayhead() },
            splitAllAtPlayhead: { _ = splitAtPlayhead(everyClip: true) },
            nudge: { _ = nudgeSelection(byFrames: $0) },
            deleteSelection: { _ = deleteSelection() },
            toggleEnabled: { toggleSelectedClipsEnabled() },
            isSnapping: snapping,
            toggleSnapping: { snapping.toggle() },
            tool: tool,
            setTool: { tool = $0 },
            zoomIn: { zoomAroundPlayhead(by: zoomStep) },
            zoomOut: { zoomAroundPlayhead(by: 1 / zoomStep) },
            zoomToFit: { fitToWindow() },
            renderNow: renderer.flatMap { renderer in renderer.canRenderNow ? { renderer.renderNow() } : nil },
            timelineID: timelineID,
            structure: project.structure
        )
    }

    /// ← and → step a frame (ten with Shift), ↑ and ↓ go to the previous or
    /// next edit, Home and End to the start and end. Nil for other keys.
    /// False, leaving the key alone, while a list or other control has the
    /// keyboard, since it uses these keys itself.
    func handleNavigationKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool? {
        let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        let home: UInt16 = 115, end: UInt16 = 119
        guard [left, right, down, up, home, end].contains(event.keyCode),
              flags.isDisjoint(with: [.command, .control, .option])
        else {
            return nil
        }
        guard !(event.window?.firstResponder is NSControl) else { return false }
        let frames = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case left: stepPlayhead(byFrames: -frames)
        case right: stepPlayhead(byFrames: frames)
        case up: return jumpToEdit(forward: false)
        case down: return jumpToEdit(forward: true)
        case home: parkPlayhead(at: .zero)
        default: parkPlayhead(at: timeline.duration)
        }
        return true
    }

    /// Pauses and puts the playhead at `time`, on a frame within the
    /// timeline.
    func parkPlayhead(at time: CMTime) {
        playback.player.pause()
        let parked = timeline.snappedToFrame(CMTimeMinimum(CMTimeMaximum(.zero, time), timeline.duration))
        onScrub(parked)
        reveal(parked)
    }

    /// Pauses and moves the playhead `frames` frames, back when negative.
    func stepPlayhead(byFrames frames: Int) {
        let from = timeline.snappedToFrame(livePlayheadTime)
        parkPlayhead(at: CMTimeAdd(from, CMTimeMultiply(timeline.frameDuration, multiplier: Int32(clamping: frames))))
    }

    /// Moves the playhead to the nearest clip edge (or the timeline's end)
    /// after it, or before it. False when there is none that way.
    @discardableResult
    func jumpToEdit(forward: Bool) -> Bool {
        let now = timeline.snappedToFrame(livePlayheadTime)
        let edges = timeline.layers.flatMap { $0.clips.flatMap { [$0.startOffset, $0.endOffset] } } + [timeline.duration]
        let frames = edges.map { timeline.snappedToFrame($0) }
        guard let target = forward ? frames.filter({ $0 > now }).min() : frames.filter({ $0 < now }).max() else {
            return false
        }
        parkPlayhead(at: target)
        return true
    }

    /// Moves the selected clip `frames` frames, later when positive, by the
    /// same rules as dragging it. False with no clip selected.
    @discardableResult
    func nudgeSelection(byFrames frames: Int) -> Bool {
        guard let selection, selection.timelineID == timelineID,
              let clip = timeline.layer(id: selection.layerID)?.clips.first(id: selection.timelineClipID)
        else {
            return false
        }
        let distance = CMTimeMultiply(timeline.frameDuration, multiplier: Int32(clamping: frames))
        onMoveClip(selection.layerID, clip.id, nil, CMTimeMaximum(.zero, CMTimeAdd(clip.startOffset, distance)))
        return true
    }

    /// Splits at the playhead, as Final Cut's Blade (⌘B) and Blade All
    /// (⇧⌘B): the selected clips the playhead is in (the clip selected, or
    /// those picked together), or with nothing selected, or `everyClip`,
    /// every clip the playhead is in, on every layer. Always at the
    /// playhead, never at the skimmer. False when it splits none.
    @discardableResult
    func splitAtPlayhead(everyClip: Bool = false) -> Bool {
        let time = timeline.snappedToFrame(livePlayheadTime)
        var chosen = groupSelection
        if chosen.isEmpty, let selection, selection.timelineID == timelineID { chosen = [selection.timelineClipID] }
        let targets = timeline.clipsToSplit(at: time, selected: chosen, everyClip: everyClip)
        for target in targets { onBladeClip(target.layerID, target.clipID, time) }
        return !targets.isEmpty
    }

    /// Eases the keyframes at the playhead in the property rows that are
    /// showing, under the selected clip's layer or under every layer when
    /// nothing is selected. False when there are none.
    func easeKeyframesAtPlayhead(_ preset: KeyframeEase.Preset) -> Bool {
        let time = timeline.snappedToFrame(playheadTime)
        let layers: [TimelineLayer]
        if let selection, selection.timelineID == timelineID, let layer = timeline.layer(id: selection.layerID) {
            layers = [layer]
        } else {
            layers = timeline.layers
        }
        var eased = false
        // With the effects panel open, the selected clip's controls count.
        if showsEffects, let selection, selection.timelineID == timelineID,
           let clip = project.clipAndLayer(selection.timelineClipID, in: timelineID)?.clip {
            var copy = clip
            if copy.easeKeyframes(atTimelineTime: time, preset) {
                onEditProject { $0.editClip(clip.id, in: timelineID) { $0 = copy } }
                eased = true
            }
        }
        for layer in layers {
            if showsVolume(of: layer), layer.volume.keyframe(at: time) != nil {
                onEditVolume(layer.id) { $0.applyEase(preset, at: time) }
                eased = true
            }
        }
        return eased
    }

    /// L shows volume, as levels in After Effects (pressing it again hides
    /// it): each clip's as a line across it, and a Sound or Music layer's as
    /// a row under it. Acts on the selected clip's layer, or on every layer
    /// with sound when nothing is selected.
    func toggleVolumeRows() -> Bool {
        let targets: [TimelineLayer]
        if let selection, selection.timelineID == timelineID, let layer = timeline.layer(id: selection.layerID) {
            targets = project.layerPlaysAudio(layer) ? [layer] : []
        } else {
            targets = timeline.layers.filter { project.layerPlaysAudio($0) }
        }
        guard !targets.isEmpty else { return false }
        let hiding = targets.allSatisfy { volumeRevealed.contains($0.id) }
        for layer in targets {
            if hiding { volumeRevealed.remove(layer.id) } else { volumeRevealed.insert(layer.id) }
        }
        return true
    }
}
