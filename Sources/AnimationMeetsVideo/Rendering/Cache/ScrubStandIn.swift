import AppKit
import AVFoundation
import CoreMedia

/// A picture to show while a fast scrub's seek is behind (docs/rendering.md,
/// "Thumbnails while catching up"): where the timeline is one file drawn
/// plainly over the whole frame, the nearest picture of that file the
/// timeline's filmstrips keep in memory (`FrameThumbnails`), until the
/// player's frame arrives and replaces it.
@MainActor
enum ScrubStandIn {
    /// The stand-in for `time` of the timeline `videoComposition` draws, as
    /// a buffer the viewer shows; nil where the frame is anything but one
    /// file drawn plainly (an effect, a transition, a still, more than one
    /// picture, one not filling the frame), in an HDR timeline, or with no
    /// picture of the file kept.
    static func picture(at time: CMTime, of videoComposition: AVVideoComposition) -> CVPixelBuffer? {
        guard let place = plainFile(at: time, of: videoComposition),
              let image = FrameThumbnails.nearestCached(url: place.url, time: place.fileTime),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return buffer(of: cgImage, colorSpace: place.colorSpace)
    }

    /// The file drawn at `time` and the time in it, when the frame is that
    /// file alone, drawn plainly and filling the frame, in an SDR timeline.
    static func plainFile(at time: CMTime, of videoComposition: AVVideoComposition) -> (url: URL, fileTime: CMTime, colorSpace: ProjectColorSpace)? {
        guard let instruction = videoComposition.instructions
            .compactMap({ $0 as? LayeredInstruction })
            .first(where: { $0.timeRange.containsTime(time) }),
            instruction.colorSpace == .rec709, instruction.clips.count == 1, let clip = instruction.clips.first,
            case .media(let media) = clip.content, media.still == nil, let size = media.opaqueSize
        else { return nil }
        let resolved = clip.stack.resolve(atRoot: time)
        guard resolved.steps.isEmpty, resolved.transition == nil else { return nil }
        // Fitted to the whole frame: a letterboxed or moved picture would
        // need the rest of the frame drawn too.
        let placed = CGRect(origin: .zero, size: size).applying(media.base)
        let frame = CGRect(origin: .zero, size: instruction.renderSize)
        guard abs(placed.minX - frame.minX) < 1, abs(placed.minY - frame.minY) < 1,
              abs(placed.width - frame.width) < 1, abs(placed.height - frame.height) < 1
        else { return nil }
        let source = clip.stack.sourceTime(atLocal: clip.stack.localTime(atRoot: time))
        return (media.url, CMTimeAdd(source, media.alignmentOffset), instruction.colorSpace)
    }

    /// `image` in a buffer the viewer shows, tagged as the timeline's.
    private static func buffer(of image: CGImage, colorSpace: ProjectColorSpace) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made) == kCVReturnSuccess,
              let buffer = made
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        colorSpace.attach(to: buffer)
        return buffer
    }
}
