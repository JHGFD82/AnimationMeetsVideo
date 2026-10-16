import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The gray level (the green channel, 0...255) at a point of the frame drawn
/// at `time`, as fractions of its size from the top left.
func grayLevel(
    of composed: ComposedTimeline, at time: CMTime, x: Double = 0.5, y: Double = 0.5,
    size: CGSize = CGSize(width: 128, height: 72)
) async throws -> Int {
    let generator = AVAssetImageGenerator(asset: composed.composition)
    generator.videoComposition = composed.videoComposition
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.maximumSize = size
    let image = try await generator.image(at: time).image
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let px = min(width - 1, Int(Double(width) * x)), py = min(height - 1, Int(Double(height) * y))
    return Int(pixels[(py * width + px) * 4 + 1])
}

/// A project on a small frame with solid-color clips, for drawing tests.
struct DrawingFixture {
    var project = EditingProject.empty
    let directory: URL

    var timelineID: UUID { project.rootTimelineID }

    /// The default frame is the size of the movies the tests write.
    init(frame: CGSize = CGSize(width: 128, height: 72)) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "amv-drawing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        project.timelines[0].frameSize = frame
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Puts a solid clip of `luma` on a new layer at the top of `timeline`.
    @discardableResult
    mutating func addClip(luma: UInt8, frames: Int = 48, to timeline: UUID? = nil) async throws -> (layerID: UUID, clipID: UUID) {
        let url = directory.appending(path: "clip-\(UUID().uuidString).mov")
        try await writeMovie(to: url, segments: [(luma: luma, frames: frames)])
        let media = MediaClip(
            name: url.lastPathComponent, kind: .video, url: url, duration: CMTime(value: Int64(frames), timescale: 24),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let placed = project.importClip(media, intoTimeline: timeline ?? timelineID)
        return try #require(placed)
    }

    /// Replaces a clip's stack with one Transform effect holding these controls.
    mutating func setTransform(
        _ controls: [(ControlKind, [Double])], ofClip clipID: UUID, in timeline: UUID? = nil, movesAnchor: Bool = true
    ) {
        var effect = Effect(kind: .transform, controls: [])
        effect.movesAnchor = movesAnchor
        for (kind, values) in controls {
            var control = EffectControl(kind: kind)
            control.number = AnimatedValue(ComponentValue(values: values))
            effect.controls.append(control)
        }
        project.editClip(clipID, in: timeline ?? timelineID) { $0.effects = [effect] }
    }

    func build(forPreview: Bool = false) async throws -> ComposedTimeline {
        try await CompositionExporter.buildComposedTimeline(for: project, timelineID: timelineID, forPreview: forPreview)
    }
}
