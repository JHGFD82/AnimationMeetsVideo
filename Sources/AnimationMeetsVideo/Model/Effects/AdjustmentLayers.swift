import CoreMedia
import Foundation

// Adjustment layers (see docs/effects.md, "Adjustment layers"): layers of
// adjustment clips, whose stacks are applied to the layers below them, each
// clip as far down as its own reach.

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

    /// Sets how far down an adjustment clip reaches: down to the layer
    /// `bottomLayerID`, or every layer below it for nil.
    mutating func setReach(ofClip clipID: UUID, in timelineID: UUID, toLayer bottomLayerID: UUID?) {
        guard let timeline = timeline(id: timelineID),
              let clip = clipAndLayer(clipID, in: timelineID)?.clip, clip.source == .adjustment
        else {
            return
        }
        if let bottomLayerID, timeline.layer(id: bottomLayerID) == nil { return }
        editClip(clipID, in: timelineID) { $0.reach = bottomLayerID }
    }

    /// The layers an adjustment clip on `layer` reaches, top to bottom, and
    /// whether that is every layer below it: those below its layer down to
    /// the one it reaches to. None when that layer has been moved above it.
    func reach(of clip: TimelineClip, on layer: TimelineLayer, in timeline: Timeline) -> (layers: [TimelineLayer], all: Bool) {
        guard clip.source == .adjustment, let index = timeline.layers.firstIndex(where: { $0.id == layer.id }) else { return ([], false) }
        let below = Array(timeline.layers[(index + 1)...])
        guard let bottom = clip.reach, let bottomIndex = timeline.layers.firstIndex(where: { $0.id == bottom }) else {
            return (below, true)
        }
        guard bottomIndex > index else { return ([], false) }
        return (Array(timeline.layers[(index + 1)...bottomIndex]), false)
    }

    /// The layers an adjustment clip on `layer` reaches, top to bottom.
    func reachedLayers(of clip: TimelineClip, on layer: TimelineLayer, in timeline: Timeline) -> [TimelineLayer] {
        reach(of: clip, on: layer, in: timeline).layers
    }

    /// Whether the layer an adjustment clip reaches down to is above it, so
    /// it reaches nothing.
    func reachesNothing(_ clip: TimelineClip, on layer: TimelineLayer, in timeline: Timeline) -> Bool {
        guard clip.source == .adjustment, clip.reach != nil else { return false }
        return reachedLayers(of: clip, on: layer, in: timeline).isEmpty
    }

    /// What an adjustment clip reaches, in words, for its menu and notes.
    func reachDescription(of clip: TimelineClip, in timeline: Timeline) -> String {
        guard let bottom = clip.reach, let target = timeline.layer(id: bottom) else { return "All Layers Below" }
        return "Down to \(displayName(of: target, in: timeline))"
    }
}
