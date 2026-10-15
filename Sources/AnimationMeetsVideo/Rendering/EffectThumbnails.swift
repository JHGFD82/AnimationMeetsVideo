import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Small pictures of a clip after each effect of its stack, at one moment,
/// for the effects panel. Each is the clip's own picture drawn through the
/// stack up to that effect, over black: what is under the clip in the
/// timeline isn't drawn, so a Blending step blends with black.
enum EffectThumbnails {
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// The pictures by effect ID, `width` points wide. Empty when the clip
    /// has no effects or its picture can't be read.
    static func render(
        project: EditingProject,
        timelineID: UUID,
        clipID: UUID,
        at time: CMTime,
        width: CGFloat = 72
    ) async -> [UUID: CGImage] {
        guard let clip = project.clipAndLayer(clipID, in: timelineID)?.clip,
              let timeline = project.timeline(id: timelineID),
              !clip.effects.isEmpty, clip.trimmedDuration > .zero
        else {
            return [:]
        }
        // Inside the clip, on its last frame at the latest.
        let last = CMTimeMaximum(clip.startOffset, CMTimeSubtract(clip.endOffset, timeline.frameDuration))
        let at = CMTimeMinimum(CMTimeMaximum(time, clip.startOffset), last)
        guard let picture = await sourcePicture(of: clip, at: clip.sourceTime(atTimelineTime: at), in: project),
              let buffer = pixelBuffer(from: picture)
        else {
            return [:]
        }

        let frame = timeline.frameSize
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let base = fit(from: CGSize(width: picture.width, height: picture.height), to: frame)
        let thumbnail = CGSize(width: width, height: max(1, (width * frame.height / max(frame.width, 1)).rounded()))
        var result: [UUID: CGImage] = [:]
        for (index, effect) in clip.effects.enumerated() {
            var truncated = clip
            truncated.effects = Array(clip.effects.prefix(index + 1))
            let drawn = DrawClip(
                content: .media(MediaDraw(
                    trackID: 1, base: base, url: URL(fileURLWithPath: "/dev/null"), sourceStart: .zero, segmentStart: .zero
                )),
                stack: ClipStack(clip: truncated, center: center, shift: .zero, colorSpace: timeline.colorSpace),
                range: CMTimeRange(start: clip.startOffset, end: clip.endOffset), owner: clip.id
            )
            let instruction = LayeredInstruction(
                timeRange: drawn.range, clips: [drawn], renderSize: frame, colorSpace: timeline.colorSpace,
                canvasMargin: project.canvasMargin
            )
            let image = LayeredCompositor.compose(instruction, at: at, outputSize: thumbnail) { _ in buffer }
            if let cg = context.createCGImage(
                image, from: CGRect(origin: .zero, size: thumbnail), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            ) {
                result[effect.id] = cg
            }
        }
        return result
    }

    /// Scales `source` to fit inside `target` (aspect-preserving) and centers it.
    private static func fit(from source: CGSize, to target: CGSize) -> CGAffineTransform {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .identity }
        let scale = min(target.width / source.width, target.height / source.height)
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
            translationX: (target.width - source.width * scale) / 2,
            y: (target.height - source.height * scale) / 2
        ))
    }

    /// The clip's own picture at `sourceTime`, upright and small.
    private static func sourcePicture(of clip: TimelineClip, at sourceTime: CMTime, in project: EditingProject) async -> CGImage? {
        switch clip.source {
        case .media(let id):
            guard let media = project.mediaClip(id: id), media.kind == .video, let url = media.url else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 384, height: 384)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            return try? await generator.image(at: media.fileTime(forSourceTime: sourceTime)).image
        case .timeline(let id):
            guard let composed = try? await CompositionExporter.buildComposedTimeline(for: project, timelineID: id, forPreview: true) else {
                return nil
            }
            let generator = AVAssetImageGenerator(asset: composed.composition)
            generator.videoComposition = composed.videoComposition
            generator.maximumSize = CGSize(width: 384, height: 384)
            return try? await generator.image(at: sourceTime).image
        }
    }

    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}
