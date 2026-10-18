import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import os
import QuartzCore

/// One stretch of a timeline for `LayeredCompositor`: the clips drawn in
/// it, top first, as a tree (see `DrawClip`).
final class LayeredInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    /// The track whose frames are the stretch's frames as they are, for one
    /// picture that needs no drawing; invalid otherwise.
    let passthroughTrackID: CMPersistentTrackID
    let clips: [DrawClip]
    /// The timeline's frame size. The player may draw smaller than this.
    let renderSize: CGSize
    let colorSpace: ProjectColorSpace
    /// How far past the frame, as a fraction of its size on each side,
    /// pictures that are moved off it are kept for later steps.
    let canvasMargin: Double
    /// Told how long each frame took, when the viewer is watching.
    let meter: RenderMeter?
    /// What the viewer asks of drawing while it plays; nil to draw everything
    /// at full quality, as export does.
    let options: DrawingOptions?
    /// Where the frames it is drawn from are kept, for the viewer to draw
    /// the frame again with new values without decoding (see
    /// `LiveFrameRenderer`); nil to keep nothing.
    let capture: SourceCapture?

    init(
        timeRange: CMTimeRange, clips: [DrawClip], passthrough: CMPersistentTrackID = kCMPersistentTrackID_Invalid,
        renderSize: CGSize, colorSpace: ProjectColorSpace, canvasMargin: Double = EditingProject.defaultCanvasMargin,
        meter: RenderMeter? = nil, options: DrawingOptions? = nil, capture: SourceCapture? = nil
    ) {
        self.timeRange = timeRange
        self.clips = clips
        passthroughTrackID = passthrough
        self.renderSize = renderSize
        self.colorSpace = colorSpace
        self.canvasMargin = canvasMargin
        self.meter = meter
        self.options = options
        self.capture = capture
        requiredSourceTrackIDs = Set(clips.flatMap(\.allTrackIDs)).sorted().map { NSNumber(value: $0) }
    }

    /// The same stretch drawing `clips` instead.
    func drawing(_ clips: [DrawClip], capture: SourceCapture? = nil) -> LayeredInstruction {
        LayeredInstruction(
            timeRange: timeRange, clips: clips, passthrough: passthroughTrackID, renderSize: renderSize,
            colorSpace: colorSpace, canvasMargin: canvasMargin, meter: meter, options: options, capture: capture
        )
    }
}

/// The decoded frames one frame of the viewer was drawn from, by track, with
/// the stretch's instruction and the size it was drawn at, kept so the frame
/// can be drawn again with new values. Written by the compositor's queue,
/// read after the frame is done.
final class SourceCapture: @unchecked Sendable {
    struct Recorded {
        var instruction: LayeredInstruction
        var frames: [CMPersistentTrackID: CVPixelBuffer]
        var size: CGSize
    }

    private let lock = NSLock()
    private var drawn: Recorded?

    func record(_ instruction: LayeredInstruction, frames: [CMPersistentTrackID: CVPixelBuffer], size: CGSize) {
        lock.withLock { drawn = Recorded(instruction: instruction, frames: frames, size: size) }
    }

    var recorded: Recorded? { lock.withLock { drawn } }
}

