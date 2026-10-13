import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal
import MetalKit
import Observation
import QuartzCore
import SwiftUI
import Vision

/// Whether the matte preview has produced its first frame yet, so the UI can
/// show a "preparing…" indicator instead of leaving the viewer silently
/// black while the first capture/Vision pass is still in flight.
@Observable
final class AutoMatteStatus {
    var hasRenderedFrame = false
}

/// Previews a non-destructive Vision-based foreground matte over the live
/// player, without baking anything into the source pixels. The matte runs
/// on a throttled poll rather than every frame, since this is an editor
/// preview, not an export-quality path.
struct AutoMattePreviewView: NSViewRepresentable {
    let player: AVPlayer
    let status: AutoMatteStatus

    func makeCoordinator() -> AutoMatteRenderer {
        AutoMatteRenderer(player: player, status: status)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        // Plain SDR format matching the SDR colorspace used in draw(in:) —
        // this view composites Vision/checkerboard output, not HDR content.
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        // MTKView defaults to framebufferOnly = true, which optimizes its
        // texture for display-only use and silently blocks CIContext.render
        // from writing into it as a general texture — the render call runs
        // without error but produces no visible output. This is the
        // documented requirement for compositing Core Image into an MTKView.
        view.framebufferOnly = false
        context.coordinator.metalView = view
        context.coordinator.start()
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.player = player
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: AutoMatteRenderer) {
        coordinator.stop()
    }
}

private struct PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

