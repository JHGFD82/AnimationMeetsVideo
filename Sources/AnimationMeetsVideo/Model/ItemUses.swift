import CoreMedia
import Foundation

// Where the project's timelines use an asset or a timeline, for Find All
// and for removing one from the browser (see docs/browser.md, "Removing"
// and "Finding uses"). Removing one takes its uses with it, so no clip or
// effect is left pointing at nothing; it is undoable as any edit, and a
// removed asset's files stay in the package (docs/project-package.md).

/// Something the browser lists that timelines can use.
enum UsedItem: Hashable {
    case media(UUID)
    case timeline(UUID)
}

/// One place a timeline uses an asset or a timeline: a clip of it, or the
/// input of one of a clip's effects. The times are the clip's on its
/// timeline.
struct ItemUse: Identifiable, Equatable {
    var timelineID: UUID
    var layerID: UUID
    var clipID: UUID
    /// The effect taking it as its input; nil for a clip of it.
    var effectID: UUID?
    var start: CMTime
    var end: CMTime

    var id: String { "\(clipID)|\(effectID?.uuidString ?? "clip")" }
    var duration: CMTime { CMTimeSubtract(end, start) }
    var isEffectInput: Bool { effectID != nil }
}

extension EditingProject {
    /// Every use of `item`, in the order of the timelines, top layer first,
    /// then by time. With `range` (an asset's original time, such as a
    /// scene's), only clips and inputs playing some of it count.
    func uses(of item: UsedItem, within range: CMTimeRange? = nil) -> [ItemUse] {
        var found: [ItemUse] = []
        for timeline in timelines {
            for layer in timeline.layers {
                for clip in layer.clips.sorted(by: { $0.startOffset < $1.startOffset }) {
                    func use(_ effectID: UUID? = nil) -> ItemUse {
                        ItemUse(
                            timelineID: timeline.id, layerID: layer.id, clipID: clip.id, effectID: effectID,
                            start: clip.startOffset, end: clip.endOffset
                        )
                    }
                    if Self.source(clip.source, is: item), Self.overlaps(clip.trimStart, clip.trimEnd, range) {
                        found.append(use())
                    }
                    for effect in clip.effects {
                        guard let input = effect.input, Self.source(input.source, is: item) else { continue }
                        let end = input.loops ? CMTime.positiveInfinity : CMTimeAdd(input.offset, clip.placedDuration)
                        if Self.overlaps(input.offset, end, range) { found.append(use(effect.id)) }
                    }
                }
            }
        }
        return found
    }

    func isUsed(_ item: UsedItem) -> Bool { !uses(of: item).isEmpty }

    private static func source(_ source: ClipSource, is item: UsedItem) -> Bool {
        switch item {
        case .media(let id): source == .media(id)
        case .timeline(let id): source == .timeline(id)
        }
    }

    private static func source(_ source: EffectInput.Source, is item: UsedItem) -> Bool {
        switch item {
        case .media(let id): source == .asset(id)
        case .timeline(let id): source == .timeline(id)
        }
    }

    private static func overlaps(_ start: CMTime, _ end: CMTime, _ range: CMTimeRange?) -> Bool {
        guard let range else { return true }
        return start < range.end && end > range.start
    }

    /// Takes the assets out of the project with their uses: every clip of
    /// them is deleted (its layer stays), an effect taking one as its input
    /// lets go of it, and a clip tied to one as its music is untied.
    /// Returns those taken out.
    @discardableResult
    mutating func removeMedia(_ ids: some Sequence<UUID>) -> [UUID] {
        let removed = Set(ids.filter { mediaClip(id: $0) != nil })
        guard !removed.isEmpty else { return [] }
        removeUses { clip in
            if case .media(let id) = clip.source { return removed.contains(id) }
            return false
        } input: { source in
            if case .asset(let id) = source { return removed.contains(id) }
            return false
        }
        for t in timelines.indices {
            for l in timelines[t].layers.indices {
                for c in timelines[t].layers[l].clips.indices
                where timelines[t].layers[l].clips[c].music.map({ removed.contains($0.assetID) }) == true {
                    timelines[t].layers[l].clips[c].music = nil
                }
            }
        }
        clips.removeAll { removed.contains($0.id) }
        return Array(removed)
    }

    /// Any timeline but the main one can be deleted.
    func canDeleteTimeline(_ timelineID: UUID) -> Bool {
        timelineID != rootTimelineID && timeline(id: timelineID) != nil
    }

    /// Deletes the timelines among `ids` that can be deleted, with their
    /// uses: every clip embedding one is deleted (its layer stays), and an
    /// effect taking one as its input lets go of it. What a deleted
    /// timeline embedded stays. Returns those deleted.
    @discardableResult
    mutating func deleteTimelines(_ ids: some Sequence<UUID>) -> [UUID] {
        let deleted = Set(ids.filter(canDeleteTimeline))
        guard !deleted.isEmpty else { return [] }
        timelines.removeAll { deleted.contains($0.id) }
        removeUses { clip in
            if case .timeline(let id) = clip.source { return deleted.contains(id) }
            return false
        } input: { source in
            if case .timeline(let id) = source { return deleted.contains(id) }
            return false
        }
        return Array(deleted)
    }

    /// Deletes the clips `clip` picks, and takes the inputs `input` picks
    /// off the effects of those left.
    private mutating func removeUses(clip picksClip: (TimelineClip) -> Bool, input picksInput: (EffectInput.Source) -> Bool) {
        for t in timelines.indices {
            for l in timelines[t].layers.indices {
                timelines[t].layers[l].clips.removeAll(where: picksClip)
                for c in timelines[t].layers[l].clips.indices {
                    for e in timelines[t].layers[l].clips[c].effects.indices
                    where timelines[t].layers[l].clips[c].effects[e].input.map({ picksInput($0.source) }) == true {
                        timelines[t].layers[l].clips[c].effects[e].input = nil
                    }
                }
            }
        }
    }
}
