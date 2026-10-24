import Foundation

/// What a copied clip needs from the project it was copied in, so it can
/// be pasted into another project: the media it plays and the timelines
/// it embeds, with everything those need in turn, and what its effects
/// take as inputs. Pasting adds whatever the project lacks, by ID, so
/// pasting into the same project adds nothing.
struct PasteSources: Equatable {
    var media: [MediaClip] = []
    var timelines: [Timeline] = []

    func hasMedia(_ id: UUID) -> Bool { media.contains { $0.id == id } }
    func hasTimeline(_ id: UUID) -> Bool { timelines.contains { $0.id == id } }
}

extension EditingProject {
    /// What `clips` need from this project to be pasted into another.
    func pasteSources(for clips: [TimelineClip]) -> PasteSources {
        var sources = PasteSources()
        var seenMedia: Set<UUID> = []
        var seenTimelines: Set<UUID> = []

        func needMedia(_ id: UUID) {
            guard seenMedia.insert(id).inserted, let media = mediaClip(id: id) else { return }
            sources.media.append(media)
        }
        func needTimeline(_ id: UUID) {
            guard seenTimelines.insert(id).inserted, let nested = timeline(id: id) else { return }
            sources.timelines.append(nested)
            for clip in nested.layers.flatMap(\.clips) { need(clip) }
        }
        func need(_ clip: TimelineClip) {
            switch clip.source {
            case .media(let id): needMedia(id)
            case .timeline(let id): needTimeline(id)
            case .adjustment, .graphic: break
            }
            for effect in clip.effects + clip.audioEffects {
                switch effect.input?.source {
                case .asset(let id)?: needMedia(id)
                case .timeline(let id)?: needTimeline(id)
                case nil: break
                }
            }
        }
        for clip in clips { need(clip) }
        return sources
    }

    /// Adds the media and timelines of `sources` this project doesn't have.
    /// Returns the IDs of the media added.
    @discardableResult
    mutating func adopt(_ sources: PasteSources) -> [UUID] {
        var added: [UUID] = []
        for media in sources.media where mediaClip(id: media.id) == nil {
            clips.append(media)
            added.append(media.id)
        }
        for nested in sources.timelines where timeline(id: nested.id) == nil {
            timelines.append(nested)
        }
        return added
    }
}
