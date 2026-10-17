import AppKit
import AVFoundation
import CoreMedia

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
    private static let limiter = Limiter(slots: concurrency)

    /// Forgets every picture and generator, for when a file was swapped
    /// under the same path.
    static func invalidate() {
        cache.removeAllObjects()
        generators = [:]
    }

    /// The frame at `time` in the file, at most `height` points tall (drawn
    /// at twice that in pixels). Nil when it can't be read, or when the
    /// calling task is cancelled before its turn, as a thumbnail scrolled
    /// out of view is.
    static func image(url: URL, time: CMTime, height: CGFloat = 45) async -> NSImage? {
        let pixels = Int((height * 2).rounded(.up))
        let key = "\(url.path)|\(time.value)/\(time.timescale)|\(pixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let generator = generator(for: url, pixels: pixels)
        guard await limiter.acquire() else { return nil }
        let made = await render(HandedOver(value: generator), time: time)
        await limiter.release()

        guard let made else { return nil }
        let image = NSImage(cgImage: made, size: NSSize(width: made.width, height: made.height))
        cache.setObject(image, forKey: key)
        return image
    }

    /// Set up once and never changed, so requests can share it.
    private static func generator(for url: URL, pixels: Int) -> AVAssetImageGenerator {
        let key = "\(url.path)|\(pixels)"
        if let existing = generators[key] { return existing }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: pixels * 16 / 9, height: pixels)
        generators[key] = generator
        return generator
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
