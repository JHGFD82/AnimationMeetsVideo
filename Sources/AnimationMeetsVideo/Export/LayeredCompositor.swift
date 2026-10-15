import AVFoundation
import CoreImage
import CoreMedia
import Foundation
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

    init(
        timeRange: CMTimeRange, clips: [DrawClip], passthrough: CMPersistentTrackID = kCMPersistentTrackID_Invalid,
        renderSize: CGSize, colorSpace: ProjectColorSpace, canvasMargin: Double = EditingProject.defaultCanvasMargin,
        meter: RenderMeter? = nil
    ) {
        self.timeRange = timeRange
        self.clips = clips
        passthroughTrackID = passthrough
        self.renderSize = renderSize
        self.colorSpace = colorSpace
        self.canvasMargin = canvasMargin
        self.meter = meter
        requiredSourceTrackIDs = Set(clips.flatMap(\.leaves).map(\.media.trackID)).sorted().map { NSNumber(value: $0) }
    }
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
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? LayeredInstruction,
                      let output = request.renderContext.newPixelBuffer()
                else {
                    request.finish(with: CompositionError.exportFailed("A frame couldn't be drawn."))
                    return
                }
                let started = CACurrentMediaTime()
                let size = request.renderContext.size
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

    func cancelAllPendingVideoCompositionRequests() {
        queue.sync {}
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
    let time: CMTime
    /// Output pixels per frame pixel, in each direction.
    let scale: CGSize
    /// How far past a frame's edges pictures are kept, as a fraction of its
    /// size.
    let canvasMargin: Double
    /// The decoded frame of a composition track at `time`.
    let source: (CMPersistentTrackID) -> CVPixelBuffer?

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
        case .adjustment(let adjustment):
            return drawAdjustment(clip, adjustment, resolved: resolved, frame: frameSize, over: output, outer: outer)
        case .media(let media):
            guard let buffer = source(media.trackID) else { return output }
            let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
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
                return draw(group.children, frame: frameSize, over: output, outer: combined)
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
                let layers = draw(group.children, frame: frameSize, over: .empty(), outer: OuterPlacement(matrix: geometry, opacity: 1))
                picture = Self.limited(layers, toNestedFrame: group.frameSize, through: geometry.concatenating(toOutput))
            } else {
                let nestedBounds = CGRect(x: 0, y: 0, width: group.frameSize.width * scale.width, height: group.frameSize.height * scale.height)
                let nested = draw(group.children, frame: group.frameSize, over: .empty(), outer: .identity).cropped(to: nestedBounds)
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
            inOutput: inOutput, placed: placed
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
        return picture.composited(over: output)
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
            inOutput: inOutput, placed: placed
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
    private func runStack(
        _ steps: [ResolvedStep],
        on start: CIImage,
        opacity: inout Double,
        backdrop: CIImage,
        clip: DrawClip,
        frame frameSize: CGSize,
        inOutput: (CGAffineTransform) -> CGAffineTransform,
        placed: (CGAffineTransform) -> CGAffineTransform
    ) -> CIImage {
        var picture = start
        var kept: [UUID: CIImage] = [:]
        func settleOpacity() {
            guard opacity != 1 else { return }
            picture = picture.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
            opacity = 1
        }
        for step in steps {
            switch step {
            case .place(let matrix, let factor):
                picture = picture.transformed(by: inOutput(placed(matrix)))
                opacity *= factor
            case .mark(let id):
                settleOpacity()
                kept[id] = picture
            case .color(let ops):
                // Grading doesn't depend on where a pixel is, so it doesn't
                // wait for the opacity either.
                let canvas = canvasRect(of: frameSize)
                if let graded = ColorProcessor.grade(picture, ops, in: clip.stack.colorSpace, over: picture.extent.intersection(canvas)) {
                    picture = graded
                }
            case .blend(let mode, let amount, let against):
                settleOpacity()
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
        return picture
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

private extension ProjectColorSpace {
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
