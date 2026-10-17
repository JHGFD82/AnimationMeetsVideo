import Foundation
import Observation

/// Runs the background work on a project's assets, one at a time: capturing
/// each asset's reference data (first, since it can only be read from the
/// original file) and frame scoring for video. Each result is written into
/// the project package as soon as it exists, and pictures are then dropped
/// from memory. Results only wait for a save when writing fails. They are
/// not part of `EditingProject`: they are large, mostly recomputable, and
/// have no place in undo.
///
/// Everything here runs on the main actor, but a job suspends at every
/// `await`, and the project can change meanwhile. So each job holds a
/// `Lease` (project generation plus a token for that asset's job) which is
/// checked again after every suspension before anything is changed, and each
/// result carries a revision so that a write finishing late can only mark
/// the result it actually wrote as saved.
@MainActor
@Observable
final class AssetAnalysis {
    private(set) var tracks: [UUID: ChangeScoreTrack] = [:]
    /// 0...1 for assets being analyzed right now or waiting their turn,
    /// within the current stage.
    private(set) var progress: [UUID: Double] = [:]
    /// What is being done to each asset in `progress`; absent while waiting.
    private(set) var stages: [UUID: Stage] = [:]

    enum Stage {
        case reference, scenes, pictures, beats

        var label: String {
            switch self {
            case .reference: "Reading the original…"
            case .scenes: "Finding scenes…"
            case .pictures: "Saving pictures…"
            case .beats: "Finding beats…"
            }
        }
    }
    /// Why a stage produced nothing, by asset and stage. Cleared when the
    /// file it ran on changes, and by `retry`.
    private(set) var stageFailures: [AssetStage: AnalysisFailure] = [:]
    /// Results that exist but could not be written into the project. They
    /// are kept and written with the next save or `writeHeldResults`.
    private(set) var persistenceFailures: [AssetStage: AnalysisFailure] = [:]

    struct AssetStage: Hashable, Sendable {
        var id: UUID
        var stage: Stage
    }

    func failure(_ stage: Stage, for id: UUID) -> AnalysisFailure? {
        stageFailures[AssetStage(id: id, stage: stage)]
    }

    /// The first failure of any stage, in the order the stages run.
    func firstFailure(for id: UUID) -> AnalysisFailure? {
        [Stage.reference, .scenes, .pictures, .beats].lazy.compactMap { self.failure($0, for: id) }.first
    }

    private func messages(of stage: Stage) -> [UUID: String] {
        var result: [UUID: String] = [:]
        for (key, failure) in stageFailures where key.stage == stage { result[key.id] = failure.message }
        return result
    }

    /// The scene-detection, reference and beat failures by asset, as text.
    var failures: [UUID: String] { messages(of: .scenes) }
    var referenceFailures: [UUID: String] { messages(of: .reference) }
    var beatFailures: [UUID: String] { messages(of: .beats) }

    /// Reference data captured at import. Never re-captured for an asset that
    /// has it, so it keeps describing the original after the file is replaced.
    private(set) var references: [UUID: AssetReference] = [:]
    /// The scores of each asset's original footage, for aligning a
    /// replacement to the original. Reference data like `references`: taken
    /// only while the asset's file still is the original, never replaced,
    /// never made from a replacement file, and deleted by Forget Original.
    /// The scores in `tracks` describe the file in use now and are separate.
    private(set) var originalScores: [UUID: ChangeScoreTrack] = [:]
    @ObservationIgnored private var originalSources: [UUID: FileStamp] = [:]
    /// Assets whose reference pictures are captured, in memory or on disk.
    private(set) var thumbnailed: Set<UUID> = []
    /// Beats found in each asset's audio, in the asset's own time. An empty
    /// track means the audio was analyzed and no steady beat was found.
    private(set) var beats: [UUID: BeatTrack] = [:]

    /// What `update(with:)` looks at for each asset, so views can call it
    /// again when any of it changes. A job whose input no longer matches is
    /// replaced, and its results are dropped.
    struct Input: Equatable {
        var id: UUID
        var file: AnalyzedFile?
        var hasAudio: Bool
        /// False once the original is forgotten or the file was replaced:
        /// reference data is never taken from such a file.
        var canCaptureReference: Bool
        /// What the analysis runs with, so results made with other settings
        /// are not mixed in; see `AnalysisProvenance`.
        var settings = AssetAnalysis.settings
    }

    nonisolated private static let settings = AnalysisKind.allCases
        .map { "\($0.rawValue):\(AnalysisProvenance.current(for: $0).algorithm)/\(AnalysisProvenance.current(for: $0).settings)" }
        .joined(separator: "|")

    /// The file a result was computed from. Beats are in the time of the
    /// file they were found in, so they are found again when it changes.
    struct AnalyzedFile: Equatable {
        var path: String
        var stamp: FileStamp?
    }

    /// The file a result in memory was computed from. Results read from the
    /// package carry only the verified stamp, not the path they had then.
    private struct ResultSource {
        var path: String?
        var stamp: FileStamp?

        /// Files with stamps are the same file when the stamps are, wherever
        /// they are; ones that can't be stamped only when the path is.
        func matches(_ file: AnalyzedFile) -> Bool {
            if let stamp, let other = file.stamp { return stamp == other }
            return stamp == nil && file.stamp == nil && path == file.path
        }
    }

    /// A result retired in memory whose retirement is not yet confirmed in
    /// the package.
    struct Invalidation: Hashable, Sendable {
        var kind: AnalysisKind
        var id: UUID
    }

    static func inputs(of project: EditingProject) -> [Input] {
        project.clips.map(input(of:))
    }

    private static func input(of clip: MediaClip) -> Input {
        Input(
            id: clip.id, file: analyzedFile(of: clip), hasAudio: clip.hasAudio,
            canCaptureReference: !clip.referenceForgotten && !clip.wasReplaced
        )
    }

    private static func analyzedFile(of clip: MediaClip) -> AnalyzedFile? {
        clip.url.map { AnalyzedFile(path: $0.path, stamp: clip.acceptedStamp) }
    }

