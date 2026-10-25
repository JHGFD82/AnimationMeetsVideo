import CoreMedia
import Foundation

/// Names an edit for the Edit menu by comparing the project before and
/// after it, as `ProjectHistory` finds edits: what was done and to what,
/// such as "Undo Trim End of Scene 23 of video.mp4" or "Undo Change Blur
/// Radius on Scene 4 of interview.mov". A clip is named by the scene of
/// its video it plays, once the video's scenes are found, and by its file
/// otherwise. No call site has to say what it did, so a new kind of edit
/// still gets a name, if only a general one ("Edit Scene 4 of …").
///
/// Each step also has an identity that is never shown: a hash of what was
/// done and the IDs of what it was done to. Quick changes merge into one
/// undo step only when their identities match, so the same control
/// stepped by the arrow keys is one step, while the same edit to two
/// clips, or two edits to one clip, are always two, even when their names
/// read the same (two clips of one scene).
enum ProjectChange {
    struct Step: Equatable {
        /// For the Edit menu: "Undo" and "Redo" go before it.
        let name: String
        /// What was done and to which things, hashed; equal only for the
        /// same edit to the same things.
        let identity: Int
    }

    /// The scenes of a video asset in a project, in order, or nil while
    /// they aren't known (see `EditingProject.scenes(ofAsset:track:)`).
    typealias SceneLookup = (EditingProject, UUID) -> [SceneRange]?

    /// File names longer than this are shortened in the middle, keeping
    /// the extension: "A very long name of…take 3.mp4".
    static let longestFileName = 32

    /// What the change from `before` to `after` did, or nil when nothing
    /// changed. `scenes` finds the scenes clips are named by.
    static func step(from before: EditingProject, to after: EditingProject, scenes: SceneLookup? = nil) -> Step? {
        guard let found = Describer(scenes: scenes).describe(before, after) else { return nil }
        var hasher = Hasher()
        hasher.combine(found.what)
        for id in found.ids { hasher.combine(id) }
        return Step(name: found.name, identity: hasher.finalize())
    }

    /// `name` no longer than `longestFileName`, cut in the middle of the
    /// part before the extension.
    static func shortened(fileName name: String) -> String {
        guard name.count > longestFileName else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let base = ext.isEmpty ? name : String(name.dropLast(suffix.count))
        let room = max(longestFileName - suffix.count - 1, 2)
        let head = (room * 2) / 3
        return base.prefix(head) + "…" + base.suffix(room - head) + suffix
    }

    static func quoted(_ name: String) -> String {
        "\u{201C}\(name)\u{201D}"
    }
}

// MARK: - Describing

/// A step before it is hashed: its name, a token for the kind of edit,
/// and the IDs of what it changed, in a stable order.
private struct Found {
    let name: String
    let what: String
    let ids: [UUID]
}

/// An edit to one clip, named with a place for which clip ("%@"), so the
/// same edit to several clips can be named together.
private struct ClipEdit {
    let template: String
    let what: String
    /// What inside the clip it changed, such as an effect and control.
    var ids: [UUID] = []

    func name(for label: String) -> String {
        template.replacingOccurrences(of: "%@", with: label)
    }
}

private struct PlacedClip {
    let clip: TimelineClip
    let layerID: UUID
}

private struct Describer {
    let scenes: ProjectChange.SceneLookup?

    private func quoted(_ name: String) -> String { ProjectChange.quoted(name) }

    func describe(_ before: EditingProject, _ after: EditingProject) -> Found? {
        if before.timelines != after.timelines {
            return timelinesChange(before, after)
        }
        if before.clips != after.clips {
            return mediaChange(before.clips, after.clips)
        }
        if before.name != after.name {
            return Found(name: "Rename Project to \(quoted(after.name))", what: "rename-project", ids: [])
        }
        if before != after { return Found(name: "Change Project Settings", what: "project-settings", ids: []) }
        return nil
    }

    // MARK: Labels

    /// A media file as named in steps: its file name, shortened when long.
    private func fileLabel(_ media: MediaClip) -> String {
        ProjectChange.shortened(fileName: media.url?.lastPathComponent ?? media.name)
    }

