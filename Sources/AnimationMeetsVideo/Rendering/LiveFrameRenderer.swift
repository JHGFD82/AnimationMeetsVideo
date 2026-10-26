import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// Draws the paused frame from a freshly built composition, so the viewer
/// can follow an edit (dragging a value) without swapping its player item
/// for every step. Latest wins: one frame is drawn at a time, and a
/// request that arrives meanwhile replaces any waiting, so a fast drag
/// shows the newest picture it can instead of falling behind or being
/// cancelled before anything is drawn.
///
/// Each frame drawn from a build also keeps the decoded frames it was drawn
/// from and the stretch's drawing (a `Scene`). An edit that changes only
/// values, as dragging one does, is then drawn from those (`redraw`): the
/// edited clips' new values put into the drawing and the one frame composed
/// again, in a few milliseconds, with no build and no decoding. Both keep
/// the finished picture of each clip drawn the same way as the last time
/// (`ClipPictureCache.Keeping.steady`), so a drag of one clip's value
/// draws only that clip again and takes the others' as they were.
@MainActor
final class LiveFrameRenderer {
    struct Request {
        var composed: ComposedTimeline
        /// The fraction of the frame size to draw at.
        var scale: Double
        var time: CMTime
        /// Drawn for a drag in progress, whose frame times are measured.
        var interactive = false
        /// The structure (`EditingProject.structure`) of the project the
        /// composition was built from, which later edits must share to be
        /// drawn from this frame; nil to keep nothing.
        var structure: EditingProject?
    }

    /// What a frame drawn from a build was drawn from.
    private struct Scene {
        var structure: EditingProject
        var time: CMTime
        var capture: SourceCapture
        /// Whether the frame drawn from the build was deeper than 8 bits,
        /// which a frame drawn again keeps.
        var deep: Bool
    }

    /// A frame to draw again from the scene, with these values.
    private struct Redraw {
        var instruction: LayeredInstruction
        var frames: [CMPersistentTrackID: CVPixelBuffer]
        var size: CGSize
        var time: CMTime
        var deep: Bool
        var interactive: Bool
    }

    private enum Job {
        case build(Request)
        case redraw(Redraw)
    }

    /// Called with each finished picture, how long it took to draw, and
    /// whether it was for a drag in progress.
    var onFrame: ((CoverPicture, Double, Bool) -> Void)?

    private var latest: Job?
    private var worker: Task<Void, Never>?
    /// Bumped by `cancel`, so a picture drawn for an older request is dropped.
    private var generation = 0
    private var scene: Scene?

    /// Why the last `redraw` was refused, nil if it wasn't. A frame that needs
    /// a scene has none to draw again from: none was built, the playhead has
    /// moved, or the stretch it stands in is a render, which holds the values
    /// it was made with. A build without the renders gives it one. A change
    /// of structure needs the timeline built again.
    enum Refusal { case needsScene, structureChanged }
    private(set) var refusal: Refusal?

    func submit(_ request: Request) {
        enqueue(.build(request))
    }

    /// Draws the frame again with `project`'s values, from the last frame
    /// drawn from a build, if that can show it: `structure` (the project's)
    /// is the same as that build's, so only values changed, and the frame is
    /// at `time`, as that one was. False when it can't (see `refusal`), and
    /// the timeline has to be built.
    func redraw(with project: EditingProject, structure: EditingProject, time: CMTime, interactive: Bool) -> Bool {
        refusal = nil
        guard let scene, scene.time == time else {
            refusal = .needsScene
            return false
        }
        guard scene.structure == structure else {
            refusal = .structureChanged
            return false
        }
        guard let recorded = scene.capture.recorded else {
            refusal = .needsScene
            return false
        }
        let clips = project.clipsByID
        var drawn: [DrawClip] = []
        for clip in recorded.instruction.clips {
            // A rendered stretch can't take new values.
            guard let patched = clip.withValues(from: clips) else {
                refusal = .needsScene
                return false
            }
            drawn.append(patched)
        }
        enqueue(.redraw(Redraw(
            instruction: recorded.instruction.drawing(drawn, keeping: .steady), frames: recorded.frames, size: recorded.size,
            time: time, deep: scene.deep, interactive: interactive
        )))
        return true
    }

    /// Drops what is waiting and what is being drawn, and the scene.
    func cancel() {
        generation += 1
        latest = nil
        worker?.cancel()
        worker = nil
        scene = nil
    }

    private func enqueue(_ job: Job) {
        latest = job
        guard worker == nil else { return }
        let mine = generation
        worker = Task { [weak self] in
            while let self, self.generation == mine, let job = self.latest {
                self.latest = nil
                let started = ContinuousClock.now
                let picture: CoverPicture?
                var interactive = false
                switch job {
                case .build(let request):
                    interactive = request.interactive
                    let capture = request.structure == nil ? nil : SourceCapture()
                    let image = await Self.draw(request, capture: capture)
                    if let capture, let structure = request.structure, let image, self.generation == mine {
                        self.scene = Scene(structure: structure, time: request.time, capture: capture, deep: image.bitsPerComponent > 8)
                    }
                    picture = image.map(CoverPicture.image)
                case .redraw(let redraw):
                    interactive = redraw.interactive
                    picture = await Self.draw(redraw).map(CoverPicture.frame)
                }
                let (seconds, attoseconds) = (ContinuousClock.now - started).components
                guard self.generation == mine else { return }
                if let picture { self.onFrame?(picture, Double(seconds) + Double(attoseconds) / 1e18, interactive) }
            }
            if let self, self.generation == mine { self.worker = nil }
        }
    }

    private static func draw(_ request: Request, capture: SourceCapture?) async -> CGImage? {
        guard var videoComposition = request.composed.videoComposition(scaledBy: request.scale) else { return nil }
        if let capture, let copy = videoComposition.mutableCopy() as? AVMutableVideoComposition {
            // Each stretch keeps what it is drawn from; only the one at the
            // playhead draws.
            copy.instructions = copy.instructions.map { instruction in
                (instruction as? LayeredInstruction).map { $0.drawing($0.clips, capture: capture, keeping: .steady) } ?? instruction
            }
            videoComposition = copy
        }
        let generator = AVAssetImageGenerator(asset: request.composed.composition)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: request.time).image
    }

    /// Colors as they are: the compositor's values are the timeline's
    /// encoding, which the frame is tagged with, as the player's are.
    nonisolated private static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        return MetalDevice.shared.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    /// The frame composed again, into a surface tagged with the timeline's
    /// colors exactly as the compositor tags the player's frames, so the
    /// screen shows it as it shows the video, color-matched on the GPU.
    private static func draw(_ redraw: Redraw) async -> CVPixelBuffer? {
        let job = HandedOver(value: redraw)
        return await Task.detached(priority: .userInitiated) { () -> HandedOver<CVPixelBuffer>? in
            let redraw = job.value
            let image = LayeredCompositor.compose(
                redraw.instruction, at: redraw.time, outputSize: redraw.size, pictures: redraw.instruction.options?.pictures
            ) { redraw.frames[$0] }
            var buffer: CVPixelBuffer?
            let attributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferCreate(
                nil, Int(redraw.size.width), Int(redraw.size.height),
                redraw.deep ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
            )
            guard let buffer else { return nil }
            context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: redraw.size), colorSpace: nil)
            redraw.instruction.colorSpace.attach(to: buffer)
            return HandedOver(value: buffer)
        }.value?.value
    }
}
