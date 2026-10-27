import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Draws the viewer's paused frame again from what the player's compositor
/// drew it from (`SourceCapture`): the clips' values put into the stretch's
/// drawing and the one frame composed again, in a few milliseconds, with no
/// build and no decoding. A value edit is shown this way, and so is the
/// paused frame at full size while Auto plays smaller.
///
/// The frame is composed as the compositor composes it (the same Core Image
/// options, the same pixel format, tagged with the same colors), so it is
/// the picture the player would draw, and the viewer can put one in place
/// of the other without anything changing on screen but what was edited.
///
/// Latest wins: one frame is drawn at a time, and a request that arrives
/// meanwhile replaces any waiting, so a fast drag shows the newest picture
/// it can instead of falling behind. Each keeps the finished picture of
/// every clip drawn the same way as the last time
/// (`ClipPictureCache.Keeping.steady`), so a drag of one clip's value draws
/// only that clip again.
@MainActor
final class FrameRedrawer {
    struct Request {
        var recorded: SourceCapture.Recorded
        /// Every clip of the project by ID, whose values to draw with; nil
        /// to draw the frame as it was.
        var values: [UUID: TimelineClip]?
        var size: CGSize
        /// Handed back with the frame, for the caller to tell whether it is
        /// still wanted.
        var token: Int
    }

    /// Called with each finished frame and its request's token.
    var onFrame: ((CVPixelBuffer, Int) -> Void)?

    private var latest: (instruction: LayeredInstruction, request: Request)?
    private var worker: Task<Void, Never>?
    /// Bumped by `cancel`, so a frame drawn for an older request is dropped.
    private var generation = 0

    /// Draws `request`'s frame, unless a picture in it can't take the
    /// values, as a render can't (it holds the values it was made with):
    /// then false, and nothing is drawn.
    @discardableResult
    func redraw(_ request: Request) -> Bool {
        guard let instruction = Self.instruction(for: request) else { return false }
        latest = (instruction, request)
        guard worker == nil else { return true }
        let mine = generation
        worker = Task { [weak self] in
            while let self, self.generation == mine, let job = self.latest {
                self.latest = nil
                let buffer = await Self.draw(job.instruction, job.request)
                guard self.generation == mine else { return }
                if let buffer { self.onFrame?(buffer, job.request.token) }
            }
            if let self, self.generation == mine { self.worker = nil }
        }
        return true
    }

    /// Whether `recorded` can be drawn with `values`.
    static func canDraw(_ recorded: SourceCapture.Recorded, values: [UUID: TimelineClip]?) -> Bool {
        guard let values else { return true }
        return recorded.instruction.clips.allSatisfy { $0.withValues(from: values) != nil }
    }

    /// Drops what is waiting and what is being drawn.
    func cancel() {
        generation += 1
        latest = nil
        worker?.cancel()
        worker = nil
    }

    private static func instruction(for request: Request) -> LayeredInstruction? {
        let recorded = request.recorded
        guard let values = request.values else { return recorded.instruction.drawing(recorded.instruction.clips, keeping: .steady) }
        var drawn: [DrawClip] = []
        for clip in recorded.instruction.clips {
            guard let patched = clip.withValues(from: values) else { return nil }
            drawn.append(patched)
        }
        return recorded.instruction.drawing(drawn, keeping: .steady)
    }

    /// The compositor's options exactly: colors as they are, the frames'
    /// encoded values, tagged with the timeline's colors afterwards.
    nonisolated private static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        return MetalDevice.shared.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    private static func draw(_ instruction: LayeredInstruction, _ request: Request) async -> CVPixelBuffer? {
        let job = HandedOver(value: (instruction, request))
        return await Task.detached(priority: .userInitiated) { () -> HandedOver<CVPixelBuffer>? in
            let (instruction, request) = job.value
            let recorded = request.recorded
            let image = LayeredCompositor.compose(
                instruction, at: recorded.time, outputSize: request.size, pictures: instruction.options?.pictures
            ) { recorded.frames[$0] }
            var buffer: CVPixelBuffer?
            let attributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferCreate(
                nil, Int(request.size.width), Int(request.size.height), recorded.pixelFormat, attributes as CFDictionary, &buffer
            )
            guard let buffer else { return nil }
            context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: request.size), colorSpace: nil)
            instruction.colorSpace.attach(to: buffer)
            return HandedOver(value: buffer)
        }.value?.value
    }
}