    /// A clip as named in steps: the scene or scenes of its video it plays
    /// ("Scene 23 of video.mp4", "Scenes 3–5 of video.mp4"), its file
    /// while the scenes aren't known, or what else it plays.
    private func clipLabel(_ clip: TimelineClip, in project: EditingProject) -> String {
        guard case .media(let assetID) = clip.source, let media = project.mediaClip(id: assetID) else {
            return quoted(project.resolvedInfo(for: clip.source)?.name ?? "Clip")
        }
        let file = fileLabel(media)
        guard let ranges = scenes?(project, assetID), ranges.count > 1 else { return file }
        let start = CMTimeMinimum(clip.trimStart, clip.trimEnd)
        let end = CMTimeMaximum(clip.trimStart, clip.trimEnd)
        // The scenes it overlaps; touching a scene at an edge isn't playing it.
        let played = ranges.indices.filter { ranges[$0].end > start && ranges[$0].start < end }
        guard let first = played.first, let last = played.last else { return file }
        return first == last ? "Scene \(first + 1) of \(file)" : "Scenes \(first + 1)–\(last + 1) of \(file)"
    }

    /// One clip, or how many: "Scene 4 of video.mp4", "3 Clips".
    private func clipsLabel(_ clips: [PlacedClip], in project: EditingProject) -> String {
        clips.count == 1 ? clipLabel(clips[0].clip, in: project) : "\(clips.count) Clips"
    }

    // MARK: Timelines

    private func timelinesChange(_ before: EditingProject, _ after: EditingProject) -> Found {
        let beforeIDs = before.timelines.map(\.id)
        let afterIDs = after.timelines.map(\.id)
        if let added = after.timelines.first(where: { !beforeIDs.contains($0.id) }) {
            return Found(name: "New Timeline \(quoted(added.name))", what: "new-timeline", ids: [added.id])
        }
        if let removed = before.timelines.first(where: { !afterIDs.contains($0.id) }) {
            return Found(name: "Delete Timeline \(quoted(removed.name))", what: "delete-timeline", ids: [removed.id])
        }
        // A change reaching into several timelines at once, such as putting
        // clips in a new nested timeline, is named by the first.
        for new in after.timelines {
            guard let old = before.timeline(id: new.id), old != new else { continue }
            return timelineChange(old, new, before: before, after: after)
        }
        return Found(name: "Reorder Timelines", what: "reorder-timelines", ids: [])
    }

    private func timelineChange(_ old: Timeline, _ new: Timeline, before: EditingProject, after: EditingProject) -> Found {
        if old.name != new.name {
            return Found(name: "Rename Timeline to \(quoted(new.name))", what: "rename-timeline", ids: [new.id])
        }
        if old.frameSize != new.frameSize || old.frameRate != new.frameRate || old.colorSpace != new.colorSpace {
            return Found(name: "Change Settings of \(quoted(new.name))", what: "timeline-settings", ids: [new.id])
        }
        let oldClips = clipsByID(old)
        let newClips = clipsByID(new)
        let added = new.layers.flatMap(\.clips).filter { oldClips[$0.id] == nil }.compactMap { newClips[$0.id] }
        let removed = old.layers.flatMap(\.clips).filter { newClips[$0.id] == nil }.compactMap { oldClips[$0.id] }
        if !added.isEmpty || !removed.isEmpty {
            return clipsAddedOrRemoved(added: added, removed: removed, in: new, before: before, after: after)
        }
        if old.layers.map(\.id) != new.layers.map(\.id) {
            return layersChange(old, new, project: before, after: after)
        }
        if old.sections != new.sections {
            return Found(name: "Edit Sections of \(quoted(new.name))", what: "sections", ids: [new.id])
        }

        // Clips that changed in place, in timeline order.
        let changed = new.layers.flatMap(\.clips).compactMap { clip -> (old: PlacedClip, new: PlacedClip)? in
            guard let was = oldClips[clip.id], let now = newClips[clip.id],
                  was.clip != now.clip || was.layerID != now.layerID
            else { return nil }
            return (was, now)
        }
        if !changed.isEmpty {
            let edits = changed.map { clipEdit($0.old, $0.new, in: new, project: after) }
            let ids = changed.map(\.new.clip.id)
            if edits.count == 1, let edit = edits.first {
                // Named as it was: a trim can move a clip into another scene.
                return Found(name: edit.name(for: clipLabel(changed[0].old.clip, in: before)), what: edit.what, ids: ids + edit.ids)
            }
            // The same edit to several clips reads as one; different edits
            // as a general one.
            if let first = edits.first, edits.allSatisfy({ $0.template == first.template }) {
                return Found(name: first.name(for: "\(edits.count) Clips"), what: first.what, ids: ids + edits.flatMap(\.ids))
            }
            return Found(name: "Edit \(edits.count) Clips", what: "edit-clips", ids: ids)
        }

        for (oldLayer, newLayer) in zip(old.layers, new.layers) where oldLayer != newLayer {
            return layerChange(oldLayer, newLayer, label: quoted(after.displayName(of: newLayer, in: new)))
        }
        return Found(name: "Edit \(quoted(new.name))", what: "edit-timeline", ids: [new.id])
    }

