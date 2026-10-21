import AppKit
import AVFoundation
import CoreMedia
import ImageIO

/// Small pictures of a file's frames, for filmstrips, scene lists and
/// replacement checks. Made on request and kept in memory only (see
/// docs/browser.md, "Filmstrips"): a few at a time, so a long strip at one
/// second a thumbnail doesn't swamp the decoder, from one generator per
/// file and size.
@MainActor
enum FrameThumbnails {
    /// How many pictures are made at once.
    static let concurrency = 4

    private static let cache = NSCache<NSString, NSImage>()
    private static var generators: [String: AVAssetImageGenerator] = [:]
    /// The times pictures were made at, by file and size, to find the one
    /// nearest a time when that time has none.
    private static var madeTimes: [String: [CMTime]] = [:]
    private static let limiter = Limiter(slots: concurrency)

    /// Forgets every picture and generator, for when a file was swapped
    /// under the same path.
    static func invalidate() {
        cache.removeAllObjects()
        generators = [:]
        madeTimes = [:]
    }

    /// The picture `image(url:time:height:)` made, if it is still kept.
    static func cached(url: URL, time: CMTime, height: CGFloat) -> NSImage? {
        cache.object(forKey: key(url: url, time: time, height: height))
    }

    /// The kept picture of the file nearest `time`, preferring the last
    /// one at or before it, as the thumbnail whose stretch holds `time`
    /// is. Nil when none of the file at that size is kept.
    static func nearestCached(url: URL, time: CMTime, height: CGFloat) -> NSImage? {
        if let exact = cached(url: url, time: time, height: height) { return exact }
        let times = madeTimes[fileKey(url: url, height: height)] ?? []
        let before = times.filter { $0 <= time }.sorted(by: >)
        let after = times.filter { $0 > time }.sorted()
        for candidate in before + after {
            if let image = cached(url: url, time: candidate, height: height) { return image }
        }
        return nil
    }

    private static func fileKey(url: URL, height: CGFloat) -> String {
        "\(url.path)|\(Int((height * 2).rounded(.up)))"
    }

    /// A still is the same picture at every time, so it is kept once.
    private static func key(url: URL, time: CMTime, height: CGFloat) -> NSString {
        let time = MediaImporter.isImage(url) ? .zero : time
        return "\(url.path)|\(time.value)/\(time.timescale)|\(Int((height * 2).rounded(.up)))" as NSString
    }

    /// The frame at `time` in the file, at most `height` points tall (drawn
    /// at twice that in pixels). Nil when it can't be read, or when the
    /// calling task is cancelled before its turn, as a thumbnail scrolled
    /// out of view is.
    static func image(url: URL, time: CMTime, height: CGFloat = 45) async -> NSImage? {
        let pixels = Int((height * 2).rounded(.up))
        let key = key(url: url, time: time, height: height)
        if let cached = cache.object(forKey: key) { return cached }

        guard await limiter.acquire() else { return nil }
        let made = MediaImporter.isImage(url)
            ? await still(url: url, pixels: pixels)
            : await render(HandedOver(value: generator(for: url, pixels: pixels)), time: time)
        await limiter.release()

        guard let made else { return nil }
        let image = NSImage(cgImage: made, size: NSSize(width: made.width, height: made.height))
        cache.setObject(image, forKey: key)
        madeTimes[fileKey(url: url, height: height), default: []].append(time)
        return image
    }

    /// Set up once and never changed, so requests can share it.
    private static func generator(for url: URL, pixels: Int) -> AVAssetImageGenerator {
        let key = "\(url.path)|\(pixels)"
        if let existing = generators[key] { return existing }
        let generator = AVAssetImageGenerator(asset: MediaFile.asset(at: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: pixels * 16 / 9, height: pixels)
        generators[key] = generator
        return generator
    }

    /// A still's thumbnail, upright, from ImageIO without decoding the whole
    /// picture when the file holds a smaller one.
    private nonisolated static func still(url: URL, pixels: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels * 16 / 9,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func render(_ generator: HandedOver<AVAssetImageGenerator>, time: CMTime) async -> CGImage? {
        try? await generator.value.image(at: time).image
    }

    /// Lets `slots` callers through at a time, in order. A caller whose task
    /// is cancelled while waiting is turned away.
    private actor Limiter {
        private var free: Int
        private var waiting: [CheckedContinuation<Bool, Never>] = []

        init(slots: Int) { free = slots }

        func acquire() async -> Bool {
            if Task.isCancelled { return false }
            if free > 0 {
                free -= 1
                return true
            }
            let admitted = await withCheckedContinuation { waiting.append($0) }
            if Task.isCancelled {
                release()
                return false
            }
            return admitted
        }

        func release() {
            if waiting.isEmpty {
                free += 1
            } else {
                waiting.removeFirst().resume(returning: true)
            }
        }
    }
}
