import CoreGraphics
import CoreMedia
import Foundation

extension EffectKind {
    /// What the browser's Generators tab lists, in its order: text, then
    /// the shapes. Each makes a clip of its own on the timeline (a graphic
    /// clip holding it) rather than going into another clip's stack, so
    /// none of them is in the Effects Library.
    static var generators: [EffectKind] {
        let shapes = all.filter(\.drawsShape)
        return shapes.filter { $0 == .text } + shapes.filter { $0 != .text }
    }
}

extension Effect {
    /// Sizes a new shape to a frame `frame` big: a rectangle half its width
    /// and height, an ellipse a circle half its height, a polygon or star
    /// as tall (its inner points halfway in), and text a ninth of its
    /// height (120 pixels in HD).
    mutating func sizeShape(to frame: CGSize) {
        let side = Double(frame.height / 2).rounded()
        func set(_ kind: ControlKind, _ values: [Double]) {
            changeControl(kind) { $0.number = AnimatedValue(ComponentValue(values: values)) }
        }
        switch kind {
        case .rectangle: set(.shapeSize, [Double(frame.width / 2).rounded(), side])
        case .ellipse: set(.shapeSize, [side, side])
        case .polygon, .star:
            set(.radius, [side / 2])
            set(.innerRadius, [(side / 4).rounded()])
        case .text: set(.fontSize, [max(1, Double(frame.height / 9).rounded())])
        default: break
        }
    }
}

extension EditingProject {
    /// Whether `kind` can go into `clip`'s stack. Text and the shapes are
    /// generators, not effects: they only go into a graphic clip, the clip
    /// a generator makes, where another one drawn below can follow it (text
    /// on the path of the shape above). Everything else goes by
    /// `addEffect`'s own rules.
    func stack(of clip: TimelineClip, takes kind: EffectKind) -> Bool {
        !kind.drawsShape || clip.source == .graphic
    }

    /// A graphic clip from `start` lasting `duration` (at least a frame),
    /// holding one generator of `kind` sized to the frame.
    private func generatorClip(_ kind: EffectKind, in timeline: Timeline, from start: CMTime, duration: CMTime) -> TimelineClip {
        let length = CMTimeMaximum(timeline.frameDuration, timeline.frameAligned(duration, .down))
        var shape = Effect(kind: kind)
        shape.sizeShape(to: timeline.frameSize)
        var clip = TimelineClip(
            source: .graphic, startOffset: timeline.frameAligned(start, .nearest),
            trimStart: .zero, trimEnd: length, streams: .video
        )
        clip.effects = [shape]
        return clip
    }

    /// Puts a video layer at `index` (the top by default) holding a clip
    /// of the generator `kind` (text or a shape) from `start`, sized to the
    /// frame (see `Effect.sizeShape`). Lasts `duration`, five seconds
    /// unless given.
    @discardableResult
    mutating func addShapeLayer(
        _ kind: EffectKind = .rectangle,
        to timelineID: UUID,
        at index: Int = 0,
        from start: CMTime = .zero,
        duration: CMTime = MediaClip.stillLength
    ) -> (layerID: UUID, clipID: UUID)? {
        guard kind.drawsShape, let tIndex = timelines.firstIndex(id: timelineID) else { return nil }
        let clip = generatorClip(kind, in: timelines[tIndex], from: start, duration: duration)
        let layer = TimelineLayer(customName: nil, kind: .video, clips: [clip])
        timelines[tIndex].layers.insert(layer, clampedAt: index)
        return (layer.id, clip.id)
    }

    /// Puts a clip of the generator `kind` on the layer `layerID` at
    /// `start`, landing as a clip moved there would (see `insertion`):
    /// inside a clip it goes to the nearer edge and the clips after it move
    /// right to make room. A layer that can't take it (audio, adjustment)
    /// gets a new video layer above it instead. Lasts five seconds.
    @discardableResult
    mutating func addGenerator(
        _ kind: EffectKind, to timelineID: UUID, onLayer layerID: UUID, at start: CMTime
    ) -> (layerID: UUID, clipID: UUID)? {
        guard kind.drawsShape, let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID)
        else { return nil }
        let timeline = timelines[tIndex]
        var clip = generatorClip(kind, in: timeline, from: start, duration: MediaClip.stillLength)
        let layer = timeline.layers[lIndex]
        guard self.layer(layer, accepts: clip) else {
            return addShapeLayer(kind, to: timelineID, at: lIndex, from: start)
        }
        var others = layer.clips
        let move = insertion(lasting: clip.placedDuration, frameLocked: isFrameLocked(clip), among: others, in: timeline, at: start)
        others.makeRoom(for: move)
        clip.startOffset = move.start
        others.append(clip)
        timelines[tIndex].layers[lIndex].clips = others.sorted { $0.startOffset < $1.startOffset }
        return (layer.id, clip.id)
    }
}
