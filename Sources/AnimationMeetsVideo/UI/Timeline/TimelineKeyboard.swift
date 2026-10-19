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

    /// P, S, R and T show only position, scale, rotation or opacity (pressing
    /// the key again hides it); with Shift they add or remove that property
    /// and keep the others. They act on the selected clip's layer, or on
    /// every visual layer when nothing is selected.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let handled = handleNavigationKey(event, flags: flags) { return handled }
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
        return false
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
            nudge: { _ = nudgeSelection(byFrames: $0) },
            deleteSelection: { _ = deleteSelection() },
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
              let clip = timeline.layer(id: selection.layerID)?.clips.first(where: { $0.id == selection.timelineClipID })
        else {
            return false
        }
        let distance = CMTimeMultiply(timeline.frameDuration, multiplier: Int32(clamping: frames))
        onMoveClip(selection.layerID, clip.id, nil, CMTimeMaximum(.zero, CMTimeAdd(clip.startOffset, distance)))
        return true
    }

    /// Splits at the playhead: the selected clip when the playhead is in
    /// it, otherwise every clip the playhead is in, on every layer. False
    /// when it is in none.
    @discardableResult
    func splitAtPlayhead() -> Bool {
        let time = timeline.snappedToFrame(livePlayheadTime)
        func contains(_ clip: TimelineClip) -> Bool { time > clip.startOffset && time < clip.endOffset }
        var targets: [(layerID: UUID, clipID: UUID)] = []
        if let selection, selection.timelineID == timelineID,
           let clip = timeline.layer(id: selection.layerID)?.clips.first(where: { $0.id == selection.timelineClipID }),
           contains(clip) {
            targets = [(selection.layerID, clip.id)]
        } else {
            for layer in timeline.layers {
                for clip in layer.clips where contains(clip) { targets.append((layer.id, clip.id)) }
            }
        }
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
