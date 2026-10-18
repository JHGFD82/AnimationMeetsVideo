import CoreGraphics
import CoreMedia
import Foundation

extension Effect {
    /// Sizes a new shape to a frame `frame` big: a rectangle half its width
    /// and height, an ellipse a circle half its height.
    mutating func sizeShape(to frame: CGSize) {
        guard kind.isShape, let size = controls.firstIndex(where: { $0.kind == .shapeSize }) else { return }
        let side = Double(frame.height / 2).rounded()
        let values = kind == .ellipse ? [side, side] : [Double(frame.width / 2).rounded(), side]
        controls[size].number = AnimatedValue(ComponentValue(values: values))
    }
}

extension EditingProject {
    /// Puts a video layer at `index` (the top by default) holding a shape
    /// clip from `start`, with one shape of `kind` sized to the frame (see
    /// `Effect.sizeShape`). Lasts `duration`, five seconds unless given.
    @discardableResult
    mutating func addShapeLayer(
        _ kind: EffectKind = .rectangle,
        to timelineID: UUID,
        at index: Int = 0,
        from start: CMTime = .zero,
        duration: CMTime = MediaClip.stillLength
    ) -> (layerID: UUID, clipID: UUID)? {
        guard kind.isShape, let tIndex = timelines.firstIndex(where: { $0.id == timelineID }) else { return nil }
        let timeline = timelines[tIndex]
        let length = CMTimeMaximum(timeline.frameDuration, timeline.frameAligned(duration, .down))
        var shape = Effect(kind: kind)
        shape.sizeShape(to: timeline.frameSize)
        var clip = TimelineClip(
            source: .graphic, startOffset: timeline.frameAligned(start, .nearest),
            trimStart: .zero, trimEnd: length, streams: .video
        )
        clip.effects = [shape]
        let layer = TimelineLayer(customName: nil, kind: .video, clips: [clip])
        timelines[tIndex].layers.insert(layer, at: min(max(index, 0), timelines[tIndex].layers.count))
        return (layer.id, clip.id)
    }
}