    // MARK: Clips

    private func clipsByID(_ timeline: Timeline) -> [UUID: PlacedClip] {
        var found: [UUID: PlacedClip] = [:]
        for layer in timeline.layers {
            for clip in layer.clips { found[clip.id] = PlacedClip(clip: clip, layerID: layer.id) }
        }
        return found
    }

    private func clipsAddedOrRemoved(
        added: [PlacedClip], removed: [PlacedClip], in timeline: Timeline, before: EditingProject, after: EditingProject
    ) -> Found {
        if removed.isEmpty {
            let ids = added.map(\.clip.id)
            if added.count == 1, let layer = timeline.layer(id: added[0].layerID) {
                let layerName = quoted(after.displayName(of: layer, in: timeline))
                return Found(name: "Add \(clipLabel(added[0].clip, in: after)) to \(layerName)", what: "add-clips", ids: ids)
            }
            return Found(name: "Add \(added.count) Clips", what: "add-clips", ids: ids)
        }
        let removedIDs = removed.map(\.clip.id)
        if added.isEmpty {
            return Found(name: "Delete \(clipsLabel(removed, in: before))", what: "delete-clips", ids: removedIDs)
        }
        // Splitting and joining give the pieces new IDs, from the same
        // footage as the clips they replace.
        let sources = removed.map(\.clip.source)
        if added.allSatisfy({ sources.contains($0.clip.source) }) {
            if added.count > removed.count {
                return Found(name: "Split \(clipsLabel(removed, in: before))", what: "split", ids: removedIDs)
            }
            if added.count < removed.count {
                return Found(name: "Join \(clipsLabel(added, in: after))", what: "join", ids: removedIDs)
            }
        }
        return Found(name: "Replace \(clipsLabel(removed, in: before))", what: "replace-clips", ids: removedIDs + added.map(\.clip.id))
    }

