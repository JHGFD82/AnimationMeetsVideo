import AppKit
import AVFoundation
import CoreMedia
import Observation

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
    /// missing, say), or the preview was let go first.
    func composed() async -> ComposedTimeline? {
        await build.value
    }

    /// Stops building it, for a preview replaced or no longer shown.
    func cancel() {
        build.cancel()
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

/// The browser's previews of timelines, one each, made when first shown.
///
/// A preview is built again only once edits to what it draws have settled
/// (`settleDelay` after the last), so a run of edits builds it once, and
/// a build overtaken by a newer one is cancelled; until then the strips
/// keep the old pictures. Edits reach it from the editor
/// (`projectChanged`), not from the browser, which isn't redrawn while
/// only values change and so would hold an older project.
@MainActor @Observable
final class TimelinePreviews {
    static let shared = TimelinePreviews()

    /// Goes up whenever a preview is replaced, so the strips that read it
    /// draw the new one.
    private(set) var revision = 0

    @ObservationIgnored let settleDelay: Duration
    @ObservationIgnored private var previews: [UUID: TimelinePreview] = [:]
    /// A rebuild waiting for edits to settle: the key it would be built
    /// to, and the wait.
    @ObservationIgnored private var pending: [UUID: (key: CompositionKey, wait: Task<Void, Never>)] = [:]

    init(settleDelay: Duration = .milliseconds(500)) {
        self.settleDelay = settleDelay
    }

    /// The previews of `timelineIDs`, by ID, made now for any not yet
    /// shown, leaving out any that isn't in `project`. Those no longer
    /// listed are let go. An existing preview is returned as it is, even
    /// when `project` differs from what it was built from: changes come
    /// through `projectChanged`.
    func previews(of timelineIDs: [UUID], in project: EditingProject) -> [UUID: TimelinePreview] {
        _ = revision
        var found: [UUID: TimelinePreview] = [:]
        var whole: CompositionKey?
        for id in timelineIDs where project.timeline(id: id) != nil {
            if let existing = previews[id] {
                found[id] = existing
                continue
            }
            // Worked out once, and only when a preview is made.
            let projectKey = whole ?? CompositionKey(project: project)
            whole = projectKey
            let made = TimelinePreview(timelineID: id, project: project, key: TimelinePreview.key(of: id, in: project, whole: projectKey))
            previews[id] = made
            found[id] = made
        }
        for id in previews.keys where found[id] == nil { release(id) }
        return found
    }

    /// The preview of `timelineID`, made now if it isn't kept, leaving the
    /// others alone: for callers that each ask for one, such as nested
    /// clips. Nil when `project` has no such timeline.
    func preview(of timelineID: UUID, in project: EditingProject) -> TimelinePreview? {
        _ = revision
        if let existing = previews[timelineID] { return existing }
        guard project.timeline(id: timelineID) != nil else { return nil }
        let made = TimelinePreview(timelineID: timelineID, project: project)
        previews[timelineID] = made
        return made
    }

    /// The project as edited: each preview whose timeline draws something
    /// that changed is built again once edits settle, and every preview's
    /// sound follows the new volumes and pans at once.
    func projectChanged(_ project: EditingProject) {
        guard !previews.isEmpty else { return }
        let whole = CompositionKey(project: project)
        let curves = MixCurves.of(project)
        for (id, preview) in previews {
            guard project.timeline(id: id) != nil else {
                release(id)
                continue
            }
            if preview.curves.current != curves { preview.curves.replace(with: curves) }
            let key = TimelinePreview.key(of: id, in: project, whole: whole)
            if key == preview.key {
                // Back to what it shows, as an undo before it settled.
                pending.removeValue(forKey: id)?.wait.cancel()
            } else if pending[id]?.key != key {
                pending[id]?.wait.cancel()
                let delay = settleDelay
                pending[id] = (key, Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    self.install(TimelinePreview(timelineID: id, project: project, key: key))
                })
            }
        }
    }

    /// Waits until every rebuild waiting for edits to settle has been made
    /// or cancelled. Each wait runs on the main actor, so how long that
    /// takes depends on what else it is doing, not only on `settleDelay`.
    /// A wait that finishes has installed its preview, and one cancelled
    /// was taken out or replaced as it was, so none is waited for twice.
    func settle() async {
        while let wait = pending.values.first?.wait {
            await wait.value
        }
    }

    /// Lets every preview go, as when the Timelines tab closes; they are
    /// made again when it is shown.
    func releaseAll() {
        for id in Array(previews.keys) { release(id) }
    }

    private func install(_ preview: TimelinePreview) {
        previews[preview.timelineID]?.cancel()
        previews[preview.timelineID] = preview
        pending[preview.timelineID] = nil
        revision += 1
    }

    private func release(_ id: UUID) {
        pending.removeValue(forKey: id)?.wait.cancel()
        previews.removeValue(forKey: id)?.cancel()
    }
}

/// The editor's previews of the timelines its nested clips play: the
/// pictures along those clips and the viewer's slip and trim frames.
/// Apart from the browser's (`TimelinePreviews.shared`), which lets every
/// preview go when the Timelines tab closes. Each is made when first asked
/// for, from the project last given to `projectChanged`, and built again
/// as the browser's are once edits to what it draws settle.
@MainActor @Observable
final class NestedTimelinePreviews {
    @ObservationIgnored private let previews: TimelinePreviews
    @ObservationIgnored private var project: EditingProject?

    init(settleDelay: Duration = .milliseconds(500)) {
        previews = TimelinePreviews(settleDelay: settleDelay)
    }

    /// The preview of `timelineID`; nil before the first project or when
    /// it has no such timeline.
    func preview(of timelineID: UUID) -> TimelinePreview? {
        guard let project else { return nil }
        return previews.preview(of: timelineID, in: project)
    }

    func projectChanged(_ project: EditingProject) {
        self.project = project
        previews.projectChanged(project)
    }

    /// Waits for rebuilds waiting on edits, as `TimelinePreviews.settle`.
    func settle() async {
        await previews.settle()
    }
}
