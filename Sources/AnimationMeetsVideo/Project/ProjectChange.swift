import Foundation

/// Names an edit for the Edit menu ("Undo Split Clip") by comparing the
/// project before and after it, as `ProjectHistory` finds edits: no call
/// site has to say what it did, so a new kind of edit still gets a name,
/// if only a general one.
///
/// The name also tells edits apart: quick changes merge into one undo step
/// only while they have the same name, so a split followed at once by a
/// nudge stays two steps, while a slider dragged by its arrow keys is one.
enum ProjectChange {
    /// What the change from `before` to `after` did, or nil when nothing
    /// that has a name changed.
    static func name(from before: EditingProject, to after: EditingProject) -> String? {
        if before.timelines != after.timelines {
            return timelinesChange(before.timelines, after.timelines)
        }
        if before.clips != after.clips {
            return mediaChange(before.clips, after.clips)
        }
        if before.name != after.name { return "Rename Project" }
        if before != after { return "Change Project Settings" }
        return nil
    }

    private static func timelinesChange(_ before: [Timeline], _ after: [Timeline]) -> String {
        let beforeIDs = Set(before.map(\.id))
        let afterIDs = Set(after.map(\.id))
        if afterIDs.isStrictSuperset(of: beforeIDs) { return "New Timeline" }
        if afterIDs.isStrictSubset(of: beforeIDs) { return "Delete Timeline" }
        guard beforeIDs == afterIDs else { return "Edit Timelines" }
        let changed = after.filter { timeline in before.first { $0.id == timeline.id } != timeline }
        // A change reaching into several timelines at once, such as putting
        // clips in a new nested timeline, is named by the first.
        guard let new = changed.first, let old = before.first(where: { $0.id == new.id }) else { return "Reorder Timelines" }
        return timelineChange(old, new)
    }

    private static func timelineChange(_ old: Timeline, _ new: Timeline) -> String {
        if old.name != new.name { return "Rename Timeline" }
        if old.frameSize != new.frameSize || old.frameRate != new.frameRate || old.colorSpace != new.colorSpace {
            return "Change Timeline Settings"
        }
        let oldClips = clipsByID(old)
        let newClips = clipsByID(new)
        let added = newClips.keys.filter { oldClips[$0] == nil }.compactMap { newClips[$0] }
        let removed = oldClips.keys.filter { newClips[$0] == nil }.compactMap { oldClips[$0] }
        if !added.isEmpty || !removed.isEmpty {
            return clipsAddedOrRemoved(added: added, removed: removed)
        }
        let oldLayers = old.layers.map(\.id)
        let newLayers = new.layers.map(\.id)
        if oldLayers != newLayers {
            if newLayers.count > oldLayers.count { return "Add Layer" }
            if newLayers.count < oldLayers.count { return "Delete Layer" }
            if Set(oldLayers) == Set(newLayers) { return "Move Layer" }
            return "Edit Layers"
        }
        if old.sections != new.sections { return "Edit Sections" }

        let changedClips = newClips.values.filter { oldClips[$0.clip.id]?.clip != $0.clip || oldClips[$0.clip.id]?.layerID != $0.layerID }
        if let first = changedClips.first, let before = oldClips[first.clip.id] {
            let name = clipChange(before, first)
            return changedClips.count > 1 ? plural(name) : name
        }
        for (oldLayer, newLayer) in zip(old.layers, new.layers) where oldLayer != newLayer {
            return layerChange(oldLayer, newLayer)
        }
        return "Edit Timeline"
    }

    private struct PlacedClip {
        let clip: TimelineClip
        let layerID: UUID
    }

    private static func clipsByID(_ timeline: Timeline) -> [UUID: PlacedClip] {
        var found: [UUID: PlacedClip] = [:]
        for layer in timeline.layers {
            for clip in layer.clips { found[clip.id] = PlacedClip(clip: clip, layerID: layer.id) }
        }
        return found
    }

