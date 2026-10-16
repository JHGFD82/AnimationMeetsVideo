import CoreMedia
import Foundation

// Adjustment layers (see docs/effects.md, "Adjustment layers"): layers of
// adjustment clips, whose stacks are applied to the layers below them, as far
// down as their reach.

extension EditingProject {
    /// Adds an adjustment layer holding one adjustment clip, at `index` in
    /// the timeline (0 is the top). The clip starts at `start` and lasts
    /// `duration`, by default the timeline's length, or five seconds when the
    /// timeline is empty.
    @discardableResult
    mutating func addAdjustmentLayer(
        to timelineID: UUID,
        at index: Int = 0,
        from start: CMTime = .zero,
        duration: CMTime? = nil
    ) -> (layerID: UUID, clipID: UUID)? {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }) else { return nil }
        let timeline = timelines[tIndex]
        let wanted = duration ?? (timeline.duration > start ? CMTimeSubtract(timeline.duration, start) : CMTime(value: 5, timescale: 1))
        let length = CMTimeMaximum(timeline.frameDuration, timeline.frameAligned(wanted, .down))
        let clip = TimelineClip(
            source: .adjustment, startOffset: timeline.frameAligned(start, .nearest),
            trimStart: .zero, trimEnd: length, streams: .video
        )
        var layer = TimelineLayer(customName: nil, kind: .video, clips: [clip])
        layer.isAdjustment = true
        timelines[tIndex].layers.insert(layer, at: min(max(index, 0), timelines[tIndex].layers.count))
        return (layer.id, clip.id)
    }

    /// Sets how far down an adjustment layer reaches: down to the layer
    /// `bottomLayerID`, or every layer below it for nil.
    mutating func setReach(of layerID: UUID, in timelineID: UUID, toLayer bottomLayerID: UUID?) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              timelines[tIndex].layers[lIndex].isAdjustment
        else {
            return
        }
        if let bottomLayerID, !timelines[tIndex].layers.contains(where: { $0.id == bottomLayerID }) { return }
        timelines[tIndex].layers[lIndex].reach = bottomLayerID
    }

    /// The layers an adjustment layer reaches, top to bottom: those below it
    /// down to the one it reaches to. None when that layer has been moved
    /// above it.
    func reachedLayers(of layer: TimelineLayer, in timeline: Timeline) -> [TimelineLayer] {
        guard layer.isAdjustment, let index = timeline.layers.firstIndex(where: { $0.id == layer.id }) else { return [] }
        let below = Array(timeline.layers[(index + 1)...])
        guard let bottom = layer.reach, let bottomIndex = timeline.layers.firstIndex(where: { $0.id == bottom }) else {
            return below
        }
        guard bottomIndex > index else { return [] }
        return Array(timeline.layers[(index + 1)...bottomIndex])
    }

    /// Whether the layer an adjustment layer reaches down to is above it, so
    /// it reaches nothing.
    func reachesNothing(_ layer: TimelineLayer, in timeline: Timeline) -> Bool {
        guard layer.isAdjustment, layer.reach != nil else { return false }
        return reachedLayers(of: layer, in: timeline).isEmpty
    }

    /// What an adjustment layer reaches, in words, for its menu and notes.
    func reachDescription(of layer: TimelineLayer, in timeline: Timeline) -> String {
        guard let bottom = layer.reach, let target = timeline.layer(id: bottom) else { return "All Layers Below" }
        return "Down to \(displayName(of: target, in: timeline))"
    }
}
