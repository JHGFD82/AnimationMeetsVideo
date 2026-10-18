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
/// again, in a few milliseconds, with no build and no decoding.
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
        /// How the frame drawn from the build was tagged and how deep it was,
        /// which a frame drawn again takes, so the two look the same: the
        /// image generator tags video as the player shows it.
        var colorSpace: CGColorSpace?
        var deep: Bool
    }

    /// A frame to draw again from the scene, with these values.
    private struct Redraw {
        var instruction: LayeredInstruction
        var frames: [CMPersistentTrackID: CVPixelBuffer]
        var size: CGSize
        var time: CMTime
        var colorSpace: CGColorSpace?
        var deep: Bool
        var interactive: Bool
    }

    private enum Job {
        case build(Request)
        case redraw(Redraw)
    }

    /// Called with each finished picture, how long it took to draw, and
    /// whether it was for a drag in progress.
    var onFrame: ((CGImage, Double, Bool) -> Void)?

    private var latest: Job?
    private var worker: Task<Void, Never>?
    /// Bumped by `cancel`, so a picture drawn for an older request is dropped.
    private var generation = 0
    private var scene: Scene?

    func submit(_ request: Request) {
        enqueue(.build(request))
    }

    /// Draws the frame again with `project`'s values, from the last frame
    /// drawn from a build, if that can show it: `structure` (the project's)
    /// is the same as that build's, so only values changed, and the frame is
    /// at `time`, as that one was. False when it can't, and the timeline has
    /// to be built.
    func redraw(with project: EditingProject, structure: EditingProject, time: CMTime, interactive: Bool) -> Bool {
        guard let scene, scene.time == time, scene.structure == structure, let recorded = scene.capture.recorded else {
            return false
        }
        let clips = project.clipsByID
        var drawn: [DrawClip] = []
        for clip in recorded.instruction.clips {
            // A rendered stretch can't take new values.
            guard let patched = clip.withValues(from: clips) else { return false }
            drawn.append(patched)
        }
        enqueue(.redraw(Redraw(
            instruction: recorded.instruction.drawing(drawn), frames: recorded.frames, size: recorded.size,
            time: time, colorSpace: scene.colorSpace ?? recorded.instruction.colorSpace.cgColorSpace, deep: scene.deep,
            interactive: interactive
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
                let image: CGImage?
                var interactive = false
                switch job {
                case .build(let request):
                    interactive = request.interactive
                    let capture = request.structure == nil ? nil : SourceCapture()
                    image = await Self.draw(request, capture: capture)
                    if let capture, let structure = request.structure, let image, self.generation == mine {
                        self.scene = Scene(
                            structure: structure, time: request.time, capture: capture,
                            colorSpace: image.colorSpace, deep: image.bitsPerComponent > 8
                        )
                    }
                case .redraw(let redraw):
                    interactive = redraw.interactive
                    image = await Self.draw(redraw)
                }
                let (seconds, attoseconds) = (ContinuousClock.now - started).components
                guard self.generation == mine else { return }
                if let image { self.onFrame?(image, Double(seconds) + Double(attoseconds) / 1e18, interactive) }
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
                (instruction as? LayeredInstruction).map { $0.drawing($0.clips, capture: capture) } ?? instruction
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
    /// encoding, which the picture is tagged with, as the player's are.
    nonisolated private static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        return MetalDevice.shared.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    private static func draw(_ redraw: Redraw) async -> CGImage? {
        let job = HandedOver(value: redraw)
        return await Task.detached(priority: .userInitiated) {
            let redraw = job.value
            let image = LayeredCompositor.compose(redraw.instruction, at: redraw.time, outputSize: redraw.size) { redraw.frames[$0] }
            return context.createCGImage(
                image, from: CGRect(origin: .zero, size: redraw.size),
                format: redraw.deep ? .RGBAh : .RGBA8, colorSpace: redraw.colorSpace
            )
        }.value
    }
}
