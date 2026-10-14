import AVFoundation
import CoreImage
import CoreMedia
import Foundation
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
/// for a film dissolve, which keys on brightness and so can't be drawn by
/// the built-in compositor. Everything else is drawn as the built-in
/// compositor would: each layer's crop, transform and opacity, bottom layer
/// first, over black.
///
/// AVFoundation's transforms measure from the top left and Core Image's
/// from the bottom left, so each layer is flipped into the transform's
/// space and back out.
///
/// Like the built-in compositor it works on the frames' encoded values,
/// without color management, so the two draw the same picture and the
/// film dissolve keys on brightness as it looks rather than as light.
final class LayeredCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ]
        return MetalDevice.shared.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()
    private let queue = DispatchQueue(label: "LayeredCompositor", qos: .userInitiated)

    // Half floats keep HDR sources and timelines intact.
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_64RGBAHalf],
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_64RGBAHalf],
    ]
    let supportsWideColorSourceFrames = true
    let supportsHDRSourceFrames = true

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? LayeredInstruction,
                      let output = request.renderContext.newPixelBuffer()
                else {
                    request.finish(with: CompositionError.exportFailed("The film dissolve couldn't be drawn."))
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

        var output = CIImage(color: .black).cropped(to: bounds)
        for layer in instruction.layers.reversed() {
            guard let buffer = frame(layer.trackID) else { continue }
            let animation = layer.animation
            var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            let sourceHeight = image.extent.height
            if let crop = animation.cropRectangle(at: time) {
                image = image.cropped(to: CGRect(x: crop.minX, y: sourceHeight - crop.maxY, width: crop.width, height: crop.height))
            }
            let fromSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
            image = image.transformed(by: fromSource.concatenating(animation.transform(at: time)).concatenating(toOutput))

            let opacity = CGFloat(animation.opacity(at: time))
            if opacity < 1 {
                image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
            }
            if let reveal = animation.lumaReveal(at: time) {
                // On the way in the clip is the following picture; on the way
                // out it is what's underneath, and the clip stays where that
                // hasn't come through yet.
                var mask = Self.revealMask(of: reveal.keysIncoming ? image : output, reveal)
                if !reveal.keysIncoming { mask = mask.applyingFilter("CIColorInvert") }
                image = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask,
                ])
            }
            output = image.composited(over: output)
        }
        return output.cropped(to: bounds)
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