/// Draws a timeline with Core Image on the GPU through Metal, for the viewer
/// and for export alike. Each clip goes through its stack and then its
/// transitions and is drawn over the clips below it; a nested timeline is
/// drawn first on transparency, as one picture, unless it passes through.
///
/// Geometry is worked out in each timeline's frame, in pixels with the
/// origin at the top left and y down, as AVFoundation does; Core Image's
/// origin is at the bottom left, so each picture is flipped into that space
/// and back out. The viewer may ask for a smaller size: every picture is
/// then drawn straight to it, rather than drawing full size and scaling.
///
/// It works on the frames' encoded values, without color management, so
/// the film dissolve keys on brightness as it looks rather than as light.
class LayeredCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ]
        return MetalDevice.shared.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()
    private let queue = DispatchQueue(label: "LayeredCompositor", qos: .userInitiated)
    /// Bumped when the player gives up on the requests it has made, as on
    /// a seek: those still queued are let go undrawn.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    /// The format frames are decoded into and drawn in. Half floats keep
    /// HDR sources and timelines intact.
    class var pixelFormat: OSType { kCVPixelFormatType_64RGBAHalf }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [Self.pixelFormat]]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [Self.pixelFormat]]
    }
    var supportsWideColorSourceFrames: Bool { Self.pixelFormat == kCVPixelFormatType_64RGBAHalf }
    var supportsHDRSourceFrames: Bool { Self.pixelFormat == kCVPixelFormatType_64RGBAHalf }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let requestedIn = generation.withLock { $0 }
        queue.async { [self] in
            guard generation.withLock({ $0 }) == requestedIn else {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? LayeredInstruction,
                      let output = request.renderContext.newPixelBuffer()
                else {
                    request.finish(with: CompositionError.exportFailed("A frame couldn't be drawn."))
                    return
                }
                let started = CACurrentMediaTime()
                let size = request.renderContext.size
                if let capture = instruction.capture {
                    // Every frame it may draw, kept for drawing it again.
                    var frames: [CMPersistentTrackID: CVPixelBuffer] = [:]
                    for value in instruction.requiredSourceTrackIDs ?? [] {
                        guard let id = (value as? NSNumber)?.int32Value else { continue }
                        frames[id] = request.sourceFrame(byTrackID: id)
                    }
                    capture.record(instruction, frames: frames, size: size)
                }
                let image = Self.compose(instruction, at: request.compositionTime, outputSize: size) {
                    request.sourceFrame(byTrackID: $0)
                }
                context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
                instruction.colorSpace.attach(to: output)
                instruction.meter?.record(renderSeconds: CACurrentMediaTime() - started)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    /// Lets go of the queued requests rather than drawing them first; the
    /// one being drawn finishes as usual.
    func cancelAllPendingVideoCompositionRequests() {
        generation.withLock { $0 += 1 }
    }

    /// The frame at `time`: the instruction's clips from the bottom up over
    /// black.
    static func compose(
        _ instruction: LayeredInstruction,
        at time: CMTime,
        outputSize: CGSize,
        frame: @escaping (CMPersistentTrackID) -> CVPixelBuffer?
    ) -> CIImage {
        let renderSize = instruction.renderSize
        let bounds = CGRect(origin: .zero, size: outputSize)
        // The render context may be smaller than the timeline's frame, as
        // when the player draws at a reduced size.
        let scale = renderSize.width > 0 ? outputSize.width / renderSize.width : 1
        let drawing = Drawing(
            time: time,
            scale: CGSize(width: scale, height: renderSize.height > 0 ? outputSize.height / renderSize.height : 1),
            canvasMargin: instruction.canvasMargin,
            options: instruction.options,
            source: frame
        )
        let black = CIImage(color: .black).cropped(to: bounds)
        return drawing.draw(instruction.clips, frame: renderSize, over: black, outer: .identity).cropped(to: bounds)
    }

    /// White where the picture is bright enough to show through by now,
    /// black where it isn't, with a soft edge between.
    static func revealMask(of image: CIImage, _ reveal: LumaReveal) -> CIImage {
        let (gain, bias) = reveal.gainAndBias
        let weights = CIVector(x: 0.2126 * gain, y: 0.7152 * gain, z: 0.0722 * gain, w: 0)
        return image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": weights,
                "inputGVector": weights,
                "inputBVector": weights,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
    }
}

/// How the clips of a pass-through nested timeline are placed in the
/// timeline it passes through to: from their own frame into that one.
struct OuterPlacement {
    var matrix = CGAffineTransform.identity
    var opacity = 1.0
    /// Whether the clips are those of a pass-through nested timeline,
    /// drawn straight into the timeline above. An adjustment layer in one
    /// reaches no further than that nested timeline's own layers.
    var passesThrough = false

    static let identity = OuterPlacement()
}

/// Draws one frame: the clips of a timeline, then those of the timelines
/// nested in them.
struct Drawing {
    var time: CMTime
    /// Output pixels per frame pixel, in each direction.
    let scale: CGSize
    /// How far past a frame's edges pictures are kept, as a fraction of its
    /// size.
    let canvasMargin: Double
    /// What the viewer asks of drawing while it plays, if it is the viewer.
    var options: DrawingOptions?
    /// The decoded frame of a composition track at `time`.
    let source: (CMPersistentTrackID) -> CVPixelBuffer?

    /// The same drawing at another moment.
    func at(_ time: CMTime) -> Drawing {
        var moved = self
        moved.time = time
        return moved
    }

    /// `clips` (top first) drawn bottom first over `output`, which holds
    /// the timeline whose frame is `frameSize`, in output pixels with the
    /// origin at the bottom left. Clips of a nested timeline that passes
    /// through are drawn here too, `outer` placing them.
    func draw(_ clips: [DrawClip], frame frameSize: CGSize, over output: CIImage, outer: OuterPlacement) -> CIImage {
        var output = output
        for clip in clips.reversed() {
            output = draw(clip, frame: frameSize, over: output, outer: outer)
        }
        return output
    }

    private func draw(_ clip: DrawClip, frame frameSize: CGSize, over output: CIImage, outer: OuterPlacement) -> CIImage {
        if case .adjustment(let adjustment) = clip.content {
            return drawAdjustment(
                clip, adjustment, resolved: clip.stack.resolve(atRoot: time), frame: frameSize, over: output, outer: outer
            )
        }
        // Which moment a nested timeline's pictures are drawn at is the
        // drawing's own time; so a group is drawn through `at`.
        guard var picture = finishedPicture(clip, at: time, frame: frameSize, over: output, outer: outer) else { return output }
        let shutter = clip.stack.shutter

        // Motion blur: the finished clip drawn at moments across the shutter
        // and averaged. The viewer draws fewer while playing.
        if let blur = shutter.motionBlur?.clamped {
            let samples = options.map { $0.motionBlurSamples(wanted: blur.samples) } ?? blur.samples
            let open = clip.stack.frameDuration.seconds > 0 ? clip.stack.frameDuration.seconds : 1.0 / 24
            let shutterSeconds = open * blur.angle / 360
            if samples > 1, shutterSeconds > 0 {
                let weight = CGFloat(1) / CGFloat(samples)
                var sum: CIImage?
                for index in 0..<samples {
                    let moment = CMTimeAdd(time, CMTime(seconds: shutterSeconds * ((Double(index) + 0.5) / Double(samples) - 0.5), preferredTimescale: 240_000))
                    guard let sample = finishedPicture(clip, at: moment, frame: frameSize, over: output, outer: outer) else { continue }
                    // The matrix works on colors before they are multiplied by
                    // alpha, so scaling alpha alone scales the picture.
                    let scaled = sample.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: weight)])
                    sum = sum.map { scaled.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? scaled
                }
                if let sum { picture = sum }
            }
        }

        // Trails: copies of the finished clip from earlier moments, under it,
        // the furthest first.
        if case .media(let media) = clip.content, !media.trails.isEmpty {
            var under: CIImage?
            for trail in media.trails.reversed() {
                let moment = CMTimeSubtract(time, trail.delay)
                guard let copy = finishedPicture(clip, at: moment, frame: frameSize, over: output, outer: outer, trail: trail) else { continue }
                let faded = trail.strength == 1 ? copy : copy.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(trail.strength)),
                ])
                under = under.map { faded.composited(over: $0) } ?? faded
            }
            if let under { picture = picture.composited(over: under) }
        }
        let together = picture.composited(over: output)
        // A transition drawn from two whole pictures takes what's under the
        // clip and the clip over it, and its result replaces both.
        guard let transition = clip.stack.transitionFrame(atRoot: time) else { return together }
        let bounds = CGRect(x: 0, y: 0, width: frameSize.width * scale.width, height: frameSize.height * scale.height)
        return TransitionRenderer.draw(
            transition,
            from: transition.entering ? output : together,
            to: transition.entering ? together : output,
            in: bounds
        )
    }

    /// The clip as it finishes, at root time `time`: its picture put into the
    /// frame, run through its stack and its transitions, before it is drawn
    /// over what is below. With `trail` the footage is that copy's.
    private func finishedPicture(
        _ clip: DrawClip,
        at time: CMTime,
        frame frameSize: CGSize,
        over output: CIImage,
        outer: OuterPlacement,
        trail: TrackCopy? = nil
    ) -> CIImage? {
        let resolved = clip.stack.resolve(atRoot: time)
        let transition = resolved.transition
        // From the frame's pixels (origin top left) to output pixels.
        let toOutput = Self.flip(height: frameSize.height).concatenating(CGAffineTransform(scaleX: scale.width, y: scale.height))
        /// A transform of the frame's pixels as one of output pixels.
        func inOutput(_ matrix: CGAffineTransform) -> CGAffineTransform {
            toOutput.inverted().concatenating(matrix).concatenating(toOutput)
        }

        // What places the clip's own frame in the one it is drawn into (a
        // pass-through or pushed nested timeline) is applied to the picture
        // first, and each move after it is turned to work in the placed
        // frame. That is the same picture as applying it last, and it means
        // blending and grading work at the size the picture ends up. A
        // placement that can't be undone is applied last.
        let start = outer.matrix.isInvertibleMatrix ? outer.matrix : .identity
        let startInverse = start.inverted()
        func placed(_ matrix: CGAffineTransform) -> CGAffineTransform {
            start == .identity ? matrix : startInverse.concatenating(matrix).concatenating(start)
        }

        // The stack, which a nested timeline's leading move is taken out of
        // when it is pushed into the layers inside.
        var steps = resolved.steps
        var opacity = 1.0
        // Whether the transition's move is already part of the matrix pushed
        // into a nested timeline's layers.
        var transitionPushed = false

        // The picture, put into the frame.
        var picture: CIImage
        switch clip.content {
        case .adjustment:
            return nil
        case .graphic:
            // Transparency, for the stack's shapes to draw on.
            picture = .empty()
        case .media(let media):
            guard let image = sourcePicture(of: media, clip: clip, at: time, trail: trail) else { return nil }
            picture = image.transformed(
                by: Self.flip(height: image.extent.height).concatenating(media.base).concatenating(start).concatenating(toOutput)
            )
        case .group(let group):
            let placement = resolved.placement
            if group.passThrough {
                // The nested layers go straight into this timeline, each
                // placed as the group is. Only what works layer by layer
                // applies: wipes and the film dissolve need one picture.
                let combined = OuterPlacement(
                    matrix: group.toOuter
                        .concatenating(placement.matrix)
                        .concatenating(transition?.transform ?? .identity)
                        .concatenating(outer.matrix),
                    opacity: placement.opacity * (transition?.opacity ?? 1) * outer.opacity,
                    passesThrough: true
                )
                return at(time).draw(group.children, frame: frameSize, over: output, outer: combined)
            }
            if group.pushesTransforms, placement.matrix.isInvertibleMatrix {
                // The nested layers are drawn at the size they end up, with
                // the group's move applied to each of them over
                // transparency, rather than drawn at the nested frame's size
                // and enlarged. That is the same picture where every step
                // inside is per pixel, and keeps detail a smaller nested
                // frame would lose. Opacity stays on the whole.
                var geometry = group.toOuter
                if case .place(let matrix, let factor)? = steps.first {
                    geometry = geometry.concatenating(matrix)
                    opacity *= factor
                    steps.removeFirst()
                }
                if steps.isEmpty, let transition {
                    geometry = geometry.concatenating(transition.transform)
                    transitionPushed = true
                }
                geometry = geometry.concatenating(start)
                let layers = at(time).draw(group.children, frame: frameSize, over: .empty(), outer: OuterPlacement(matrix: geometry, opacity: 1))
                picture = Self.limited(layers, toNestedFrame: group.frameSize, through: geometry.concatenating(toOutput))
            } else {
                let nestedBounds = CGRect(x: 0, y: 0, width: group.frameSize.width * scale.width, height: group.frameSize.height * scale.height)
                let nested = at(time).draw(group.children, frame: group.frameSize, over: .empty(), outer: .identity).cropped(to: nestedBounds)
                let toFrame = CGAffineTransform(scaleX: 1 / scale.width, y: 1 / scale.height)
                    .concatenating(Self.flip(height: group.frameSize.height))
                    .concatenating(group.toOuter)
                picture = nested.transformed(by: toFrame.concatenating(start).concatenating(toOutput))
            }
        }

        // The stack. Opacity waits until something needs the picture's own
        // alpha, so consecutive moves stay one transform.
        picture = runStack(
            steps, on: picture, opacity: &opacity, backdrop: output, clip: clip, frame: frameSize,
            start: start, inOutput: inOutput, placed: placed
        )
        func settleOpacity() {
            guard opacity != 1 else { return }
            picture = picture.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
            opacity = 1
        }

        // Then the transitions, then, for a placement that couldn't be
        // applied first, the placement.
        if let transition {
            if !transitionPushed { picture = picture.transformed(by: inOutput(placed(transition.transform))) }
            opacity *= transition.opacity
        }
        if start == .identity, outer.matrix != .identity { picture = picture.transformed(by: inOutput(outer.matrix)) }
        opacity *= outer.opacity

        if var visible = transition?.visibleRect {
            // In the clip's own frame; a pass-through group places it in
            // the frame it passes to.
            visible = visible.applying(outer.matrix)
            picture = picture.cropped(to: CGRect(
                x: visible.minX * scale.width, y: (frameSize.height - visible.maxY) * scale.height,
                width: visible.width * scale.width, height: visible.height * scale.height
            ))
        }
        settleOpacity()
        if let reveal = transition?.lumaReveal {
            // On the way in the clip is the following picture; on the way
            // out it is what's underneath, and the clip stays where that
            // hasn't come through yet.
            var mask = LayeredCompositor.revealMask(of: reveal.keysIncoming ? picture : output, reveal)
            if !reveal.keysIncoming { mask = mask.applyingFilter("CIColorInvert") }
            picture = picture.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ])
        }
        return picture
    }

    /// A media clip's picture at root time `time`, before anything is done
    /// to it: the frame it is at, mixed with the next by how far between
    /// the two the moment falls (Blend), with earlier frames layered under
    /// it (Echo). With `trail`, that copy's footage as it is.
    private func sourcePicture(of media: MediaDraw, clip: DrawClip, at time: CMTime, trail: TrackCopy?) -> CIImage? {
        func frame(_ trackID: CMPersistentTrackID) -> CIImage? {
            source(trackID).map { CIImage(cvPixelBuffer: $0, options: [.colorSpace: NSNull()]) }
        }
        func scaled(_ image: CIImage, by strength: Double) -> CIImage {
            guard strength < 1 else { return image }
            return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(strength))])
        }
        // A still is the same picture at every moment, and has no other
        // frames to mix in.
        if let still = media.still { return still.image }
        guard var image = frame(trail?.trackID ?? media.trackID) else { return nil }
        if trail != nil { return image }

        if let next = media.nextFrame, media.frameDuration.seconds > 0, let later = frame(next.trackID) {
            // How far past the frame the moment is in the file.
            let local = clip.stack.localTime(atRoot: time)
            let position = (clip.stack.sourceTime(atLocal: local).seconds + media.alignmentOffset.seconds) / media.frameDuration.seconds
            let fraction = position - (position + 1e-6).rounded(.down)
            if fraction > 0.01 {
                // Optical Flow moves the frames along the motion between
                // them. It costs too much to do while the viewer plays or
                // is drawing for display; renders and export do (they draw
                // without options). Where it can't be done, it fades.
                if media.opticalFlow, options == nil, let moved = OpticalFlow.between(image, later, fraction: fraction) {
                    image = moved
                } else {
                    image = scaled(later, by: fraction).composited(over: image)
                }
            }
        }
        var under: CIImage?
        for echo in media.echoes.reversed() {
            guard let earlier = frame(echo.trackID) else { continue }
            let faded = scaled(earlier, by: echo.strength)
            under = under.map { faded.composited(over: $0) } ?? faded
        }
        if let under { image = image.composited(over: under) }
        return image
    }

    /// An adjustment clip: its stack is run on the layers it reaches drawn
    /// together over what is below them (`output`), and the result is mixed
    /// into what is below by how much the reached layers cover:
    ///
    /// 1. Below: `output`, the layers under the reach.
    /// 2. With: the reached layers drawn over it, as usual.
    /// 3. Adjusted: the stack run on With. A Blending step's backdrop is With.
    /// 4. Coverage: the alpha of the reached layers alone over transparency;
    ///    the whole frame when it reaches every layer below.
    /// 5. Result: Below mixed toward Adjusted by Coverage.
    ///
    /// Inside a pass-through nested timeline it reaches no further than that
    /// timeline's own layers, so only they are adjusted, and drawn over
    /// `output` as they are.
    private func drawAdjustment(
        _ clip: DrawClip,
        _ adjustment: AdjustmentDraw,
        resolved: ResolvedClip,
        frame frameSize: CGSize,
        over output: CIImage,
        outer: OuterPlacement
    ) -> CIImage {
        let passes = outer.passesThrough
        let transition = resolved.transition
        guard !resolved.steps.isEmpty || transition != nil else {
            return draw(adjustment.reached, frame: frameSize, over: output, outer: outer)
        }
        let toOutput = Self.flip(height: frameSize.height).concatenating(CGAffineTransform(scaleX: scale.width, y: scale.height))
        func inOutput(_ matrix: CGAffineTransform) -> CGAffineTransform {
            toOutput.inverted().concatenating(matrix).concatenating(toOutput)
        }
        let start = outer.matrix.isInvertibleMatrix ? outer.matrix : .identity
        let startInverse = start.inverted()
        func placed(_ matrix: CGAffineTransform) -> CGAffineTransform {
            start == .identity ? matrix : startInverse.concatenating(matrix).concatenating(start)
        }

        let with = draw(adjustment.reached, frame: frameSize, over: passes ? .empty() : output, outer: outer)
        var opacity = 1.0
        var adjusted = runStack(
            resolved.steps, on: with, opacity: &opacity, backdrop: with, clip: clip, frame: frameSize,
            start: start, inOutput: inOutput, placed: placed
        )
        if let transition {
            adjusted = adjusted.transformed(by: inOutput(placed(transition.transform)))
            opacity *= transition.opacity
        }
        opacity *= outer.opacity

        let bounds = CGRect(x: 0, y: 0, width: frameSize.width * scale.width, height: frameSize.height * scale.height)
        if passes {
            if opacity != 1 {
                adjusted = adjusted.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
            }
            return adjusted.composited(over: output)
        }
        var coverage = adjustment.reachesAll
            ? CIImage(color: .white).cropped(to: bounds)
            : draw(adjustment.reached, frame: frameSize, over: .empty(), outer: outer)
        if var visible = transition?.visibleRect {
            visible = visible.applying(outer.matrix)
            coverage = coverage.cropped(to: CGRect(
                x: visible.minX * scale.width, y: (frameSize.height - visible.maxY) * scale.height,
                width: visible.width * scale.width, height: visible.height * scale.height
            ))
        }
        if opacity != 1 {
            coverage = coverage.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
        }
        return adjusted.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: output,
            kCIInputMaskImageKey: coverage,
        ]).cropped(to: bounds.union(output.extent.isInfinite ? bounds : output.extent))
    }

    /// The steps of a clip's stack run on `picture`, in output pixels.
    /// Opacity the steps ask for is left in `opacity` for the caller.
    ///
    /// Shapes stay outlines while only moves follow them: each move is
    /// applied to their outlines as well as to the picture, and they are
    /// drawn, over the picture, when a step needs pixels or the stack ends.
    /// So a shape scaled up is drawn at the size it ends up, not enlarged.
    /// Their edges are kept after they are drawn, for a Stroke step to
    /// follow, until a Matte or Blending step changes what they cover.
    private func runStack(
        _ steps: [ResolvedStep],
        on initial: CIImage,
        opacity: inout Double,
        backdrop: CIImage,
        clip: DrawClip,
        frame frameSize: CGSize,
        start: CGAffineTransform,
        inOutput: (CGAffineTransform) -> CGAffineTransform,
        placed: (CGAffineTransform) -> CGAffineTransform
    ) -> CIImage {
        var picture = initial
        var kept: [UUID: CIImage] = [:]
        // Shapes not yet drawn, over the picture, bottom first.
        var shapes: [ShapeRendering.Paint] = []
        // The edges of the shapes drawn so far, strokes included.
        var edges: [ShapeRendering.Edge] = []
        // From the frame's pixels to output pixels, where the clip's own
        // frame is placed: where a shape added now is drawn from.
        let frameToOutput = start
            .concatenating(Self.flip(height: frameSize.height))
            .concatenating(CGAffineTransform(scaleX: scale.width, y: scale.height))
        func settleOpacity() {
            guard opacity != 1 else { return }
            picture = picture.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
            for index in shapes.indices { shapes[index].alpha *= opacity }
            opacity = 1
        }
        func drawShapes() {
            guard !shapes.isEmpty else { return }
            if let drawn = ShapeRendering.draw(shapes, within: canvasRect(of: frameSize)) {
                picture = drawn.composited(over: picture)
            }
            shapes = []
        }
        for step in steps {
            switch step {
            case .place(let matrix, let factor):
                let move = inOutput(placed(matrix))
                picture = picture.transformed(by: move)
                for index in shapes.indices { shapes[index].transform = shapes[index].transform.concatenating(move) }
                for index in edges.indices { edges[index].transform = edges[index].transform.concatenating(move) }
                opacity *= factor
            case .shape(let shape):
                // Over the picture as the steps above left it, opacity and
                // all; the steps below act on both.
                settleOpacity()
                for paint in shape.paints {
                    shapes.append(ShapeRendering.Paint(area: paint.area, color: paint.color, transform: frameToOutput))
                }
                edges.append(ShapeRendering.Edge(area: shape.edge, transform: frameToOutput))
            case .outlineStroke(let style):
                // Around everything the shapes above drew, strokes and all,
                // where those shapes now are.
                settleOpacity()
                guard let outline = ShapeRendering.union(of: edges, current: frameToOutput) else { continue }
                let area = style.area(around: outline)
                shapes.append(ShapeRendering.Paint(area: area, color: style.color, transform: frameToOutput))
                edges.append(ShapeRendering.Edge(area: area, transform: frameToOutput))
            case .mark(let id):
                settleOpacity()
                drawShapes()
                kept[id] = picture
            case .color(let ops):
                drawShapes()
                // Grading doesn't depend on where a pixel is, so it doesn't
                // wait for the opacity either.
                let canvas = canvasRect(of: frameSize)
                if let graded = ColorProcessor.grade(picture, ops, in: clip.stack.colorSpace, over: picture.extent.intersection(canvas)) {
                    picture = graded
                }
            case .matte(let effectID, let mode, let amount):
                settleOpacity()
                drawShapes()
                edges = []
                guard let input = clip.inputs[effectID], let matte = matteImage(input, frame: frameSize, start: start) else { continue }
                picture = cut(picture, by: matte, mode: mode, amount: amount, frame: frameSize)
            case .blend(let mode, let amount, let against):
                settleOpacity()
                drawShapes()
                edges = []
                let other: CIImage
                if let against {
                    guard let earlier = kept[against] else { continue }
                    other = earlier
                } else {
                    other = backdrop
                }
                let canvas = canvasRect(of: frameSize)
                var region = picture.extent.intersection(canvas)
                if against != nil { region = region.union(other.extent.intersection(canvas)) }
                if let blended = BlendProcessor.blend(
                    picture, with: other, mode: mode, amount: amount, keepsBackdrop: against != nil, over: region
                ) {
                    picture = blended
                }
            }
        }
        drawShapes()
        return picture
    }

    /// An effect's input as a picture in the clip's frame, in output pixels:
    /// fitted into the frame and left there, whatever later steps do.
    private func matteImage(_ input: InputDraw, frame frameSize: CGSize, start: CGAffineTransform) -> CIImage? {
        let toOutput = Self.flip(height: frameSize.height).concatenating(CGAffineTransform(scaleX: scale.width, y: scale.height))
        switch input {
        case .track(let copy, let base):
            guard let buffer = source(copy.trackID) else { return nil }
            let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            return image.transformed(
                by: Self.flip(height: image.extent.height).concatenating(base).concatenating(start).concatenating(toOutput)
            )
        case .group(let group):
            let bounds = CGRect(x: 0, y: 0, width: group.frameSize.width * scale.width, height: group.frameSize.height * scale.height)
            let nested = draw(group.children, frame: group.frameSize, over: .empty(), outer: .identity).cropped(to: bounds)
            let toFrame = CGAffineTransform(scaleX: 1 / scale.width, y: 1 / scale.height)
                .concatenating(Self.flip(height: group.frameSize.height))
                .concatenating(group.toOuter)
            return nested.transformed(by: toFrame.concatenating(start).concatenating(toOutput))
        }
    }

    /// `picture` shown only where `matte` says: its alpha or its brightness,
    /// inverted for the inverted modes, and mixed in by `amount`.
    private func cut(_ picture: CIImage, by matte: CIImage, mode: MatteMode, amount: Double, frame frameSize: CGSize) -> CIImage {
        let canvas = canvasRect(of: frameSize)
        // Outside the matte's own picture it is empty.
        var mask = matte.composited(over: CIImage(color: .clear).cropped(to: canvas)).cropped(to: canvas)
        let weight = CGFloat(amount) * (mode.isInverted ? -1 : 1)
        let bias = mode.isInverted ? 1 : 1 - CGFloat(amount)
        let alphaVector: CIVector
        if mode.usesLuma {
            // Brightness is what is left of the picture over black.
            mask = mask.composited(over: CIImage(color: .black).cropped(to: canvas))
            alphaVector = CIVector(x: 0.2126 * weight, y: 0.7152 * weight, z: 0.0722 * weight, w: 0)
        } else {
            alphaVector = CIVector(x: 0, y: 0, z: 0, w: weight)
        }
        mask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": alphaVector,
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: bias),
        ])
        return picture.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
    }

    /// The frame and the margin round it that pictures are kept in, in
    /// output pixels.
    private func canvasRect(of frameSize: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: frameSize.width * scale.width, height: frameSize.height * scale.height)
            .insetBy(dx: -frameSize.width * scale.width * canvasMargin, dy: -frameSize.height * scale.height * canvasMargin)
    }

    /// `image` kept to the nested timeline's frame (`nested`, in its own
    /// pixels from the top left) as it lies after `matrix`, which takes
    /// those pixels to output pixels: cropped when the frame stays upright,
    /// masked when it is turned.
    static func limited(_ image: CIImage, toNestedFrame nested: CGSize, through matrix: CGAffineTransform) -> CIImage {
        let frame = CGRect(origin: .zero, size: nested)
        if abs(matrix.b) < 1e-6, abs(matrix.c) < 1e-6 {
            return image.cropped(to: frame.applying(matrix))
        }
        let mask = CIImage(color: .white).cropped(to: frame).transformed(by: matrix)
        return image.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
    }

    /// Flips between top-left and bottom-left origins in a frame
    /// `height` high.
    static func flip(height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }
}

private extension CGAffineTransform {
    var isInvertibleMatrix: Bool { abs(a * d - b * c) > 1e-9 }
}

/// The viewer's compositor for SDR timelines. Frames are decoded into 8-bit
/// BGRA, half the size of half floats and with no conversion to float, so
/// each frame costs less memory traffic; SDR pictures have no more
/// precision to keep. Export and HDR timelines use `LayeredCompositor`.
final class SDRLayeredCompositor: LayeredCompositor, @unchecked Sendable {
    override class var pixelFormat: OSType { kCVPixelFormatType_32BGRA }
}

extension ProjectColorSpace {
    /// Tags a rendered frame so the player and the exporter read its colors
    /// as the timeline's.
    func attach(to buffer: CVPixelBuffer) {
        let primaries: CFString, transfer: CFString, matrix: CFString
        switch self {
        case .rec709:
            primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
            transfer = kCVImageBufferTransferFunction_ITU_R_709_2
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .rec2020PQ:
            primaries = kCVImageBufferColorPrimaries_ITU_R_2020
            transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .rec2020HLG:
            primaries = kCVImageBufferColorPrimaries_ITU_R_2020
            transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    }
}
