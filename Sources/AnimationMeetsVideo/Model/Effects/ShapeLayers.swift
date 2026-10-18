import CoreGraphics
import CoreMedia
import Foundation

extension Effect {
    /// Sizes a new shape to a frame `frame` big: a rectangle half its width
    /// and height, an ellipse a circle half its height, and a polygon or
    /// star as tall (its inner points halfway in).
    mutating func sizeShape(to frame: CGSize) {
        let side = Double(frame.height / 2).rounded()
        func set(_ kind: ControlKind, _ values: [Double]) {
            guard let index = controls.firstIndex(where: { $0.kind == kind }) else { return }
            controls[index].number = AnimatedValue(ComponentValue(values: values))
        }
        switch kind {
        case .rectangle: set(.shapeSize, [Double(frame.width / 2).rounded(), side])
        case .ellipse: set(.shapeSize, [side, side])
        case .polygon, .star:
            set(.radius, [side / 2])
            set(.innerRadius, [(side / 4).rounded()])
        default: break
        }
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
        guard kind.drawsShape, let tIndex = timelines.firstIndex(where: { $0.id == timelineID }) else { return nil }
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