    // MARK: Test seams

    /// The expensive and slow steps, replaceable so tests can hold one open.
    struct Backend: Sendable {
        typealias Progress = @Sendable (Double) -> Void
        var captureReference: @Sendable (URL, @escaping Progress) async throws -> AssetReference
        var scoreFrames: @Sendable (URL, @escaping Progress) async throws -> ChangeScoreTrack
        var capturePictures: @Sendable (URL, ChangeScoreTrack, @escaping Progress) async throws -> ReferenceThumbnails
        var detectBeats: @Sendable (URL, @escaping Progress) async throws -> BeatTrack
        /// What the package holds for an asset, read away from the main actor
        /// and in turn with everything else that changes the package. Scores and
        /// beats are checked against `identity`; the reference and its pictures
        /// are looked for only when `includingReference`.
        var readSaved: @Sendable (_ package: URL, _ id: UUID, _ identity: FileStamp?, _ includingReference: Bool) async -> SavedAnalysis
        /// Whether the media file is there and what it looks like right now,
        /// asked away from the main actor.
        var observeFile: @Sendable (URL) async -> FileObservation
        /// Runs `body` against the package, through the `PackageCoordinator`
        /// so it happens in the order it was asked, relative to saves too.
        var perform: @Sendable (URL, @escaping @Sendable (URL) throws -> Void) async throws -> Void

