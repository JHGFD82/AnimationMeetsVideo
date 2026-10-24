import CoreMedia
import Foundation

/// A named sequence of numbered layers, After Effects-style. Timelines can
/// embed one another (nested/compound-clip style) via `ClipSource.timeline`.
struct Timeline: Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Index 0 is the topmost layer — matches After Effects' convention
    /// where newer/higher layers composite over lower ones.
    var layers: [TimelineLayer]
    var frameSize: CGSize
    var frameRate: Double
    var colorSpace: ProjectColorSpace
    /// Named stretches of time, in order, not overlapping.
    var sections: [TimelineSection] = []

    /// Up to the end of the last clip or section, whichever is later.
    var duration: CMTime {
        (layers.map(\.duration) + sections.map(\.end)).max() ?? .zero
    }

    var timebaseSummary: String {
        "\(Int(frameSize.width))×\(Int(frameSize.height)) · \(String(format: "%.2f", frameRate)) fps · \(colorSpace.rawValue)"
    }

    func layer(id: UUID) -> TimelineLayer? {
        layers.first(id: id)
    }

    /// The clip in the given layer whose [startOffset, endOffset) range
    /// covers `time`, if any — nil if `time` falls in a gap.
    func clip(at time: CMTime, layer layerID: UUID) -> TimelineClip? {
        guard let layer = layer(id: layerID) else { return nil }
        return layer.clips.first { time >= $0.startOffset && time < $0.endOffset }
    }
}

struct TimelineLayer: Identifiable, Equatable {
    var id = UUID()
    /// User-assigned name, if any. Without one the timeline shows its kind
    /// and number, such as "Video 2".
    var customName: String?
    /// Which area of the timeline the layer sits in, and so which clips it
    /// takes. See `LayerKind`.
    var kind: LayerKind = .video
    var clips: [TimelineClip]
    /// The volume of everything a Sound or Music layer plays, applied after
    /// each clip's own, in decibels (see `AudioLevel`), keyframed in this
    /// timeline's time. Video layers have none, only their clips do.
    var volume = AnimatedValue(0.0)
    /// Where a Sound or Music layer's sound sits between the speakers,
    /// applied after each clip's own pan (see `AudioPan`), keyframed in
    /// this timeline's time.
    var pan = AnimatedValue(0.0)
    /// The sound effects a Sound or Music layer plays everything on it
    /// through, after each clip's own and before the layer's volume and
    /// pan, keyframed in this timeline's time. Video layers have none.
    var audioEffects: [Effect] = []
    /// Whether the layer holds adjustment clips (and only them), whose
    /// stacks are applied to the layers below. See docs/effects.md,
    /// "Adjustment layers". The layer is a video layer in every other way.
    var isAdjustment = false

    var duration: CMTime {
        clips.map(\.endOffset).max() ?? .zero
    }
}

extension Timeline {
    /// The clips a split at `time` cuts, with their layers, as Final Cut's
    /// Blade and Blade All: of the clips `time` is strictly inside, those
    /// `selected`, or every one with `everyClip` or nothing selected.
    func clipsToSplit(at time: CMTime, selected: Set<UUID>, everyClip: Bool) -> [(layerID: UUID, clipID: UUID)] {
        layers.flatMap { layer in
            layer.clips.compactMap { clip in
                guard time > clip.startOffset, time < clip.endOffset,
                      everyClip || selected.isEmpty || selected.contains(clip.id)
                else { return nil }
                return (layer.id, clip.id)
            }
        }
    }
}

extension Timeline {
    /// Clips on a layer closer than this are taken to meet: the end of a
    /// retimed clip can't be found closer than the rounding of source
    /// time (4 µs), and a gap that small shows as a black frame.
    static let abutmentTolerance = CMTime(value: 1, timescale: 1000)

    /// The same timeline with every gap between clips on a layer smaller
    /// than `abutmentTolerance` closed, by moving the later clip to the
    /// earlier one's end.
    func closingSlivers() -> Timeline {
        var copy = self
        for layer in copy.layers.indices {
            let clips = copy.layers[layer].clips.sorted { $0.startOffset < $1.startOffset }
            var previousEnd: CMTime?
            var result: [TimelineClip] = []
            for var clip in clips {
                if let previousEnd {
                    let gap = CMTimeSubtract(clip.startOffset, previousEnd)
                    if gap > .zero, gap < Self.abutmentTolerance { clip.startOffset = previousEnd }
                }
                previousEnd = clip.endOffset
                result.append(clip)
            }
            // Keep the layer's own order of clips.
            // Loaded projects aren't guaranteed unique IDs; keep the first.
            let moved = Dictionary(result.map { ($0.id, $0.startOffset) }, uniquingKeysWith: { first, _ in first })
            for index in copy.layers[layer].clips.indices {
                copy.layers[layer].clips[index].startOffset = moved[copy.layers[layer].clips[index].id] ?? copy.layers[layer].clips[index].startOffset
            }
        }
        return copy
    }
}

extension Timeline {
    /// The same timeline without its disabled clips, which play as gaps.
    func withoutDisabledClips() -> Timeline {
        var copy = self
        for layer in copy.layers.indices { copy.layers[layer].clips.removeAll { !$0.enabled } }
        return copy
    }
}
