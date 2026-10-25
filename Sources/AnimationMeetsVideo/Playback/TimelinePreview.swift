import AppKit
import AVFoundation
import CoreMedia

/// A timeline as the browser shows it: its composition, built once for
/// each change to what it draws, which its filmstrip's pictures are made
/// from and which skimming it plays. See docs/browser.md, "Timelines".
@MainActor
final class TimelinePreview {
    let timelineID: UUID
    /// What it was built from: the composition key of the timelines it is
    /// drawn from (`EditingProject.timelinesDrawn(from:)`), so an edit to
    /// any other timeline leaves it alone.
    let key: CompositionKey
    let frameSize: CGSize
    let duration: CMTime
    /// The volumes and pans its sound plays through, kept current by
    /// `TimelinePreviews` without rebuilding it, as the editor's are.
    let curves: MixCurves

    private let build: Task<ComposedTimeline?, Never>
    private var generators: [Int: AVAssetImageGenerator] = [:]
    private let pictures = NSCache<NSString, NSImage>()

    /// Pictures made at once across every timeline, as for files.
    private static let limiter = FrameThumbnails.Limiter(slots: 2)

    init(timelineID: UUID, project: EditingProject, key: CompositionKey? = nil) {
        self.timelineID = timelineID
        self.key = key ?? Self.key(of: timelineID, in: project)
        let timeline = project.timeline(id: timelineID)
        frameSize = timeline?.frameSize ?? CGSize(width: 16, height: 9)
        duration = timeline?.duration ?? .zero
        curves = MixCurves(MixCurves.of(project))
        build = Task {
            try? await CompositionExporter.buildComposedTimeline(for: project, timelineID: timelineID, forPreview: true)
        }
    }

    /// The composition of `timelineID` and the timelines it is drawn from,
    /// cut from `whole`, the project's own key, when it is given.
    static func key(of timelineID: UUID, in project: EditingProject, whole: CompositionKey? = nil) -> CompositionKey {
        var key = whole ?? CompositionKey(project: project)
        let drawn = project.timelinesDrawn(from: timelineID)
        key.timelines = key.timelines.filter { drawn.contains($0.id) }
        return key
    }

    /// The composition, once built; nil when it can't be (its media is
    /// missing, say).
    func composed() async -> ComposedTimeline? {
        await build.value
    }

    /// The picture `image(at:height:)` made, if it is still kept.
    func cachedImage(at time: CMTime, height: CGFloat) -> NSImage? {
        pictures.object(forKey: Self.pictureKey(time, pixels: Self.pixels(height)))
    }

    /// The timeline's frame at `time`, at most `height` points tall (drawn
    /// at twice that in pixels). Nil when it can't be made, or when the
    /// calling task is cancelled before its turn.
    func image(at time: CMTime, height: CGFloat) async -> NSImage? {
        let pixels = Self.pixels(height)
        let key = Self.pictureKey(time, pixels: pixels)
        if let cached = pictures.object(forKey: key) { return cached }
        guard let composed = await composed(), await Self.limiter.acquire() else { return nil }
        let generator = generator(for: composed, pixels: pixels)
        // The last frame starts a frame before the end; the end itself has none.
        let latest = CMTimeSubtract(duration, CMTime(value: 1, timescale: 600))
        let made = await Self.render(HandedOver(value: generator), time: CMTimeMaximum(.zero, CMTimeMinimum(time, latest)))
        await Self.limiter.release()
        guard let made else { return nil }
        let image = NSImage(cgImage: made, size: NSSize(width: made.width, height: made.height))
        pictures.setObject(image, forKey: key)
        return image
    }

    private static func pixels(_ height: CGFloat) -> Int {
        Int((height * 2).rounded(.up))
    }

    private static func pictureKey(_ time: CMTime, pixels: Int) -> NSString {
        "\(time.value)/\(time.timescale)|\(pixels)" as NSString
    }

    /// Set up once for each size and never changed, so requests can share it.
    private func generator(for composed: ComposedTimeline, pixels: Int) -> AVAssetImageGenerator {
        if let existing = generators[pixels] { return existing }
        let generator = AVAssetImageGenerator(asset: composed.composition)
        generator.videoComposition = composed.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let aspect = frameSize.height > 0 ? frameSize.width / frameSize.height : 16.0 / 9
        generator.maximumSize = CGSize(width: CGFloat(pixels) * aspect, height: CGFloat(pixels))
        generators[pixels] = generator
        return generator
    }

    private nonisolated static func render(_ generator: HandedOver<AVAssetImageGenerator>, time: CMTime) async -> CGImage? {
        try? await generator.value.image(at: time).image
    }
}

/// The browser's previews of timelines, one each, made when first asked
/// for and again whenever what a timeline draws has changed since.
@MainActor
enum TimelinePreviews {
    private static var previews: [UUID: TimelinePreview] = [:]

    /// The previews of `timelineIDs` as `project` has them, by ID, leaving
    /// out any that isn't there. The project's key and mix are worked out
    /// once for all of them.
    static func previews(of timelineIDs: [UUID], in project: EditingProject) -> [UUID: TimelinePreview] {
        let whole = CompositionKey(project: project)
        let curves = MixCurves.of(project)
        var found: [UUID: TimelinePreview] = [:]
        for id in timelineIDs where project.timeline(id: id) != nil {
            let key = TimelinePreview.key(of: id, in: project, whole: whole)
            if let existing = previews[id], existing.key == key {
                if existing.curves.current != curves { existing.curves.replace(with: curves) }
                found[id] = existing
            } else {
                let made = TimelinePreview(timelineID: id, project: project, key: key)
                previews[id] = made
                found[id] = made
            }
        }
        // Timelines that are gone, or no longer listed, are let go.
        previews = previews.filter { found[$0.key] != nil }
        return found
    }
}