@MainActor
final class AutoMatteRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    var player: AVPlayer
    weak var metalView: MTKView?

    private let status: AutoMatteStatus
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private var pollTimer: Timer?
    private var isProcessing = false
    private var processingStartedAt: CFTimeInterval?
    private var latestImage: CIImage?
    private var ticksSinceLastNudge = 0
    private var pollTickCount = 0

    init(player: AVPlayer, status: AutoMatteStatus) {
        self.player = player
        self.status = status
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        ciContext = device.map { CIContext(mtlDevice: $0) }
        super.init()
    }

    func start() {
        status.hasRenderedFrame = false
        pollTimer?.invalidate()
        // ~8Hz is plenty for a live preview of the matte; Vision's instance
        // segmentation is too expensive to run at full playback framerate.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollForFrame()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let videoOutput, let attachedItem {
            attachedItem.remove(videoOutput)
        }
        videoOutput = nil
        attachedItem = nil
    }

    private func pollForFrame() {
        pollTickCount += 1
        guard let item = player.currentItem else { return }

        if item !== attachedItem {
            if let oldOutput = videoOutput, let oldItem = attachedItem {
                oldItem.remove(oldOutput)
            }
            // Taps the player's own existing decode pipeline rather than
            // opening an independent one — AVAssetImageGenerator opens a
            // fresh decoder session per call, which fails outright
            // (AVFoundationErrorDomain -11832 "Cannot Open") in this
            // unsigned/unbundled executable even though the same asset
            // plays and scrubs fine through the player itself.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            videoOutput = output
            attachedItem = item
        }

        // A hung Vision call (or a failure that never clears the flag)
        // would otherwise permanently freeze the preview, since every later
        // poll would see isProcessing == true forever and bail immediately.
        if isProcessing, let startedAt = processingStartedAt, CACurrentMediaTime() - startedAt > 3 {
            isProcessing = false
        }
        guard let videoOutput, !isProcessing else { return }

        // AVPlayerItemVideoOutput expects queries in its own time mapping,
        // not the player's native currentTime().
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else {
            // A paused player has no reason to keep decoding, so the output
            // drains whatever was already queued at attach time and then
            // offers nothing further. Seeking forces a fresh decode without
            // visibly resuming playback — but seeking to the exact time the
            // player is already sitting at is very likely a no-op AVPlayer
            // short-circuits internally (nothing changed, nothing to do),
            // which is why neither step(byCount:) nor a same-time re-seek
            // ever produced a frame. Seek to a genuinely different nearby
            // time first, then back, to force real decode work to happen.
            ticksSinceLastNudge += 1
            if ticksSinceLastNudge >= 4 {
                ticksSinceLastNudge = 0
                let time = player.currentTime()
                let duration = player.currentItem?.duration ?? .positiveInfinity
                let offset = CMTime(value: 1, timescale: 10)
                let forward = CMTimeAdd(time, offset)
                let nudgeTarget = CMTimeCompare(forward, duration) < 0 ? forward : CMTimeSubtract(time, offset)
                print("[AutoMatte] nudging via \(time.seconds) -> \(nudgeTarget.seconds) -> \(time.seconds) at tick #\(pollTickCount)")
                let player = self.player
                Task {
                    _ = await player.seek(to: nudgeTarget, toleranceBefore: .zero, toleranceAfter: .zero)
                    _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            return
        }

        ticksSinceLastNudge = 0

        // Show the raw frame immediately so the preview is never literally
        // blank while Vision is still working (or if it fails outright) —
        // the matte composite then replaces this once/if it's ready.
        print("[AutoMatte] captured pixel buffer at tick #\(pollTickCount)")
        latestImage = CIImage(cvPixelBuffer: pixelBuffer)
        status.hasRenderedFrame = true
        metalView?.needsDisplay = true

        isProcessing = true
        processingStartedAt = CACurrentMediaTime()
        let box = PixelBufferBox(pixelBuffer)
        Task {
            let result = await Self.computeMattedImage(box)
            isProcessing = false
            print("[AutoMatte] Vision pass finished, matte produced=\(result != nil)")
            if let result {
                latestImage = result
            }
            metalView?.needsDisplay = true
        }
    }

    /// `CVPixelBuffer` isn't `Sendable`, but it's a thread-safe CoreFoundation
    /// object in practice; this wrapper tells the compiler that's accounted
    /// for so the buffer can cross into this nonisolated computation.
    private nonisolated static func computeMattedImage(_ box: PixelBufferBox) async -> CIImage? {
        let pixelBuffer = box.value
        do {
            let request = GenerateForegroundInstanceMaskRequest()
            guard let observation = try await request.perform(on: pixelBuffer) else {
                print("[AutoMatte] No foreground instance observation for this frame; showing raw frame.")
                return nil
            }
            guard !observation.allInstances.isEmpty else {
                print("[AutoMatte] Observation found zero foreground instances; showing raw frame.")
                return nil
            }
            let handler = ImageRequestHandler(pixelBuffer)
            let maskedPixelBuffer = try observation.generateMaskedImage(
                for: observation.allInstances,
                imageFrom: handler,
                croppedToInstancesExtent: false
            )

            let foreground = CIImage(cvPixelBuffer: maskedPixelBuffer)
            let extent = foreground.extent

            let checkerboard = CIFilter.checkerboardGenerator()
            checkerboard.center = CGPoint(x: extent.midX, y: extent.midY)
            checkerboard.color0 = CIColor(red: 0.32, green: 0.32, blue: 0.34)
            checkerboard.color1 = CIColor(red: 0.45, green: 0.45, blue: 0.48)
            checkerboard.width = 32
            checkerboard.sharpness = 1
            let background = (checkerboard.outputImage ?? CIImage.empty()).cropped(to: extent)

            let composite = CIFilter.sourceOverCompositing()
            composite.inputImage = foreground
            composite.backgroundImage = background

            return composite.outputImage ?? foreground
        } catch {
            // The caller already showed the raw frame before this ran, so
            // returning nil here just leaves that in place rather than
            // flashing blank on an occasional Vision failure.
            print("[AutoMatte] Vision matte failed, showing raw frame: \(error)")
            return nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let ciContext,
            let image = latestImage
        else {
            return
        }

        let scale = min(
            CGFloat(drawable.texture.width) / image.extent.width,
            CGFloat(drawable.texture.height) / image.extent.height
        )
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: (CGFloat(drawable.texture.width) - scaled.extent.width) / 2,
            y: (CGFloat(drawable.texture.height) - scaled.extent.height) / 2
        ))

        ciContext.render(
            centered,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