        static let live = Backend(
            captureReference: { try await ReferenceCapture.capture(url: $0, progress: $1) },
            scoreFrames: { try await FrameScorer.score(url: $0, progress: $1) },
            capturePictures: {
                try await ReferenceThumbnailCapture.capture(
                    url: $0, times: ReferenceThumbnailCapture.times(for: $1), progress: $2
                )
            },
            detectBeats: { try await BeatDetector.detect(url: $0, progress: $1) },
            readSaved: { package, id, identity, includingReference in
                let read = try? await PackageCoordinator.shared.run(on: [package]) { () -> SavedAnalysis in
                    var saved = SavedAnalysis()
                    saved.scores = ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: identity)
                    saved.beats = ProjectStore.readVerifiedBeats(for: id, in: package, identity: identity)
                    if includingReference {
                        saved.reference = ProjectStore.readReference(for: id, in: package)
                        saved.originalScores = ProjectStore.readVerifiedOriginalScores(for: id, in: package)
                        saved.hasThumbnails = ProjectStore.hasThumbnails(for: id, in: package)
                    }
                    return saved
                }
                return read ?? SavedAnalysis()
            },
            observeFile: { url in
                await Task.detached(priority: .utility) {
                    FileObservation(exists: FileManager.default.fileExists(atPath: url.path), stamp: FileStamp(url: url))
                }.value
            },
            perform: { package, body in try await PackageCoordinator.shared.run(on: [package]) { try body(package) } }
        )
    }

    @ObservationIgnored var backend = Backend.live

    /// A media file as seen on disk, as opposed to as the project accepted it.
    struct FileObservation: Sendable {
        var exists: Bool
        var stamp: FileStamp?
    }

    /// What a package held for one asset when it was read.
    struct SavedAnalysis: Sendable {
        var scores: CachedResult<ChangeScoreTrack> = .absent
        var beats: CachedResult<BeatTrack> = .absent
        var originalScores: CachedResult<ChangeScoreTrack> = .absent
        var reference: AssetReference?
        var hasThumbnails = false
    }

    // MARK: Job ownership

    /// Proof that a job still owns an asset's work. Checked after every
    /// suspension, before any state is changed.
    private struct Lease {
        var generation: Int
        var id: UUID
        var token: Int
    }

    /// What the live (queued or running) job for an asset was started for.
    private struct Owner {
        var token: Int
        var input: Input
        var wantsReference: Bool
    }

    private struct Job {
        var lease: Lease
        var url: URL
        var file: AnalyzedFile
        var wantsScores: Bool
        var wantsReference: Bool
        var wantsThumbnails: Bool
        var wantsBeats: Bool
    }

    private func isCurrent(_ lease: Lease) -> Bool {
        generation == lease.generation && owners[lease.id]?.token == lease.token
    }

    /// `isCurrent`, and the asset still has the inputs the job was made for
    /// according to the project as it is right now. A job found out of date
    /// is replaced at once, without waiting for anyone to call `update`.
    private func stillValid(_ lease: Lease) -> Bool {
        guard isCurrent(lease) else { return false }
        guard let project = projectSource?(), let owner = owners[lease.id] else { return true }
        let now = project.clips.first { $0.id == lease.id }.map(Self.input(of:))
        if now == owner.input { return true }
        update(with: project)
        return false
    }

    @ObservationIgnored private var owners: [UUID: Owner] = [:]
    @ObservationIgnored private var nextToken = 0
    /// Source of result revisions. Never reset, so a revision identifies one
    /// result across projects too.
    @ObservationIgnored private var nextRevision = 0

    // MARK: Unsaved results

    /// Revisions of the results not yet confirmed in the package. A write
    /// clears an entry only if it still holds the revision that was written.
    @ObservationIgnored private var dirtyScores: [UUID: Int] = [:]
    @ObservationIgnored private var dirtyReferences: [UUID: Int] = [:]
    @ObservationIgnored private var dirtyBeats: [UUID: Int] = [:]
    @ObservationIgnored private var dirtyOriginalScores: [UUID: Int] = [:]
    @ObservationIgnored private var dirtyPictures: [UUID: Int] = [:]
    /// Pictures captured since the last save; dropped once saved, since they
    /// are read back from the package when needed.
    @ObservationIgnored private var heldPictures: [UUID: ReferenceThumbnails] = [:]
    /// Saved results retired in memory but not yet confirmed retired in the
    /// package, with the revision of the retirement. Retried until it holds.
    @ObservationIgnored private var pendingInvalidations: [Invalidation: Int] = [:]
    /// Retirements that could not be made durable, by asset. While one is
    /// listed, the outdated result could come back when the project is reopened.
    private(set) var invalidationFailures: [Invalidation: AnalysisFailure] = [:]

    /// Which file each asset's scores, beats, or failure to find them, came
    /// from. Scores and beats describe the file the asset uses now, so they
    /// are retired when it changes; nothing is assumed about a result that
    /// has no source.
    @ObservationIgnored private var scoreSources: [UUID: ResultSource] = [:]
    @ObservationIgnored private var beatSources: [UUID: ResultSource] = [:]
    /// Assets whose file was gone when their job ran, with the file that was
    /// missing. They aren't queued again, or recorded as failed, until
    /// `retryUnavailable` says files may be back or the asset gets another file.
    @ObservationIgnored private var unavailable: [UUID: AnalyzedFile] = [:]
    /// Assets whose saved results were looked for in the package already.
    @ObservationIgnored private var checkedPackage: Set<UUID> = []
    /// Assets whose saved results are being read right now, with the token of
    /// that read. Nothing is decided about such an asset until the read is
    /// back, so a result already on disk is not analyzed a second time.
    @ObservationIgnored private var loading: [UUID: Int] = [:]
    /// Assets whose file on disk differs from the one the project accepted:
    /// it was changed outside the app. No current-file analysis is made, or
    /// cached results used, for them until the change is accepted (which
    /// changes the accepted stamp) or `retry` asks to look again, so nothing
    /// is ever recorded as computed from a file it was not computed from.
    private(set) var changedFiles: [UUID: ChangedFile] = [:]

    struct ChangedFile: Equatable, Sendable {
        var accepted: FileStamp?
        var observed: FileStamp?
    }

    /// Whether a file on disk contradicts the stamp the project accepted.
    /// With either side unknown there is nothing to contradict.
    private static func contradicts(accepted: FileStamp?, observed: FileStamp?) -> Bool {
        guard let accepted, let observed else { return false }
        return accepted != observed
    }
    /// Why saved results were not used, by asset, as of the last read.
    private(set) var rejectedResults: [UUID: [AnalysisKind: AnalysisRejection]] = [:]
    @ObservationIgnored private var invalidationTasks: [Invalidation: Task<Void, Never>] = [:]
    /// The project last analyzed, checked again once the queue drains.
    @ObservationIgnored private var latestProject: EditingProject?
    /// The project as it is now, read when a job checks its inputs. Set by
    /// whoever owns the project; without it the last project passed to
    /// `update(with:)` stands in.
    @ObservationIgnored var projectSource: (@MainActor () -> EditingProject?)?
    @ObservationIgnored private var waiting: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Bumped by `reset` so a result that arrives after the project was
    /// replaced is dropped.
    @ObservationIgnored private var generation = 0
    /// Bumped whenever the destination changes, so a write that went to a
    /// package that is no longer the active one is not counted as saved.
    @ObservationIgnored private var packageEpoch = 0
    /// Where results are written as they arrive; nil holds them until a
    /// save. Set by `reset`, and directly after Save As moves the project.
    @ObservationIgnored var packageURL: URL? {
        didSet { if oldValue != packageURL { packageEpoch += 1 } }
    }

    /// Starts over for a different project, with whatever scores it had saved.
    func reset(
        tracks: [UUID: ChangeScoreTrack] = [:],
        references: [UUID: AssetReference] = [:],
        thumbnailed: Set<UUID> = [],
        beats: [UUID: BeatTrack] = [:],
        originalScores: [UUID: ChangeScoreTrack] = [:],
        sources: AnalysisSources = AnalysisSources(),
        rejected: [UUID: [AnalysisKind: AnalysisRejection]] = [:],
        packageURL: URL? = nil
    ) {
        worker?.cancel()
        worker = nil
        generation += 1
        packageEpoch += 1
        owners = [:]
        waiting = []
        progress = [:]
        stages = [:]
        stageFailures = [:]
        persistenceFailures = [:]
        dirtyScores = [:]
        dirtyReferences = [:]
        dirtyBeats = [:]
        dirtyOriginalScores = [:]
        originalSources = [:]
        dirtyPictures = [:]
        heldPictures = [:]
        pendingInvalidations = [:]
        invalidationFailures = [:]
        checkedPackage = []
        loading = [:]
        changedFiles = [:]
        rejectedResults = rejected
        invalidationTasks = [:]
        scoreSources = [:]
        beatSources = [:]
        latestProject = nil
        unavailable = [:]
        self.packageURL = packageURL
        self.thumbnailed = thumbnailed
        self.references = references
        // A result that comes without the file it was computed from is not
        // known to describe any file, so it is left out and analyzed again.
        self.tracks = tracks.filter { sources.scores[$0.key] != nil }
        self.beats = beats.filter { sources.beats[$0.key] != nil }
        // Original scores without a record of the original are not trusted.
        self.originalScores = originalScores.filter { sources.originalScores[$0.key] != nil }
        originalSources = sources.originalScores
        scoreSources = sources.scores.mapValues { ResultSource(path: nil, stamp: $0) }
        beatSources = sources.beats.mapValues { ResultSource(path: nil, stamp: $0) }
    }

    /// The one way the project's state reaches the analysis: retires jobs and
    /// results the project no longer allows, then queues every asset that
    /// lacks reference data, and every video asset that lacks scores or
    /// reference pictures, unless already queued or failed. Call it whenever
    /// `Input`s change. Jobs also check themselves against `projectSource`
    /// before each stage and each commit, so a missed call can delay work
    /// but can't let an outdated result in.
    func update(with project: EditingProject) {
        latestProject = project
        let present = Set(project.clips.map(\.id))
        for id in owners.keys where !present.contains(id) { revoke(id) }
        for id in changedFiles.keys where !present.contains(id) { changedFiles[id] = nil }
        for clip in project.clips {
            let input = Self.input(of: clip)
            if let owner = owners[clip.id], owner.input != input { revoke(clip.id) }
            // A change that has been accepted since is a new file to the analysis.
            if let changed = changedFiles[clip.id], changed.accepted != clip.acceptedStamp { changedFiles[clip.id] = nil }
            guard let url = clip.url, let file = input.file else { continue }
            // Even while a job runs, so outdated results stop showing at once.
            discardStaleResults(of: clip, file: file)
            // What the package already holds is read first, away from the main
            // actor; the asset is looked at again once it is back.
            if let packageURL, !checkedPackage.contains(clip.id) {
                if loading[clip.id] == nil { beginLoad(for: clip, from: packageURL) }
                continue
            }
            if let missing = unavailable[clip.id] {
                if missing == file { continue }
                unavailable[clip.id] = nil
            }
            guard owners[clip.id] == nil, changedFiles[clip.id] == nil else { continue }
            let wantsScores = clip.kind == .video && tracks[clip.id] == nil && failure(.scenes, for: clip.id) == nil
            // Reference data describes the original, so it is never taken
            // from a file that replaced it.
            let canCapture = input.canCaptureReference
            let wantsReference = canCapture && references[clip.id] == nil && failure(.reference, for: clip.id) == nil
            // Pictures are chosen from the scores, so they need scores to exist or be coming.
            let wantsThumbnails = clip.kind == .video && canCapture && !thumbnailed.contains(clip.id)
                && failure(.pictures, for: clip.id) == nil && (wantsScores || tracks[clip.id] != nil)
            let wantsBeats = clip.hasAudio && beats[clip.id] == nil && failure(.beats, for: clip.id) == nil
            guard wantsScores || wantsReference || wantsThumbnails || wantsBeats else { continue }
            nextToken += 1
            let lease = Lease(generation: generation, id: clip.id, token: nextToken)
            owners[clip.id] = Owner(token: nextToken, input: input, wantsReference: wantsReference)
            progress[clip.id] = 0
            waiting.append(Job(
                lease: lease, url: url, file: file,
                wantsScores: wantsScores, wantsReference: wantsReference,
                wantsThumbnails: wantsThumbnails, wantsBeats: wantsBeats
            ))
        }
        startWorkerIfNeeded()
    }

    /// Ends whatever job owns the asset: a queued one never starts, and a
    /// running one finds out at its next check and drops its results.
    private func revoke(_ id: UUID) {
        owners[id] = nil
        waiting.removeAll { $0.lease.id == id }
        progress[id] = nil
        stages[id] = nil
    }

    /// Reads whatever the package already holds for an asset, as for one
    /// imported again under the ID it had before, so it isn't analyzed twice.
    /// Scores and beats are taken only when their record says they came from
    /// the file the asset has now. The read is queued behind any retirement
    /// of this asset's results already asked for, so it can't see them.
    private func beginLoad(for clip: MediaClip, from package: URL) {
        nextToken += 1
        let token = nextToken, id = clip.id
        loading[id] = token
        let expectedGeneration = generation, epoch = packageEpoch
        let identity = clip.acceptedStamp, includingReference = !clip.referenceForgotten
        let url = clip.url
        let earlier = invalidationTasks.filter { $0.key.id == id }.map(\.value)
        Task {
            for task in earlier { await task.value }
            var saved = await backend.readSaved(package, id, identity, includingReference)
            // Results fit the file the project accepted; if the file on disk
            // is not that one they say nothing about it.
            var seen: FileObservation?
            if let url { seen = await backend.observeFile(url) }
            if let seen, seen.exists, Self.contradicts(accepted: identity, observed: seen.stamp),
               generation == expectedGeneration, loading[id] == token {
                changedFiles[id] = ChangedFile(accepted: identity, observed: seen.stamp)
                saved.scores = .absent
                saved.beats = .absent
            }
            guard generation == expectedGeneration, loading[id] == token else { return }
            loading[id] = nil
            if epoch == packageEpoch { publish(saved, for: id) }
            // Either way, look at the asset again: with its results, or with
            // the package it has now.
            if let project = projectSource?() ?? latestProject { update(with: project) }
        }
    }

    /// Takes what a read found, for what has nothing in memory yet.
    private func publish(_ saved: SavedAnalysis, for id: UUID) {
        checkedPackage.insert(id)
        switch saved.scores {
        case .valid(let track, let source) where tracks[id] == nil:
            tracks[id] = track
            scoreSources[id] = ResultSource(path: nil, stamp: source)
        case .rejected(let reason): rejectedResults[id, default: [:]][.scores] = reason
        default: break
        }
        switch saved.beats {
        case .valid(let track, let source) where beats[id] == nil:
            beats[id] = track
            beatSources[id] = ResultSource(path: nil, stamp: source)
        case .rejected(let reason): rejectedResults[id, default: [:]][.beats] = reason
        default: break
        }
        // Read before a later Forget Original, so it is checked again here.
        let forgotten = (projectSource?() ?? latestProject)?.clips.first { $0.id == id }?.referenceForgotten ?? false
        guard !forgotten else { return }
        if references[id] == nil, let reference = saved.reference { references[id] = reference }
        switch saved.originalScores {
        case .valid(let track, let source) where originalScores[id] == nil:
            originalScores[id] = track
            originalSources[id] = source
        case .rejected(let reason): rejectedResults[id, default: [:]][.originalScores] = reason
        default: break
        }
        if saved.hasThumbnails { thumbnailed.insert(id) }
    }

    /// True while saved results are being read.
    var isLoadingSaved: Bool { !loading.isEmpty }

    /// Drops scores and beats found in a file the asset no longer uses (and
    /// beats in one that has lost its sound), so they are not shown and are
    /// found again. A result with no known source is dropped too.
    private func discardStaleResults(of clip: MediaClip, file: AnalyzedFile) {
        let id = clip.id
        if tracks[id] != nil, scoreSources[id]?.matches(file) != true {
            discardResult(.scores, of: id)
        }
        if beats[id] != nil, beatSources[id]?.matches(file) != true || !clip.hasAudio {
            discardResult(.beats, of: id)
        }
        // A failure belongs to the file it happened on: with another file, or
        // without sound for beats, it says nothing, and the stage may be tried.
        for stage in [Stage.reference, .scenes, .pictures, .beats] {
            guard let failure = failure(stage, for: id) else { continue }
            let sameFile = failure.file.map { ResultSource(path: $0.path, stamp: $0.stamp).matches(file) } ?? false
            if !sameFile || (stage == .beats && !clip.hasAudio) { stageFailures[AssetStage(id: id, stage: stage)] = nil }
        }
    }

    /// Retires a result: gone from memory now, and from the package as soon
    /// as that can be confirmed. Until then it is pending, and tried again
    /// with the next write or save and by `retryPendingInvalidations`.
    private func discardResult(_ kind: AnalysisKind, of id: UUID) {
        switch kind {
        case .scores:
            tracks[id] = nil
            stageFailures[AssetStage(id: id, stage: .scenes)] = nil
            scoreSources[id] = nil
            dirtyScores[id] = nil
        case .beats:
            beats[id] = nil
            stageFailures[AssetStage(id: id, stage: .beats)] = nil
            beatSources[id] = nil
            dirtyBeats[id] = nil
        case .originalScores:
            // Reference data: only Forget Original removes it.
            return
        }
        nextRevision += 1
        let key = Invalidation(kind: kind, id: id)
        pendingInvalidations[key] = nextRevision
        persistInvalidation(key)
    }

    /// Asks the package to retire a result. Queued behind any write already
    /// started, so an older write can't bring the file back. The result stays
    /// pending, and the failure visible, until the package confirms.
    private func persistInvalidation(_ key: Invalidation) {
        guard let package = packageURL, let revision = pendingInvalidations[key] else { return }
        let epoch = packageEpoch
        invalidationTasks[key] = Task {
            let failure = await attemptReporting(on: package) { package in
                try ProjectStore.invalidate(key.kind, for: key.id, in: package)
            }
            guard epoch == packageEpoch, pendingInvalidations[key] == revision else { return }
            invalidationTasks[key] = nil
            if let failure {
                invalidationFailures[key] = AnalysisFailure(
                    stage: key.kind == .scores ? .scenes : .beats, error: failure, file: nil, kind: .persistence
                )
            } else {
                pendingInvalidations[key] = nil
                invalidationFailures[key] = nil
            }
        }
    }

    /// Tries again to retire results whose retirement is not yet confirmed.
    func retryPendingInvalidations() {
        for key in pendingInvalidations.keys { persistInvalidation(key) }
    }

    /// Analyzes again what was skipped because its file was gone, for when
    /// files may have come back.
    func retryUnavailable(in project: EditingProject) {
        guard !unavailable.isEmpty else { return }
        unavailable = [:]
        changedFiles = [:]
        update(with: project)
    }

    /// Whether the asset's file still is its original, so scores made from it
    /// are the original's: a replaced, realigned or forgotten asset is not.
    private func capturesOriginalScores(_ id: UUID) -> Bool {
        owners[id]?.input.canCaptureReference == true
    }

    private func keepAsOriginal(_ track: ChangeScoreTrack, of id: UUID, source: FileStamp?) {
        originalScores[id] = track
        originalSources[id] = source
        _ = markDirty(\.dirtyOriginalScores, id)
    }

    /// The original footage's scores for aligning a replacement, in the
    /// original's own time: a candidate's cuts minus these give the offset
    /// from original time to the candidate's file, whatever files the asset
    /// used in between. Never made from a replacement. If the asset's file
    /// still is the original and only its current-file scores exist (as when
    /// a replacement is chosen before they were set aside), those are the
    /// original's and are kept as such now.
    func resolveOriginalScores(for clip: MediaClip) -> Result<ChangeScoreTrack, OriginalScoresUnavailable> {
        let id = clip.id
        if clip.referenceForgotten { return .failure(.forgotten) }
        if let track = originalScores[id] { return .success(track) }
        let input = Self.input(of: clip)
        if input.canCaptureReference, let track = tracks[id], let file = input.file,
           scoreSources[id]?.matches(file) == true {
            keepAsOriginal(track, of: id, source: file.stamp)
            return .success(track)
        }
        // Saved but unusable is not the same as never saved.
        return .failure(rejectedResults[id]?[.originalScores]?.originalScoresReason ?? .notCaptured)
    }

    /// A problem saving this asset's results, or retiring outdated ones, that
    /// the person can act on with `retryPersistence`.
    func persistenceProblem(for id: UUID) -> AnalysisFailure? {
        persistenceFailures.first { $0.key.id == id }?.value
            ?? invalidationFailures.first { $0.key.id == id }?.value
    }

    var hasPersistenceProblems: Bool { !persistenceFailures.isEmpty || !invalidationFailures.isEmpty }

    /// Tries again to write results that could not be saved and to retire
    /// outdated ones that could not be removed.
    func retryPersistence() async {
        retryPendingInvalidations()
        await writeHeldResults()
    }

    /// Tries one stage again for one asset, without touching anything else:
    /// its failure is cleared, and so is the asset's wait for a missing file,
    /// so a file that came back is tried too. Reading the original and its
    /// pictures are refused, and the failure kept, for an asset whose
    /// original is forgotten or whose file was replaced: those describe the
    /// original, and are never captured from whatever file is there now.
    /// Returns whether the stage was queued to be tried.
    @discardableResult
    func retry(_ stage: Stage, for id: UUID, in project: EditingProject) -> Bool {
        guard let clip = project.clips.first(where: { $0.id == id }) else { return false }
        if stage == .reference || stage == .pictures, !Self.input(of: clip).canCaptureReference { return false }
        stageFailures[AssetStage(id: id, stage: stage)] = nil
        unavailable[id] = nil
        changedFiles[id] = nil
        update(with: project)
        return true
    }

    /// Tries every failed stage of an asset again.
    func retryFailures(for id: UUID, in project: EditingProject) {
        for stage in [Stage.reference, .scenes, .pictures, .beats] where failure(stage, for: id) != nil {
            retry(stage, for: id, in: project)
        }
    }

    /// For a person's explicit "re-detect": the stored score goes, from
    /// memory and from the package (retired for good, even if its file can't
    /// be deleted), any job still working on it is replaced, and exactly one
    /// new attempt is made that does not read the saved score. Reference
    /// pictures are original-reference artifacts and are kept.
    func reanalyze(_ clip: MediaClip, in project: EditingProject) {
        let id = clip.id
        revoke(id)
        // A read already under way may carry the old score; it is dropped,
        // and the next one is queued behind the retirement.
        loading[id] = nil
        discardResult(.scores, of: id)
        update(with: project)
    }

    // MARK: Saving

    /// What was unsaved at one moment, for `ProjectStore.save`. Pass it to
    /// `markSaved` once the save succeeds: only these exact revisions are then
    /// marked saved, so a result that arrived or changed meanwhile stays unsaved.
    struct UnsavedResults {
        fileprivate var scores: [UUID: (revision: Int, value: ChangeScoreTrack)] = [:]
        fileprivate var references: [UUID: (revision: Int, value: AssetReference)] = [:]
        fileprivate var pictures: [UUID: (revision: Int, value: ReferenceThumbnails)] = [:]
        fileprivate var beats: [UUID: (revision: Int, value: BeatTrack)] = [:]
        fileprivate var original: [UUID: (revision: Int, value: ChangeScoreTrack)] = [:]
        fileprivate var invalidations: [Invalidation: Int] = [:]
        /// The file each result in here was computed from, to be saved with it.
        fileprivate(set) var sources = AnalysisSources()

        var changeScores: [UUID: ChangeScoreTrack] { scores.mapValues(\.value) }
        var referenceData: [UUID: AssetReference] { references.mapValues(\.value) }
        var thumbnails: [UUID: ReferenceThumbnails] { pictures.mapValues(\.value) }
        var beatTracks: [UUID: BeatTrack] { beats.mapValues(\.value) }
        var originalScoreTracks: [UUID: ChangeScoreTrack] { original.mapValues(\.value) }
        var discardedBeats: Set<UUID> { Set(invalidations.keys.filter { $0.kind == .beats }.map(\.id)) }
        var invalidatedScores: Set<UUID> { Set(invalidations.keys.filter { $0.kind == .scores }.map(\.id)) }
    }

    func unsavedResults() -> UnsavedResults {
        var results = UnsavedResults()
        for (id, revision) in dirtyScores {
            if let value = tracks[id] {
                results.scores[id] = (revision, value)
                results.sources.scores[id] = scoreSources[id]?.stamp
            }
        }
        for (id, revision) in dirtyReferences { if let value = references[id] { results.references[id] = (revision, value) } }
        for (id, revision) in dirtyOriginalScores {
            if let value = originalScores[id] {
                results.original[id] = (revision, value)
                results.sources.originalScores[id] = originalSources[id]
            }
        }
        for (id, revision) in dirtyPictures { if let value = heldPictures[id] { results.pictures[id] = (revision, value) } }
        for (id, revision) in dirtyBeats {
            if let value = beats[id] {
                results.beats[id] = (revision, value)
                results.sources.beats[id] = beatSources[id]?.stamp
            }
        }
        results.invalidations = pendingInvalidations
        return results
    }

    func markSaved(_ results: UnsavedResults) {
        for (id, held) in results.scores { acknowledge(\.dirtyScores, id, held.revision) }
        for (id, held) in results.references { acknowledge(\.dirtyReferences, id, held.revision) }
        for (id, held) in results.pictures { acknowledge(\.dirtyPictures, id, held.revision) }
        for (id, held) in results.beats { acknowledge(\.dirtyBeats, id, held.revision) }
        for (id, held) in results.original { acknowledge(\.dirtyOriginalScores, id, held.revision) }
        for (key, revision) in results.invalidations where pendingInvalidations[key] == revision {
            pendingInvalidations[key] = nil
            invalidationFailures[key] = nil
        }
    }

    /// Scores computed since the last save.
    var unsavedTracks: [UUID: ChangeScoreTrack] { unsavedResults().changeScores }
    /// Reference data captured since the last save.
    var unsavedReferences: [UUID: AssetReference] { unsavedResults().referenceData }
    /// Beats found since the last save.
    var unsavedBeats: [UUID: BeatTrack] { unsavedResults().beatTracks }
    /// Reference pictures captured since the last save.
    var unsavedThumbnails: [UUID: ReferenceThumbnails] { unsavedResults().thumbnails }
    /// Assets whose outdated saved beats are still to be deleted.
    var discardedBeats: Set<UUID> { Set(pendingInvalidations.keys.filter { $0.kind == .beats }.map(\.id)) }

    private func markDirty(_ keyPath: ReferenceWritableKeyPath<AssetAnalysis, [UUID: Int]>, _ id: UUID) -> Int {
        nextRevision += 1
        self[keyPath: keyPath][id] = nextRevision
        return nextRevision
    }

    private func acknowledge(_ keyPath: ReferenceWritableKeyPath<AssetAnalysis, [UUID: Int]>, _ id: UUID, _ revision: Int) {
        guard self[keyPath: keyPath][id] == revision else { return }
        self[keyPath: keyPath][id] = nil
        if dirtyPictures[id] == nil { heldPictures[id] = nil }
    }

    /// Writes results held for a save, those that arrived while there was
    /// no `packageURL` or whose write failed, into the package now. Each
    /// that is written no longer waits for a save. Stops if the project or
    /// the destination changes meanwhile; the new destination gets its own call.
    func writeHeldResults() async {
        guard let package = packageURL else { return }
        let expected = generation, epoch = packageEpoch
        retryPendingInvalidations()
        let held = unsavedResults()
        var unchanged: Bool { generation == expected && packageEpoch == epoch }
        for (id, entry) in held.scores {
            guard unchanged else { return }
            let source = held.sources.scores[id]
            await persist(\.dirtyScores, .scenes, id, entry.revision, to: package, epoch: epoch) {
                try ProjectStore.writeChangeScores(entry.value, for: id, in: $0, source: source)
            }
        }
        for (id, entry) in held.references {
            guard unchanged else { return }
            await persist(\.dirtyReferences, .reference, id, entry.revision, to: package, epoch: epoch) {
                try ProjectStore.writeReference(entry.value, for: id, in: $0)
            }
        }
        for (id, entry) in held.original {
            guard unchanged else { return }
            let source = held.sources.originalScores[id]
            await persist(\.dirtyOriginalScores, .scenes, id, entry.revision, to: package, epoch: epoch) {
                try ProjectStore.writeOriginalScores(entry.value, for: id, in: $0, source: source)
            }
        }
        for (id, entry) in held.pictures {
            guard unchanged else { return }
            await persist(\.dirtyPictures, .pictures, id, entry.revision, to: package, epoch: epoch) {
                try ProjectStore.writeThumbnails(entry.value, for: id, in: $0)
            }
        }
        for (id, entry) in held.beats {
            guard unchanged else { return }
            let source = held.sources.beats[id]
            await persist(\.dirtyBeats, .beats, id, entry.revision, to: package, epoch: epoch) {
                try ProjectStore.writeBeats(entry.value, for: id, in: $0, source: source)
            }
        }
    }

    /// Drops the reference data of originals that `saved` marks forgotten,
    /// once that save has deleted it from the package. Until then it is
    /// kept, so undoing Forget Original brings it back. A capture still
    /// running for one of them is replaced, so it can't bring the data back.
    func dropForgottenReferences(in saved: EditingProject) {
        var revoked = false
        for clip in saved.clips where clip.referenceForgotten {
            let id = clip.id
            references[id] = nil
            stageFailures[AssetStage(id: id, stage: .reference)] = nil
            stageFailures[AssetStage(id: id, stage: .pictures)] = nil
            dirtyReferences[id] = nil
            originalScores[id] = nil
            originalSources[id] = nil
            dirtyOriginalScores[id] = nil
            dirtyPictures[id] = nil
            heldPictures[id] = nil
            thumbnailed.remove(id)
            if owners[id]?.wantsReference == true {
                revoke(id)
                revoked = true
            }
        }
        if revoked { update(with: saved) }
    }

    // MARK: Running

    private func startWorkerIfNeeded() {
        guard worker == nil, !waiting.isEmpty else { return }
        let expected = generation
        worker = Task { [weak self] in
            while let self, self.generation == expected, !self.waiting.isEmpty {
                let next = self.waiting.removeFirst()
                guard self.isCurrent(next.lease) else { continue }
                await self.run(next)
            }
            guard let self, self.generation == expected else { return }
            self.worker = nil
            if let project = self.projectSource?() ?? self.latestProject, !Task.isCancelled { self.update(with: project) }
        }
    }

    private func run(_ job: Job) async {
        let lease = job.lease
        let id = lease.id
        // However the job ends, it lets go of what it still owns.
        defer { release(lease) }
        let source = ResultSource(path: job.file.path, stamp: job.file.stamp)
        // An offline file can't be analyzed, and isn't a failure: it waits.
        let seen = await backend.observeFile(job.url)
        guard stillValid(lease) else { return }
        guard seen.exists else {
            if let file = owners[id]?.input.file { unavailable[id] = file }
            return
        }
        // The file is not the one the project accepted: nothing is analyzed
        // from it, and nothing is recorded under the old identity.
        if Self.contradicts(accepted: job.file.stamp, observed: seen.stamp) {
            changedFiles[id] = ChangedFile(accepted: job.file.stamp, observed: seen.stamp)
            return
        }
        if job.wantsReference {
            let proceed = await runStage(
                .reference, lease: lease, file: job.file, url: job.url, observed: seen.stamp,
                work: { [backend] progress in try await backend.captureReference(job.url, progress) },
                commit: { reference in
                    references[id] = reference
                    let revision = markDirty(\.dirtyReferences, id)
                    await persist(\.dirtyReferences, .reference, id, revision, to: packageURL, epoch: packageEpoch) {
                        try ProjectStore.writeReference(reference, for: id, in: $0)
                    }
                }
            )
            guard proceed else { return }
        }
        if job.wantsScores {
            let proceed = await runStage(
                .scenes, lease: lease, file: job.file, url: job.url, observed: seen.stamp,
                work: { [backend] progress in
                    let track = try await backend.scoreFrames(job.url, progress)
                    try track.validate()
                    return track
                },
                commit: { track in
                    tracks[id] = track
                    scoreSources[id] = source
                    let revision = markDirty(\.dirtyScores, id)
                    // While the asset's file is still the original, these are
                    // also the original's scores, kept for aligning a replacement.
                    let isOriginal = capturesOriginalScores(id) && originalScores[id] == nil
                    if isOriginal { keepAsOriginal(track, of: id, source: job.file.stamp) }
                    let originalRevision = dirtyOriginalScores[id]
                    await persist(\.dirtyScores, .scenes, id, revision, to: packageURL, epoch: packageEpoch) {
                        try ProjectStore.writeChangeScores(track, for: id, in: $0, source: job.file.stamp)
                    }
                    if isOriginal, let originalRevision {
                        await persist(\.dirtyOriginalScores, .scenes, id, originalRevision, to: packageURL, epoch: packageEpoch) {
                            try ProjectStore.writeOriginalScores(track, for: id, in: $0, source: job.file.stamp)
                        }
                    }
                }
            )
            guard proceed else { return }
        }
        if job.wantsThumbnails, let track = tracks[id] {
            let proceed = await runStage(
                .pictures, lease: lease, file: job.file, url: job.url, observed: seen.stamp,
                work: { [backend] progress in try await backend.capturePictures(job.url, track, progress) },
                commit: { pictures in
                    heldPictures[id] = pictures
                    thumbnailed.insert(id)
                    let revision = markDirty(\.dirtyPictures, id)
                    await persist(\.dirtyPictures, .pictures, id, revision, to: packageURL, epoch: packageEpoch) {
                        try ProjectStore.writeThumbnails(pictures, for: id, in: $0)
                    }
                }
            )
            guard proceed else { return }
        }
        if job.wantsBeats {
            _ = await runStage(
                .beats, lease: lease, file: job.file, url: job.url, observed: seen.stamp,
                work: { [backend] progress in try await backend.detectBeats(job.url, progress) },
                commit: { track in
                    beats[id] = track
                    beatSources[id] = source
                    pendingInvalidations[Invalidation(kind: .beats, id: id)] = nil
                    let revision = markDirty(\.dirtyBeats, id)
                    await persist(\.dirtyBeats, .beats, id, revision, to: packageURL, epoch: packageEpoch) {
                        try ProjectStore.writeBeats(track, for: id, in: $0, source: job.file.stamp)
                    }
                }
            )
        }
    }

    /// One stage of a job. `commit` runs only while the lease is held, and
    /// the lease is checked again before the next stage. A failure is recorded
    /// with the file it happened on; a file that vanished means the asset is
    /// unavailable rather than failed. Returns whether the job should go on:
    /// false once it was replaced or cancelled.
    private func runStage<Result: Sendable>(
        _ stage: Stage,
        lease: Lease,
        file: AnalyzedFile,
        url: URL,
        observed: FileStamp?,
        work: (@escaping @Sendable (Double) -> Void) async throws -> Result,
        commit: (Result) async -> Void
    ) async -> Bool {
        guard stillValid(lease), !Task.isCancelled else { return false }
        stages[lease.id] = stage
        progress[lease.id] = 0
        let relay = ProgressRelay { [weak self] fraction in
            self?.apply(fraction, stage: stage, lease: lease)
        }
        do {
            let result = try await work(relay.report)
            guard stillValid(lease), !Task.isCancelled else { return false }
            // Looked at again: a file that changed while it was read gave a
            // result for neither version.
            let after = await backend.observeFile(url)
            guard stillValid(lease), !Task.isCancelled else { return false }
            if after.stamp != observed {
                changedFiles[lease.id] = ChangedFile(accepted: file.stamp, observed: after.stamp)
                return false
            }
            await commit(result)
            return stillValid(lease)
        } catch {
            guard isCurrent(lease) else { return false }
            // Cancelled by reset, which ends the lease too. A cancellation
            // from anywhere else is recorded rather than retried, so it
            // can't loop.
            if error is CancellationError, Task.isCancelled { return false }
            record(AnalysisFailure(stage: stage, error: error, file: file), for: lease.id)
            return true
        }
    }

    private func record(_ failure: AnalysisFailure, for id: UUID) {
        if failure.kind == .missingFile {
            if let file = failure.file { unavailable[id] = file }
        } else {
            stageFailures[AssetStage(id: id, stage: failure.stage)] = failure
        }
    }

    /// Lets go of the asset's progress, unless a newer job has taken over.
    private func release(_ lease: Lease) {
        guard isCurrent(lease) else { return }
        owners[lease.id] = nil
        progress[lease.id] = nil
        stages[lease.id] = nil
    }

    /// Applies progress from the stage that is running now, for the job that
    /// is running now; later reports from anything else are dropped.
    private func apply(_ fraction: Double, stage: Stage, lease: Lease) {
        guard fraction.isFinite, isCurrent(lease), stages[lease.id] == stage else { return }
        progress[lease.id] = max(progress[lease.id] ?? 0, min(max(fraction, 0), 1))
    }

    // MARK: Package I/O

    /// Writes one result and, if it went to the active package and is still
    /// the revision held, counts it as saved. A write to a package that is no
    /// longer active, or one that fails, leaves the result waiting.
    private func persist(
        _ keyPath: ReferenceWritableKeyPath<AssetAnalysis, [UUID: Int]>,
        _ stage: Stage,
        _ id: UUID,
        _ revision: Int,
        to package: URL?,
        epoch: Int,
        _ body: @escaping @Sendable (URL) throws -> Void
    ) async {
        guard let package else { return }
        let failure = await attemptReporting(on: package, body)
        guard epoch == packageEpoch else { return }
        let key = AssetStage(id: id, stage: stage)
        if let failure {
            persistenceFailures[key] = AnalysisFailure(stage: stage, error: failure, file: nil, kind: .persistence)
        } else {
            persistenceFailures[key] = nil
            acknowledge(keyPath, id, revision)
        }
    }

    /// Runs package work off the main actor. Nil when it worked, otherwise
    /// what went wrong.
    private func attemptReporting(on package: URL, _ body: @escaping @Sendable (URL) throws -> Void) async -> (any Error)? {
        do {
            try await backend.perform(package, body)
            return nil
        } catch {
            NSLog("Couldn't change the project package: \(error.localizedDescription)")
            return error
        }
    }
}

/// Carries progress from a worker thread to the main actor with at most one
/// update waiting, so a fast reporter can't pile up main-actor tasks. The
/// latest value wins; values that aren't numbers are ignored.
private final class ProgressRelay: @unchecked Sendable {
    private let state = NSLock()
    private var latest: Double?
    private var scheduled = false
    private let deliver: @MainActor @Sendable (Double) -> Void

    init(deliver: @escaping @MainActor @Sendable (Double) -> Void) {
        self.deliver = deliver
    }

    var report: @Sendable (Double) -> Void {
        { [self] fraction in
            guard fraction.isFinite else { return }
            let needsTask = state.withLock { () -> Bool in
                latest = fraction
                defer { scheduled = true }
                return !scheduled
            }
            guard needsTask else { return }
            Task { @MainActor in
                let value = state.withLock { () -> Double? in
                    defer { latest = nil; scheduled = false }
                    return latest
                }
                if let value { deliver(value) }
            }
        }
    }
}
