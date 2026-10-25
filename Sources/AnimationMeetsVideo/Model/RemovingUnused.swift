import Foundation

// Taking media and timelines no timeline uses out of the project, from the
// browser (see docs/browser.md, "Removing"). Only what nothing refers to
// goes, so no clip or effect is left pointing at nothing; the edit is
// undoable as any other, and a removed asset's files stay in the package
// (docs/project-package.md).

extension EditingProject {
    /// Whether any timeline refers to the asset: a clip of it, an effect
    /// taking it as an input, or a clip tied to it as its music.
    func isUsed(media assetID: UUID) -> Bool {
        timelines.contains { timeline in
            timeline.layers.contains { layer in
                layer.clips.contains { clip in
                    clip.source == .media(assetID) || clip.music?.assetID == assetID
                        || clip.effects.contains { $0.input?.source == .asset(assetID) }
                }
            }
        }
    }

    /// Takes out of the project the assets among `ids` that no timeline
    /// uses, leaving the rest. Returns those taken out.
    @discardableResult
    mutating func removeUnusedMedia(_ ids: some Sequence<UUID>) -> [UUID] {
        let removable = Set(ids.filter { mediaClip(id: $0) != nil && !isUsed(media: $0) })
        clips.removeAll { removable.contains($0.id) }
        return Array(removable)
    }

    /// Whether a timeline can be deleted: it isn't the main timeline, and
    /// no other timeline embeds it or takes it as an effect's input.
    func canDeleteTimeline(_ timelineID: UUID) -> Bool {
        guard timelineID != rootTimelineID, timeline(id: timelineID) != nil else { return false }
        return !timelines.contains { timeline in
            timeline.id != timelineID && timeline.layers.contains { layer in
                layer.clips.contains { clip in
                    clip.source == .timeline(timelineID)
                        || clip.effects.contains { $0.input?.source == .timeline(timelineID) }
                }
            }
        }
    }

    /// Deletes the timelines among `ids` that can be deleted, leaving the
    /// rest. Deleting one can free another it embedded, which stays until
    /// it is deleted itself. Returns those deleted.
    @discardableResult
    mutating func deleteUnusedTimelines(_ ids: some Sequence<UUID>) -> [UUID] {
        let deletable = Set(ids.filter(canDeleteTimeline))
        timelines.removeAll { deletable.contains($0.id) }
        return Array(deletable)
    }
}
