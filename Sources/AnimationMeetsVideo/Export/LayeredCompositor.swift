import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import os
import QuartzCore

/// One stretch of a timeline for `LayeredCompositor`: the video tracks
/// showing, top first, each with how it is placed.
final class LayeredInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    struct Layer {
        let trackID: CMPersistentTrackID
        let animation: PlacementAnimation
    }

    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: [Layer]
    /// The timeline's frame size. The player may draw smaller than this.
    let renderSize: CGSize
    let colorSpace: ProjectColorSpace
    /// Told how long each frame took, when the viewer is watching.
    let meter: RenderMeter?

    init(timeRange: CMTimeRange, layers: [Layer], renderSize: CGSize, colorSpace: ProjectColorSpace, meter: RenderMeter? = nil) {
        self.timeRange = timeRange
        self.layers = layers
        self.renderSize = renderSize
        self.colorSpace = colorSpace
        self.meter = meter
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
    }
}

/// Draws a timeline with Core Image on the GPU through Metal. The viewer
/// always uses it, since it can draw at a reduced size; export uses it only
/// for what the built-in compositor can't draw: a film dissolve, which keys
/// on brightness, and a nested timeline fading over layers of its own that
/// overlap. Everything else is drawn as the built-in compositor would: each
/// layer's crop, transform and opacity, bottom layer first, over black.
///
/// The layers of a nested timeline are stacked by themselves first, and the
/// opacity and transitions of the clip that holds it then fade the result
/// as one picture, so its layers don't show through each other.
///
/// AVFoundation's transforms measure from the top left and Core Image's
/// from the bottom left, so each layer is flipped into the transform's
/// space and back out.
///
/// Like the built-in compositor it works on the frames' encoded values,
/// without color management, so the two draw the same picture and the
/// film dissolve keys on brightness as it looks rather than as light.
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
                    request.finish(with: CompositionError.exportFailed("A frame of the timeline couldn't be drawn."))
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

    /// Lets go of the queued requests rather than drawing them first; the
    /// one being drawn finishes as usual.
    func cancelAllPendingVideoCompositionRequests() {
        generation.withLock { $0 += 1 }
    }

    /// One layer's frame, cropped and placed in the output.
    private struct Drawn {
        let animation: PlacementAnimation
        let image: CIImage
    }

    /// The frame at `time`: layers stacked bottom first over black.
    static func compose(
        _ instruction: LayeredInstruction,
        at time: CMTime,
        outputSize: CGSize,
        frame: (CMPersistentTrackID) -> CVPixelBuffer?
    ) -> CIImage {
        let renderSize = instruction.renderSize
        let bounds = CGRect(origin: .zero, size: outputSize)
        // The render context may be smaller than the timeline's frame, as
        // when the player draws at a reduced size.
        let toOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderSize.height)
            .concatenating(CGAffineTransform(
                scaleX: renderSize.width > 0 ? outputSize.width / renderSize.width : 1,
                y: renderSize.height > 0 ? outputSize.height / renderSize.height : 1
            ))

        let drawn = instruction.layers.compactMap { layer -> Drawn? in
            guard let buffer = frame(layer.trackID) else { return nil }
            let animation = layer.animation
            var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            let sourceHeight = image.extent.height
            if let crop = animation.cropRectangle(at: time) {
                image = image.cropped(to: CGRect(x: crop.minX, y: sourceHeight - crop.maxY, width: crop.width, height: crop.height))
            }
            let fromSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
            image = image.transformed(by: fromSource.concatenating(animation.transform(at: time)).concatenating(toOutput))
            return Drawn(animation: animation, image: image)
        }
        let black = CIImage(color: .black).cropped(to: bounds)
        return stack(drawn[...], depth: 0, at: time, over: black).cropped(to: bounds)
    }

    /// `layers`, top first, stacked bottom first over `background`. Layers
    /// drawn through the same nested timeline `depth` levels in are stacked
    /// by themselves, over nothing, and the result is faded as one picture
    /// by the clip that holds the nested timeline.
    private static func stack(_ layers: ArraySlice<Drawn>, depth: Int, at time: CMTime, over background: CIImage) -> CIImage {
        var output = background
        var end = layers.endIndex
        while end > layers.startIndex {
            let bottom = layers[end - 1]
            let groups = bottom.animation.groups
            guard depth < groups.count else {
                let faded = fade(
                    bottom.image, opacity: bottom.animation.ownOpacity(at: time),
                    reveal: bottom.animation.ownLumaReveal(at: time), over: output
                )
                output = faded.composited(over: output)
                end -= 1
                continue
            }
            // A nested timeline's layers come out of flattening together.
            let group = groups[depth]
            var start = end - 1
            while start > layers.startIndex {
                let above = layers[start - 1].animation.groups
                guard depth < above.count, above[depth] == group else { break }
                start -= 1
            }
            let inside = stack(layers[start..<end], depth: depth + 1, at: time, over: CIImage.empty())
            let stage = bottom.animation.stage(ofGroup: group)
            let faded = fade(
                inside, opacity: Float(stage?.opacity(at: time) ?? 1),
                reveal: stage?.lumaReveal(at: time), over: output
            )
            output = faded.composited(over: output)
            end = start
        }
        return output
    }

    /// `image` at `opacity`, keyed by a film dissolve against `below`, what
    /// it is drawn over.
    private static func fade(_ image: CIImage, opacity: Float, reveal: LumaReveal?, over below: CIImage) -> CIImage {
        var image = image
        if opacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
        }
        if let reveal {
            // On the way in the clip is the following picture; on the way
            // out it is what's underneath, and the clip stays where that
            // hasn't come through yet.
            var mask = Self.revealMask(of: reveal.keysIncoming ? image : below, reveal)
            if !reveal.keysIncoming { mask = mask.applyingFilter("CIColorInvert") }
            image = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ])
        }
        return image
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
