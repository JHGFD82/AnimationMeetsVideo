import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision

/// In-between frames for Frame Blending's Optical Flow: Vision estimates
/// where each pixel of one frame goes in the next, and a Metal kernel
/// moves both frames part of the way along it and mixes them, instead of
/// fading between them. See docs/effects.md, "Time and Shutter".
///
/// Estimating takes many milliseconds a frame, so the viewer doesn't do it
/// live (it blends), and background renders and export do.
enum OpticalFlow {
    /// The widest picture the flow is estimated on. Motion this coarse is
    /// all an in-between frame needs, and it keeps the estimate fast; the
    /// frames themselves are moved at full size.
    static let estimateWidth = 640

    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    /// A flow field: for each pixel of an `width` x `height` estimate, where
    /// it moves to in the next frame, in the estimate's pixels.
    struct Field {
        var width: Int
        var height: Int
        /// x and y of each pixel, row by row from the top.
        var vectors: [Float]
    }

    /// The motion from `first` to `second`, nil if Vision couldn't
    /// estimate it. Both are frames of the same size.
    static func field(from first: CIImage, to second: CIImage) -> Field? {
        let extent = first.extent
        guard extent.width >= 2, extent.height >= 2, extent.size == second.extent.size else { return nil }
        let scale = min(1, Double(estimateWidth) / extent.width)
        let width = max(2, Int((extent.width * scale).rounded())), height = max(2, Int((extent.height * scale).rounded()))
        guard let a = small(first, width: width, height: height), let b = small(second, width: width, height: height) else { return nil }

        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: b, options: [:])
        request.computationAccuracy = .high
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        do {
            try VNImageRequestHandler(cvPixelBuffer: a, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let flow = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow),
              CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float
        else {
            return nil
        }
        let flowWidth = CVPixelBufferGetWidth(flow), flowHeight = CVPixelBufferGetHeight(flow)
        let rowBytes = CVPixelBufferGetBytesPerRow(flow)
        var vectors = [Float](repeating: 0, count: flowWidth * flowHeight * 2)
        for y in 0..<flowHeight {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<(flowWidth * 2) { vectors[y * flowWidth * 2 + x] = row[x] }
        }
        return Field(width: flowWidth, height: flowHeight, vectors: vectors)
    }

    /// `image` at `width` x `height` pixels, in a buffer Vision reads.
    private static func small(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer
        else {
            return nil
        }
        let extent = image.extent
        let fitted = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        context.render(fitted, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return buffer
    }

    /// The frame `fraction` of the way from `first` to `second` (0...1),
    /// with every pixel moved along `field`. Nil if it can't be drawn, in
    /// which case the caller blends instead.
    static func interpolated(from first: CIImage, to second: CIImage, fraction: Double, field: Field) -> CIImage? {
        let extent = first.extent.integral
        guard !extent.isEmpty, !extent.isInfinite, extent.size == second.extent.integral.size else { return nil }
        let data = field.vectors.withUnsafeBufferPointer { Data(buffer: $0) }
        return try? InterpolationProcessor.apply(
            withExtent: extent,
            inputs: [first, second.transformed(by: CGAffineTransform(translationX: extent.minX - second.extent.minX, y: extent.minY - second.extent.minY))],
            arguments: [
                "fraction": fraction.clamped(between: 0, and: 1),
                "flow": data,
                "flowWidth": field.width,
                "flowHeight": field.height,
                "extent": NSValue(rect: extent),
            ]
        )
    }

    /// The frame between two, or nil when there isn't one to estimate.
    /// Where Vision or the Metal kernel can't run (a virtual Mac may lack
    /// the hardware), the motion is measured by block matching instead,
    /// as a morph's is. With `flows`, the motion of `pair` (frames with
    /// `fingerprint`) is measured once and kept there for the other moments
    /// between the same two frames.
    static func between(
        _ first: CIImage, _ second: CIImage, fraction: Double,
        flows: FlowFieldCache? = nil, pair: FlowFieldCache.Pair? = nil, fingerprint: FlowFieldCache.Fingerprint? = nil
    ) -> CIImage? {
        let measured: Field?
        if let flows, let pair, let fingerprint {
            measured = flows.field(for: pair, fingerprint: fingerprint) { field(from: first, to: second) }
        } else {
            measured = field(from: first, to: second)
        }
        if let field = measured,
           let moved = interpolated(from: first, to: second, fraction: fraction, field: field) {
            return moved
        }
        return matched(first, second, fraction: fraction)
    }

    /// The frame between two, from motion measured by `BlockMatchFlow` at
    /// that frame and each frame warped along it by `MorphFlow`. The search
    /// reaches about a sixth of the width, plenty from one frame to the
    /// next.
    static func matched(_ first: CIImage, _ second: CIImage, fraction: Double) -> CIImage? {
        let bounds = first.extent.integral
        guard !bounds.isEmpty, !bounds.isInfinite, bounds.size == second.extent.integral.size else { return nil }
        let p = fraction.clamped(between: 0, and: 1)
        guard p > 0, p < 1 else { return p <= 0 ? first : second }
        let aligned = second.transformed(by: CGAffineTransform(translationX: bounds.minX - second.extent.minX, y: bounds.minY - second.extent.minY))
        guard let field = BlockMatchFlow.field(from: first, to: aligned, progress: p, in: bounds, reach: 1.0 / 12),
              let leaving = MorphFlow.warped(first, along: field, by: -p, in: bounds),
              let arriving = MorphFlow.warped(aligned, along: field, by: 1 - p, in: bounds)
        else { return nil }
        return TransitionRenderer.mix(leaving, arriving, p).cropped(to: bounds)
    }
}

enum OpticalFlowKernels {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Origins are where each texture's first pixel lies in the frame's
    // pixels, which `size` measures.
    struct FlowParameters {
        float fraction;
        float2 flowScale;
        float2 size;
        float2 outOrigin;
        float2 firstOrigin;
        float2 secondOrigin;
    };

