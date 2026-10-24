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
        guard kind.drawsShape, let tIndex = timelines.firstIndex(id: timelineID) else { return nil }
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
        timelines[tIndex].layers.insert(layer, clampedAt: index)
        return (layer.id, clip.id)
    }
}

/// What adding an effect from the Effects Library did.
enum LibraryAddition: Equatable {
    /// Added the effect with this ID to the clip.
    case effect(UUID)
    /// Made a shape layer holding the shape.
    case shapeLayer(layerID: UUID, clipID: UUID)
}

extension EditingProject {
    /// Adds `kind` as a double-click in the Effects Library does: to the
    /// selected clip, except that a shape joins only a selected shape clip
    /// and otherwise starts a shape layer of its own at `playhead`. Nil when
    /// nothing could take it.
    mutating func addFromLibrary(_ kind: EffectKind, in timelineID: UUID, selectedClip: UUID?, playhead: CMTime) -> LibraryAddition? {
        let selected = selectedClip.flatMap { clipAndLayer($0, in: timelineID)?.clip }
        if kind.drawsShape, selected?.source != .graphic {
            return addShapeLayer(kind, to: timelineID, from: playhead).map { .shapeLayer(layerID: $0.layerID, clipID: $0.clipID) }
        }
        guard let selected else { return nil }
        return addEffect(kind, toClip: selected.id, in: timelineID).map { .effect($0) }
    }
}