    private static func clipsAddedOrRemoved(added: [PlacedClip], removed: [PlacedClip]) -> String {
        if removed.isEmpty { return added.count == 1 ? "Add Clip" : "Add Clips" }
        if added.isEmpty { return removed.count == 1 ? "Delete Clip" : "Delete Clips" }
        // Splitting and joining give the pieces new IDs, from the same
        // footage as the clips they replace.
        let sources = removed.map(\.clip.source)
        if added.allSatisfy({ sources.contains($0.clip.source) }) {
            if added.count > removed.count { return removed.count == 1 ? "Split Clip" : "Split Clips" }
            if added.count < removed.count { return "Join Clips" }
        }
        return "Replace Clips"
    }

    private static func clipChange(_ old: PlacedClip, _ new: PlacedClip) -> String {
        if old.layerID != new.layerID { return "Move Clip" }
        let a = old.clip
        let b = new.clip
        if a.enabled != b.enabled { return b.enabled ? "Turn Clip On" : "Turn Clip Off" }
        // Changes to the clip's place in time, each tried alone.
        if a.changingOnly(b, \.startOffset) { return "Move Clip" }
        var timing = a
        timing.startOffset = b.startOffset
        timing.trimStart = b.trimStart
        timing.trimEnd = b.trimEnd
        if timing == b {
            let sameLength = a.trimmedDuration == b.trimmedDuration && a.startOffset == b.startOffset
            return sameLength ? "Slip Clip" : "Trim Clip"
        }
        if a.transitionIn != b.transitionIn || a.transitionOut != b.transitionOut {
            let had = a.transitionIn != nil || a.transitionOut != nil
            let has = b.transitionIn != nil || b.transitionOut != nil
            if has && !had { return "Add Transition" }
            if had && !has { return "Remove Transition" }
            return "Change Transition"
        }
        if a.effects != b.effects { return effectsChange(a.effects, b.effects) }
        if a.audioEffects != b.audioEffects { return effectsChange(a.audioEffects, b.audioEffects, sound: true) }
        if a.volume != b.volume || a.pan != b.pan || a.soundMuted != b.soundMuted { return "Change Clip Sound" }
        if a.streams != b.streams { return "Detach Audio" }
        if a.time != b.time { return "Change Clip Time" }
        if a.shutter != b.shutter { return "Change Motion Blur" }
        if a.music != b.music || a.followsMusic != b.followsMusic { return "Change Music Attachment" }
        return "Edit Clip"
    }

    private static func effectsChange(_ old: [Effect], _ new: [Effect], sound: Bool = false) -> String {
        let noun = sound ? "Sound Effect" : "Effect"
        if new.count > old.count { return "Add \(noun)" }
        if new.count < old.count { return "Remove \(noun)" }
        if Set(old.map(\.id)) == Set(new.map(\.id)), old.map(\.id) != new.map(\.id) { return "Reorder \(noun)s" }
        return "Change \(noun)"
    }

    private static func layerChange(_ old: TimelineLayer, _ new: TimelineLayer) -> String {
        if old.customName != new.customName { return "Rename Layer" }
        if old.audioEffects != new.audioEffects { return effectsChange(old.audioEffects, new.audioEffects, sound: true) }
        if old.volume != new.volume || old.pan != new.pan { return "Change Layer Sound" }
        return "Edit Layer"
    }

    private static func mediaChange(_ before: [MediaClip], _ after: [MediaClip]) -> String {
        if after.count > before.count { return "Import Media" }
        if after.count < before.count { return "Remove Media" }
        for (old, new) in zip(before, after) where old != new {
            if old.name != new.name { return "Rename Media" }
            if old.sceneEdits != new.sceneEdits { return "Edit Scenes" }
            if old.beatMap != new.beatMap { return "Edit Beats" }
            if old.url != new.url { return "Replace Media" }
        }
        return "Change Media"
    }

    /// "Move Clip" for several clips at once.
    private static func plural(_ name: String) -> String {
        name.hasSuffix(" Clip") ? name + "s" : name
    }
}

private extension TimelineClip {
    /// Whether `other` is this clip with only `field` changed.
    func changingOnly<Value>(_ other: TimelineClip, _ field: WritableKeyPath<TimelineClip, Value>) -> Bool {
        var copy = self
        copy[keyPath: field] = other[keyPath: field]
        return copy == other
    }
}