    // Each output pixel takes the first frame from where the motion says it
    // was `fraction` of the way back, and the second from where it will be
    // the rest of the way on, and mixes the two toward the second. Outside
    // the frame it is transparent.
    kernel void interpolate_flow(texture2d<float, access::sample> firstTexture [[texture(0)]],
                                 texture2d<float, access::sample> secondTexture [[texture(1)]],
                                 texture2d<float, access::sample> flowTexture [[texture(2)]],
                                 texture2d<float, access::write> outTexture [[texture(3)]],
                                 constant FlowParameters &params [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;
        constexpr sampler flowSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        constexpr sampler pixelSampler(coord::pixel, address::clamp_to_edge, filter::linear);
        float2 p = float2(gid) + 0.5 + params.outOrigin;
        if (any(p < 0.0) || any(p > params.size)) {
            outTexture.write(float4(0.0), gid);
            return;
        }
        float2 motion = flowTexture.sample(flowSampler, p / params.size).xy * params.flowScale;
        float4 a = firstTexture.sample(pixelSampler, p - params.fraction * motion - params.firstOrigin);
        float4 b = secondTexture.sample(pixelSampler, p + (1.0 - params.fraction) * motion - params.secondOrigin);
        outTexture.write(mix(a, b, params.fraction), gid);
    }
    """

    nonisolated(unsafe) private static var pipelines: [ObjectIdentifier: MTLComputePipelineState] = [:]
    private static let lock = NSLock()

    static func pipeline(on device: MTLDevice) -> MTLComputePipelineState? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(device as AnyObject)
        if let cached = pipelines[key] { return cached }
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "interpolate_flow"),
              let state = try? device.makeComputePipelineState(function: function)
        else {
            NSLog("The optical flow kernel couldn't be compiled.")
            return nil
        }
        pipelines[key] = state
        return state
    }
}

/// Runs the interpolation kernel as a step of a Core Image graph: the first
/// two inputs are the frames, over the same extent. A pixel can come from
/// anywhere in a frame, so each is needed whole.
final class InterpolationProcessor: CIImageProcessorKernel {
    override class var synchronizeInputs: Bool { false }
    override class var outputFormat: CIFormat { .RGBAh }

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        (arguments?["extent"] as? NSValue)?.rectValue ?? outputRect
    }

    override class func process(
        with inputs: [any CIImageProcessorInput]?,
        arguments: [String: Any]?,
        output: any CIImageProcessorOutput
    ) throws {
        guard let inputs, inputs.count == 2,
              let commandBuffer = output.metalCommandBuffer,
              let first = inputs[0].metalTexture, let second = inputs[1].metalTexture,
              let target = output.metalTexture,
              let fraction = arguments?["fraction"] as? Double,
              let flow = arguments?["flow"] as? Data,
              let flowWidth = arguments?["flowWidth"] as? Int, let flowHeight = arguments?["flowHeight"] as? Int,
              let extent = (arguments?["extent"] as? NSValue)?.rectValue,
              flow.count == flowWidth * flowHeight * 2 * MemoryLayout<Float>.size,
              let pipeline = OpticalFlowKernels.pipeline(on: commandBuffer.device)
        else {
            throw NSError(domain: "InterpolationProcessor", code: 1)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: flowWidth, height: flowHeight, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let flowTexture = commandBuffer.device.makeTexture(descriptor: descriptor),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw NSError(domain: "InterpolationProcessor", code: 2)
        }
        flow.withUnsafeBytes { bytes in
            flowTexture.replace(
                region: MTLRegionMake2D(0, 0, flowWidth, flowHeight), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: flowWidth * 2 * MemoryLayout<Float>.size
            )
        }
        // Core Image may ask for more or less than the frame (a pixel more
        // around it to sample a moved picture smoothly, or one tile), and
        // gives each input as much of it as it has, so every texture is
        // placed by its region. The estimate was made at a smaller size, so
        // its motion is too. A texture's first row is its region's top.
        func origin(_ region: CGRect) -> SIMD2<Float> {
            SIMD2(Float(region.minX - extent.minX), Float(extent.maxY - region.maxY))
        }
        var parameters = FlowParameters(
            fraction: Float(fraction),
            flowScale: SIMD2(Float(extent.width) / Float(flowWidth), Float(extent.height) / Float(flowHeight)),
            size: SIMD2(Float(extent.width), Float(extent.height)),
            outOrigin: origin(output.region),
            firstOrigin: origin(inputs[0].region),
            secondOrigin: origin(inputs[1].region)
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(first, index: 0)
        encoder.setTexture(second, index: 1)
        encoder.setTexture(flowTexture, index: 2)
        encoder.setTexture(target, index: 3)
        encoder.setBytes(&parameters, length: MemoryLayout<FlowParameters>.size, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: target.width, height: target.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
    }

    /// The kernel's `FlowParameters`, laid out as Metal lays it out.
    private struct FlowParameters {
        var fraction: Float
        var flowScale: SIMD2<Float>
        var size: SIMD2<Float>
        var outOrigin: SIMD2<Float>
        var firstOrigin: SIMD2<Float>
        var secondOrigin: SIMD2<Float>
    }
}
