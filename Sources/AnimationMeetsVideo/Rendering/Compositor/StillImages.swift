import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// A still's picture, decoded and ready to draw: upright, at most the size
/// it is kept at, in the encoding of the timeline it is drawn in (see
/// docs/graphic-layers.md, "Stills").
final class StillPicture: @unchecked Sendable {
    let buffer: CVPixelBuffer
    var size: CGSize { CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) }

    init(buffer: CVPixelBuffer) {
        self.buffer = buffer
    }

    /// The picture as the compositor reads a frame: its values as they
    /// are, without color management.
    var image: CIImage { CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]) }
}

/// Stills decoded for drawing, kept between the many rebuilds of an editing
/// session. A picture is decoded once per file version, timeline color
/// space and size, while a composition is built, never while a frame is
/// drawn.
actor StillImages {
    static let shared = StillImages()

    /// The long side a still is never decoded past.
    static let maximumSide = 8192.0
    /// How much past the size that fits the frame a still is kept, so it can
    /// be scaled up that far before it softens.
    static let headroom = 2.0
    /// Roughly how many bytes of pictures are kept; the least recently used
    /// go first beyond it.
    static let budget = 1 << 30

    private struct Key: Hashable {
        var path: String
        var stamp: FileStamp?
        var colorSpace: ProjectColorSpace
        var size: CGSize

        func hash(into hasher: inout Hasher) {
            hasher.combine(path)
            hasher.combine(stamp?.byteCount)
            hasher.combine(stamp?.modified)
            hasher.combine(colorSpace)
            hasher.combine(size.width)
            hasher.combine(size.height)
        }
    }

    private var entries: [Key: StillPicture] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    private let context: CIContext = {
        // Color managed, unlike the compositor's: this is where a still's
        // colors are turned into the timeline's encoding.
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        return MetalDevice.shared.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    /// The picture of the still at `url` for a timeline whose frame is
    /// `frameSize`, in `colorSpace`. Nil when the file can't be read.
    func picture(at url: URL, frameSize: CGSize, colorSpace: ProjectColorSpace) -> StillPicture? {
        var options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        // An HDR picture's gain map is applied only where it can be shown.
        if colorSpace.isHDR { options[.expandToHDR] = true }
        // Reading the header only: the pixels are decoded when rendered.
        guard let image = CIImage(contentsOf: url, options: options), !image.extent.isEmpty, !image.extent.isInfinite else {
            return nil
        }
        let size = Self.keptSize(of: image.extent.size, frameSize: frameSize)
        let key = Key(path: url.path, stamp: FileStamp(url: url), colorSpace: colorSpace, size: size)
        if let cached = entries[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return cached
        }
        guard let picture = decode(image, to: size, in: colorSpace) else { return nil }
        entries[key] = picture
        order.append(key)
        trim()
        return picture
    }

    /// Lets go of every picture read from the file at `url`, for when it
    /// was replaced or changed on disk.
    func forget(_ url: URL) {
        entries = entries.filter { $0.key.path != url.path }
        order.removeAll { $0.path == url.path }
    }

    /// The size a picture `size` big is kept at for a frame `frameSize`: at
    /// most `headroom` times the size that fits the frame, and never more
    /// than `maximumSide` on its long side. Never enlarged.
    static func keptSize(of size: CGSize, frameSize: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let fit = frameSize.width > 0 && frameSize.height > 0
            ? min(frameSize.width / size.width, frameSize.height / size.height) * headroom : 1
        let scale = min(1, fit, maximumSide / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    private func decode(_ image: CIImage, to size: CGSize, in colorSpace: ProjectColorSpace) -> StillPicture? {
        var picture = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if size != image.extent.size {
            picture = picture.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: size.height / image.extent.height,
                kCIInputAspectRatioKey: (size.width / image.extent.width) / (size.height / image.extent.height),
            ])
        }
        let bounds = CGRect(origin: .zero, size: size)
        // Transparent, not clamped, where the scaled edge falls short.
        picture = picture.cropped(to: bounds).composited(over: CIImage(color: .clear).cropped(to: bounds))

        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &buffer)
        guard let buffer, let space = colorSpace.cgColorSpace else { return nil }
        context.render(picture, to: buffer, bounds: bounds, colorSpace: space)
        return StillPicture(buffer: buffer)
    }

    private func trim() {
        var bytes = entries.values.reduce(0) { $0 + CVPixelBufferGetDataSize($1.buffer) }
        while bytes > Self.budget, order.count > 1 {
            let oldest = order.removeFirst()
            if let gone = entries.removeValue(forKey: oldest) { bytes -= CVPixelBufferGetDataSize(gone.buffer) }
        }
    }
}

extension ProjectColorSpace {
    /// The encoding a timeline in this space draws in.
    var cgColorSpace: CGColorSpace? {
        switch self {
        case .rec709: CGColorSpace(name: CGColorSpace.itur_709)
        case .rec2020PQ: CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .rec2020HLG: CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        }
    }
}