    private func clipEdit(_ old: PlacedClip, _ new: PlacedClip, in timeline: Timeline, project: EditingProject) -> ClipEdit {
        if old.layerID != new.layerID {
            let layer = timeline.layer(id: new.layerID).map { quoted(project.displayName(of: $0, in: timeline)) } ?? "Another Layer"
            return ClipEdit(template: "Move %@ to \(layer)", what: "move-to-layer", ids: [new.layerID])
        }
        let a = old.clip
        let b = new.clip
        if a.enabled != b.enabled {
            return b.enabled ? ClipEdit(template: "Turn On %@", what: "turn-on") : ClipEdit(template: "Turn Off %@", what: "turn-off")
        }
        if a.changingOnly(b, \.startOffset) { return ClipEdit(template: "Move %@", what: "move") }
        var timing = a
        timing.startOffset = b.startOffset
        timing.trimStart = b.trimStart
        timing.trimEnd = b.trimEnd
        if timing == b {
            if a.trimmedDuration == b.trimmedDuration && a.startOffset == b.startOffset {
                return ClipEdit(template: "Slip %@", what: "slip")
            }
            if a.endOffset == b.endOffset { return ClipEdit(template: "Trim Start of %@", what: "trim-start") }
            if a.startOffset == b.startOffset { return ClipEdit(template: "Trim End of %@", what: "trim-end") }
            return ClipEdit(template: "Trim %@", what: "trim")
        }
        if a.transitionIn != b.transitionIn {
            return transitionEdit(a.transitionIn, b.transitionIn, end: "Start", what: "transition-in")
        }
        if a.transitionOut != b.transitionOut {
            return transitionEdit(a.transitionOut, b.transitionOut, end: "End", what: "transition-out")
        }
        if a.effects != b.effects { return effectsEdit(a.effects, b.effects, stack: "effects") }
        if a.audioEffects != b.audioEffects { return effectsEdit(a.audioEffects, b.audioEffects, stack: "sound-effects") }
        if a.volume != b.volume { return ClipEdit(template: "Change Volume of %@", what: "volume") }
        if a.pan != b.pan { return ClipEdit(template: "Change Pan of %@", what: "pan") }
        if a.soundMuted != b.soundMuted {
            return b.soundMuted ? ClipEdit(template: "Mute %@", what: "mute") : ClipEdit(template: "Unmute %@", what: "unmute")
        }
        if a.streams != b.streams { return ClipEdit(template: "Detach Audio from %@", what: "detach-audio") }
        if a.time.speed != b.time.speed { return ClipEdit(template: "Change Speed of %@", what: "speed") }
        if a.time != b.time { return ClipEdit(template: "Change Time Settings of %@", what: "time") }
        if a.shutter != b.shutter { return ClipEdit(template: "Change Motion Blur of %@", what: "shutter") }
        if a.anchorPoint != b.anchorPoint { return ClipEdit(template: "Move Anchor Point of %@", what: "anchor") }
        if a.music != b.music || a.followsMusic != b.followsMusic {
            return ClipEdit(template: "Change Music Attachment of %@", what: "music")
        }
        return ClipEdit(template: "Edit %@", what: "edit-clip")
    }

    private func transitionEdit(_ old: ClipTransition?, _ new: ClipTransition?, end: String, what: String) -> ClipEdit {
        switch (old, new) {
        case (nil, let new?):
            return ClipEdit(template: "Add \(new.kind.name) to \(end) of %@", what: "add-" + what)
        case (let old?, nil):
            return ClipEdit(template: "Remove \(old.kind.name) from \(end) of %@", what: "remove-" + what)
        case (let old?, let new?) where old.kind != new.kind:
            return ClipEdit(template: "Change \(end) Transition of %@ to \(new.kind.name)", what: "kind-" + what)
        case (let old?, let new?) where old.duration != new.duration:
            return ClipEdit(template: "Change Length of \(new.kind.name) on %@", what: "length-" + what)
        case (_, let new?):
            return ClipEdit(template: "Change \(new.kind.name) on %@", what: what)
        case (nil, nil):
            return ClipEdit(template: "Edit %@", what: what)
        }
    }

    // MARK: Effects

    /// An edit to a clip's or layer's effect stack, naming the effect and,
    /// for a value, its control.
    private func effectsEdit(_ old: [Effect], _ new: [Effect], stack: String) -> ClipEdit {
        let oldIDs = old.map(\.id)
        let newIDs = new.map(\.id)
        if let added = new.first(where: { !oldIDs.contains($0.id) }) {
            return ClipEdit(template: "Add \(added.displayName) to %@", what: "add-effect", ids: [added.id])
        }
        if let removed = old.first(where: { !newIDs.contains($0.id) }) {
            return ClipEdit(template: "Remove \(removed.displayName) from %@", what: "remove-effect", ids: [removed.id])
        }
        if oldIDs != newIDs { return ClipEdit(template: "Reorder Effects on %@", what: "reorder-" + stack) }
        for (a, b) in zip(old, new) where a != b {
            if a.enabled != b.enabled {
                return ClipEdit(template: "Turn \(b.enabled ? "On" : "Off") \(b.displayName) on %@", what: "effect-enabled", ids: [b.id])
            }
            if a.name != b.name {
                return ClipEdit(template: "Rename \(a.displayName) to \(quoted(b.displayName)) on %@", what: "rename-effect", ids: [b.id])
            }
            for (control, was) in zip(b.controls, a.controls) where control != was {
                return ClipEdit(
                    template: "Change \(b.displayName) \(control.kind.name) on %@", what: "control", ids: [b.id, control.id]
                )
            }
            return ClipEdit(template: "Change \(b.displayName) on %@", what: "effect", ids: [b.id])
        }
        return ClipEdit(template: "Change Effects on %@", what: stack)
    }

