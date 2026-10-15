import AVFoundation
import CoreMedia
import Foundation

/// Draws the paused frame from a freshly built composition, so the viewer
/// can follow an edit (dragging a value) without swapping its player item
/// for every step. Latest wins: one frame is drawn at a time, and a
/// request that arrives meanwhile replaces any waiting, so a fast drag
/// shows the newest picture it can instead of falling behind or being
/// cancelled before anything is drawn.
@MainActor
final class LiveFrameRenderer {
    struct Request {
        var composed: ComposedTimeline
        /// The fraction of the frame size to draw at.
        var scale: Double
        var time: CMTime
    }

    /// Called with each finished picture.
    var onFrame: ((CGImage) -> Void)?

    private var latest: Request?
    private var worker: Task<Void, Never>?
    /// Bumped by `cancel`, so a picture drawn for an older request is dropped.
    private var generation = 0

    func submit(_ request: Request) {
        latest = request
        guard worker == nil else { return }
        let mine = generation
        worker = Task { [weak self] in
            while let self, self.generation == mine, let request = self.latest {
                self.latest = nil
                let image = await Self.draw(request)
                guard self.generation == mine else { return }
                if let image { self.onFrame?(image) }
            }
            if let self, self.generation == mine { self.worker = nil }
        }
    }

    /// Drops what is waiting and what is being drawn.
    func cancel() {
        generation += 1
        latest = nil
        worker?.cancel()
        worker = nil
    }

    private static func draw(_ request: Request) async -> CGImage? {
        guard let videoComposition = request.composed.videoComposition(scaledBy: request.scale) else { return nil }
        let generator = AVAssetImageGenerator(asset: request.composed.composition)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: request.time).image
    }
}
