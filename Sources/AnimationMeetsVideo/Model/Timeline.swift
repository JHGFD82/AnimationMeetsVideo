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
    /// What the viewer shows where nothing is drawn, as red, green and blue
    /// (0...1, the timeline's encoded values); nil for black. Only the
    /// viewer draws it: exports, renders and the timeline nested in another
    /// draw over black and transparency as before.
    var previewBackground: [Double]?
    var versionStamp = EditStamp()

    /// The `EditingProject.editCount` of the last edit that changed this
    /// timeline: equal nonzero versions mean equal timelines, and an edit
    /// of another timeline leaves it alone. 0 for one never edited in a
    /// `ProjectState`. Not compared by `==`.
    var version: UInt64 {
        get { versionStamp.count }
        set { versionStamp = EditStamp(count: newValue) }
    }

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
    /// Removes a layer and every clip on it. An adjustment clip that
    /// reached down to it goes back to reaching every layer below.
    mutating func deleteLayer(_ id: UUID) {
        layers.removeAll { $0.id == id }
        for l in layers.indices {
            for c in layers[l].clips.indices where layers[l].clips[c].reach == id {
                layers[l].clips[c].reach = nil
            }
        }
    }

    /// Moves a layer to `index` in the stack (0 is the top), as when its
    /// header is dragged.
    mutating func moveLayer(_ id: UUID, toIndex index: Int) {
        guard let from = layers.firstIndex(id: id) else { return }
        layers.insert(layers.remove(at: from), clampedAt: index)
    }

    /// Moves a layer `offset` places up (negative) or down among the layers
    /// of its own kind, which are all its area of the timeline shows.
    /// Layers of other kinds keep their places.
    mutating func moveLayer(_ id: UUID, by offset: Int) {
        guard let index = layers.firstIndex(id: id) else { return }
        let kind = layers[index].kind
        let slots = layers.indices.filter { layers[$0].kind == kind }
        guard let position = slots.firstIndex(of: index), slots.indices.contains(position + offset) else { return }
        // The layers of this kind move through their own slots, so the
        // ones between shift by one and other kinds stay where they are.
        var sameKind = slots.map { layers[$0] }
        sameKind.insert(sameKind.remove(at: position), at: position + offset)
        for (slot, layer) in zip(slots, sameKind) {
            layers[slot] = layer
        }
    }

    /// Moves a layer to `position` among the layers of its own kind (0 is
    /// the top of its area), as when its header is dragged. Layers of other
    /// kinds keep their places.
    mutating func moveLayer(_ id: UUID, toPositionInKind position: Int) {
        guard let from = layers.firstIndex(id: id) else { return }
        let layer = layers.remove(at: from)
        let sameKind = layers.indices.filter { layers[$0].kind == layer.kind }
        let index: Int
        if sameKind.indices.contains(position) {
            index = sameKind[position]
        } else if let last = sameKind.last {
            index = last + 1
        } else {
            index = from
        }
        layers.insert(layer, clampedAt: index)
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
