import CoreMedia
import Foundation

// Inputs (see docs/effects.md, "Inputs"): pictures an effect takes besides the
// clip's, dragged from the browser into the effect's drop zone. An input is
// part of the clip, not a layer, and is tracked like any other use of its media.

extension EditingProject {
    /// Whether a timeline can be an input inside `targetTimelineID`: not
    /// itself, and not one that has the target in it, as a nested clip or as
    /// an input, however deep.
    func canUseAsInput(_ timelineID: UUID, in targetTimelineID: UUID) -> Bool {
        canEmbed(timelineID, into: targetTimelineID)
    }

    /// Whether `input` can be put on an effect of a clip in `timelineID`.
    func accepts(_ input: EffectInput, in timelineID: UUID) -> Bool {
        switch input.source {
        case .asset(let id): mediaClip(id: id)?.kind == .video
        case .timeline(let id): canUseAsInput(id, in: timelineID)
        }
    }

    /// Puts a picture on an effect that takes one, or takes it off for nil.
    /// Returns whether it was accepted.
    @discardableResult
    mutating func setInput(_ input: EffectInput?, ofEffect effectID: UUID, onClip clipID: UUID, in timelineID: UUID) -> Bool {
        guard let existing = clipAndLayer(clipID, in: timelineID)?.clip.effects.first(where: { $0.id == effectID }),
              existing.kind.takesInput
        else {
            return false
        }
        if let input, !accepts(input, in: timelineID) { return false }
        editEffect(effectID, ofClip: clipID, in: timelineID) { $0.input = input }
        return true
    }

    /// What an input is called: its asset's or timeline's name.
    func name(of input: EffectInput) -> String? {
        switch input.source {
        case .asset(let id): mediaClip(id: id)?.name
        case .timeline(let id): timeline(id: id)?.name
        }
    }

    /// Whether what an input names is gone, or has no file to read.
    func isMissing(_ input: EffectInput) -> Bool {
        switch input.source {
        case .asset(let id): mediaClip(id: id)?.url == nil
        case .timeline(let id): timeline(id: id) == nil
        }
    }

    /// The parts of an asset's original time that effects' inputs play, for
    /// the clips of every timeline: where each starts, to as far as its clip
    /// lasts, or all of it when it loops.
    func usedInputRanges(ofMedia assetID: UUID) -> [CMTimeRange] {
        guard let media = mediaClip(id: assetID) else { return [] }
        var ranges: [CMTimeRange] = []
        for timeline in timelines {
            for layer in timeline.layers {
                for clip in layer.clips {
                    for effect in clip.effects {
                        guard let input = effect.input, input.source == .asset(assetID) else { continue }
                        let end = input.loops ? media.duration : CMTimeMinimum(media.duration, CMTimeAdd(input.offset, clip.placedDuration))
                        let range = CMTimeRange(start: input.offset, end: end)
                        if range.isValid, range.duration > .zero { ranges.append(range) }
                    }
                }
            }
        }
        return ranges
    }
}