    // MARK: Layers

    private func layersChange(_ old: Timeline, _ new: Timeline, project: EditingProject, after: EditingProject) -> Found {
        let oldIDs = old.layers.map(\.id)
        let newIDs = new.layers.map(\.id)
        if let added = new.layers.first(where: { !oldIDs.contains($0.id) }) {
            return Found(name: "Add Layer \(quoted(after.displayName(of: added, in: new)))", what: "add-layer", ids: [added.id])
        }
        if let removed = old.layers.first(where: { !newIDs.contains($0.id) }) {
            return Found(name: "Delete Layer \(quoted(project.displayName(of: removed, in: old)))", what: "delete-layer", ids: [removed.id])
        }
        // The layer moved is the one without which the order is unchanged;
        // it's named as it was, since a default name follows its place.
        let moved = old.layers.first { layer in
            oldIDs.filter { $0 != layer.id } == newIDs.filter { $0 != layer.id }
        }
        if let moved {
            return Found(name: "Move Layer \(quoted(project.displayName(of: moved, in: old)))", what: "move-layer", ids: [moved.id])
        }
        return Found(name: "Reorder Layers of \(quoted(new.name))", what: "reorder-layers", ids: [new.id])
    }

    private func layerChange(_ old: TimelineLayer, _ new: TimelineLayer, label: String) -> Found {
        let edit: ClipEdit
        if old.customName != new.customName {
            edit = ClipEdit(template: "Rename Layer to %@", what: "rename-layer")
        } else if old.audioEffects != new.audioEffects {
            edit = effectsEdit(old.audioEffects, new.audioEffects, stack: "layer-sound-effects")
        } else if old.volume != new.volume {
            edit = ClipEdit(template: "Change Volume of %@", what: "layer-volume")
        } else if old.pan != new.pan {
            edit = ClipEdit(template: "Change Pan of %@", what: "layer-pan")
        } else {
            edit = ClipEdit(template: "Edit %@", what: "edit-layer")
        }
        return Found(name: edit.name(for: label), what: edit.what, ids: [new.id] + edit.ids)
    }

    // MARK: Media

    private func mediaChange(_ before: [MediaClip], _ after: [MediaClip]) -> Found {
        let beforeIDs = before.map(\.id)
        let afterIDs = after.map(\.id)
        let added = after.filter { !beforeIDs.contains($0.id) }
        if !added.isEmpty {
            let name = added.count == 1 ? "Import \(fileLabel(added[0]))" : "Import \(added.count) Files"
            return Found(name: name, what: "import", ids: added.map(\.id))
        }
        let removed = before.filter { !afterIDs.contains($0.id) }
        if !removed.isEmpty {
            let name = removed.count == 1 ? "Remove \(fileLabel(removed[0]))" : "Remove \(removed.count) Files"
            return Found(name: name, what: "remove-media", ids: removed.map(\.id))
        }
        for new in after {
            guard let old = before.first(where: { $0.id == new.id }), old != new else { continue }
            let label = fileLabel(old)
            if old.name != new.name {
                return Found(name: "Rename \(label) to \(quoted(new.name))", what: "rename-media", ids: [new.id])
            }
            if old.sceneEdits != new.sceneEdits { return Found(name: "Edit Scenes of \(label)", what: "scenes", ids: [new.id]) }
            if old.skipsSceneDetection != new.skipsSceneDetection {
                let name = new.skipsSceneDetection ? "Don't Detect Scenes of \(label)" : "Detect Scenes of \(label)"
                return Found(name: name, what: "scene-detection", ids: [new.id])
            }
            if old.beatMap != new.beatMap { return Found(name: "Edit Beats of \(label)", what: "beats", ids: [new.id]) }
            if old.url != new.url { return Found(name: "Replace \(label)", what: "replace-media", ids: [new.id]) }
            return Found(name: "Change \(label)", what: "media", ids: [new.id])
        }
        return Found(name: "Reorder Media", what: "reorder-media", ids: [])
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
