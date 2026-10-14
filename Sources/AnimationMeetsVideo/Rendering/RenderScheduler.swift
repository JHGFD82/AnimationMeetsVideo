import CoreMedia
import Foundation
import Observation
import QuartzCore

/// Renders the viewed timeline's segments into the render cache in the
/// background, one at a time, only while the timeline is idle: any edit,
/// scrub or playback stops the render in progress, and rendering resumes
/// after `idleSeconds` (two) of quiet. It also waits while the Mac is hot or in
/// Low Power Mode. A finished render bumps `finishedCount`, so the viewer
/// rebuilds and plays it.
@MainActor
@Observable
final class RenderScheduler {
    struct ActiveRender {
        var key: String
        var progress: Double
    }

    enum State: Equatable {
        case pending, rendered
        case rendering(Double)
    }

    /// The viewed timeline's segments, in order.
    private(set) var segments: [RenderSegment] = []
    /// Keys whose render is in the cache.
    private(set) var rendered: Set<String> = []
    private(set) var active: ActiveRender?
    private(set) var finishedCount = 0

    /// The package whose cache is used; nil stops rendering.
    var packageURL: URL? {
        didSet {
            guard packageURL != oldValue else { return }
            job?.cancel()
            segments = []
            rendered = []
            failed = []
            if let packageURL { RenderCache(packageURL: packageURL).removePartials() }
        }
    }

    var cache: RenderCache? { packageURL.map(RenderCache.init(packageURL:)) }

    /// How long the timeline must be quiet before rendering starts.
    @ObservationIgnored var idleSeconds = 2.0

    @ObservationIgnored private var project: EditingProject?
    @ObservationIgnored private var timelineID: UUID?
    /// Bumped by every `update`, so work planned from an older project is dropped.
    @ObservationIgnored private var planVersion = 0
    @ObservationIgnored private var exportBuild: (version: Int, composed: ComposedTimeline)?
    @ObservationIgnored private var lastActivity = CACurrentMediaTime()
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var job: Task<Void, Error>?
    /// Keys that couldn't be rendered, so they aren't tried again and again.
    @ObservationIgnored private var failed: Set<String> = []

    /// Takes the plan from the viewer's latest build of `project`.
    func update(project: EditingProject, timelineID: UUID, segments: [RenderSegment]) {
        self.project = project
        self.timelineID = timelineID
        self.segments = segments
        planVersion += 1
        exportBuild = nil
        if let cache {
            rendered = Set(segments.filter { $0.needsRender && cache.file(for: $0.key) != nil }.map(\.key))
        }
        if let active, !pending.contains(where: { $0.key == active.key }) {
            job?.cancel()
        }
        startWorkerIfNeeded()
    }

    /// An edit or scrub: stops the render in progress and restarts the wait.
    func noteActivity() {
        lastActivity = CACurrentMediaTime()
        job?.cancel()
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        noteActivity()
    }

    /// Segments still to render, in timeline order, each key once.
    var pending: [RenderSegment] {
        var seen: Set<String> = []
        return segments.filter { segment in
            segment.needsRender && !rendered.contains(segment.key) && !failed.contains(segment.key)
                && seen.insert(segment.key).inserted
        }
    }

    func state(of segment: RenderSegment) -> State? {
        guard segment.needsRender else { return nil }
        if rendered.contains(segment.key) { return .rendered }
        if let active, active.key == segment.key { return .rendering(active.progress) }
        return .pending
    }

    /// How much of what `clipID` takes part in is rendered, while some of
    /// it still isn't; nil when it needs no rendering or all is done.
    func progress(forClip clipID: UUID) -> Double? {
        var total = 0.0, done = 0.0
        for segment in segments where segment.needsRender && segment.clipIDs.contains(clipID) {
            let length = segment.range.duration.seconds
            total += length
            switch state(of: segment) {
            case .rendered: done += length
            case .rendering(let fraction): done += length * fraction
            default: break
            }
        }
        guard total > 0, done < total else { return nil }
        return done / total
    }

    private var isIdle: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return !isPlaying
            && CACurrentMediaTime() - lastActivity >= idleSeconds
            && thermal != .serious && thermal != .critical
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, packageURL != nil, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.work()
            self?.worker = nil
        }
    }

    private func work() async {
        while !Task.isCancelled {
            guard let cache, let next = pending.first else { return }
            guard isIdle else {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let version = planVersion
            do {
                let composed = try await exportComposition()
                // The project may have changed while it was being built.
                guard version == planVersion, isIdle, pending.contains(where: { $0.key == next.key }) else { continue }
                active = ActiveRender(key: next.key, progress: 0)
                let report: @Sendable (Double) -> Void = { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.active?.key == next.key else { return }
                        self.active?.progress = fraction
                    }
                }
                let job = Task.detached(priority: .utility) {
                    try await SegmentRenderer.render(next, from: composed, into: cache, progress: report)
                }
                self.job = job
                try await job.value
                rendered.insert(next.key)
                finishedCount += 1
                cache.evict(keeping: Set(segments.map(\.key)))
            } catch is CancellationError {
            } catch {
                NSLog("Couldn't render a segment: \(error.localizedDescription)")
                failed.insert(next.key)
            }
            active = nil
            job = nil
        }
    }

    /// The timeline built for export, which renders are drawn from, made
    /// once per plan.
    private func exportComposition() async throws -> ComposedTimeline {
        if let exportBuild, exportBuild.version == planVersion { return exportBuild.composed }
        guard let project, let timelineID else { throw CancellationError() }
        let version = planVersion
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: timelineID)
        if version == planVersion { exportBuild = (version, composed) }
        return composed
    }
}
