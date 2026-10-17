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
    private(set) var failures: [UUID: String] = [:]
    /// Reference data captured at import. Never re-captured for an asset that
    /// has it, so it keeps describing the original after the file is replaced.
    private(set) var references: [UUID: AssetReference] = [:]
    private(set) var referenceFailures: [UUID: String] = [:]
    /// Assets whose reference pictures are captured, in memory or on disk.
    private(set) var thumbnailed: Set<UUID> = []
    /// Beats found in each asset's audio, in the asset's own time. An empty
    /// track means the audio was analyzed and no steady beat was found.
    private(set) var beats: [UUID: BeatTrack] = [:]
    private(set) var beatFailures: [UUID: String] = [:]

    /// What `analyzeMissing` looks at for each asset, so views can call it
    /// again when any of it changes. A job whose input no longer matches is
    /// replaced, and its results are dropped.
    struct Input: Equatable {
        var id: UUID
        var file: AnalyzedFile?
        var hasAudio: Bool
        /// False once the original is forgotten or the file was replaced:
        /// reference data is never taken from such a file.
        var canCaptureReference: Bool
    }

    /// The file a result was computed from. Beats are in the time of the
    /// file they were found in, so they are found again when it changes.
    struct AnalyzedFile: Equatable {
        var path: String
        var stamp: FileStamp?
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
        /// Runs `body` against the package. Everything that touches package
        /// files goes through here, so it happens in the order it was asked.
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
            perform: { package, body in try await PackageWriter.shared.perform(on: package, body) }
        )
    }

    @ObservationIgnored var backend = Backend.live

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
        var wantsScores: Bool
        var wantsReference: Bool
        var wantsThumbnails: Bool
        var wantsBeats: Bool
    }

    private func isCurrent(_ lease: Lease) -> Bool {
        generation == lease.generation && owners[lease.id]?.token == lease.token
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
    @ObservationIgnored private var dirtyPictures: [UUID: Int] = [:]
    /// Pictures captured since the last save; dropped once saved, since they
    /// are read back from the package when needed.
    @ObservationIgnored private var heldPictures: [UUID: ReferenceThumbnails] = [:]
    /// Assets whose saved beats no longer match their file, for the next
    /// save to delete, with the revision of the discard.
    @ObservationIgnored private var discardRevisions: [UUID: Int] = [:]

    /// Which file each asset's beats, or beat failure, came from. Beats read
    /// from the package are taken to match the file the asset has when it
    /// is first analyzed.
    @ObservationIgnored private var beatFiles: [UUID: AnalyzedFile] = [:]
    @ObservationIgnored private var thumbnailFailures: Set<UUID> = []
    /// Assets whose file was gone when their job ran, with the file that was
    /// missing. They aren't queued again, or recorded as failed, until
    /// `retryUnavailable` says files may be back or the asset gets another file.
    @ObservationIgnored private var unavailable: [UUID: AnalyzedFile] = [:]
    /// Assets whose saved results were looked for in the package already.
    @ObservationIgnored private var checkedPackage: Set<UUID> = []
    /// The project last analyzed, checked again once the queue drains.
    @ObservationIgnored private var latestProject: EditingProject?
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
        failures = [:]
        dirtyScores = [:]
        dirtyReferences = [:]
        dirtyBeats = [:]
        dirtyPictures = [:]
        heldPictures = [:]
        discardRevisions = [:]
        thumbnailFailures = []
        checkedPackage = []
        referenceFailures = [:]
        beatFailures = [:]
        beatFiles = [:]
        latestProject = nil
        unavailable = [:]
        self.packageURL = packageURL
        self.beats = beats
        self.thumbnailed = thumbnailed
        self.tracks = tracks
        self.references = references
    }

    /// Queues every asset that lacks reference data, and every video asset
    /// that lacks scores or reference pictures, unless already queued or failed.
    /// A job whose inputs changed since it was queued is replaced.
    func analyzeMissing(in project: EditingProject) {
        latestProject = project
        let present = Set(project.clips.map(\.id))
        for id in owners.keys where !present.contains(id) { revoke(id) }
        for clip in project.clips {
            let input = Self.input(of: clip)
            if let owner = owners[clip.id], owner.input != input { revoke(clip.id) }
            guard let url = clip.url, let file = input.file else { continue }
            if let packageURL, checkedPackage.insert(clip.id).inserted {
                loadSaved(for: clip, from: packageURL, includingScores: true)
            }
            // Even while a job runs, so outdated beats stop showing at once.
            discardStaleBeats(of: clip, file: file)
            if let missing = unavailable[clip.id] {
                if missing == file { continue }
                unavailable[clip.id] = nil
            }
            guard owners[clip.id] == nil else { continue }
            let wantsScores = clip.kind == .video && tracks[clip.id] == nil && failures[clip.id] == nil
            // Reference data describes the original, so it is never taken
            // from a file that replaced it.
            let canCapture = input.canCaptureReference
            let wantsReference = canCapture && references[clip.id] == nil && referenceFailures[clip.id] == nil
            // Pictures are chosen from the scores, so they need scores to exist or be coming.
            let wantsThumbnails = clip.kind == .video && canCapture && !thumbnailed.contains(clip.id)
                && !thumbnailFailures.contains(clip.id) && (wantsScores || tracks[clip.id] != nil)
            let wantsBeats = clip.hasAudio && beats[clip.id] == nil && beatFailures[clip.id] == nil
            guard wantsScores || wantsReference || wantsThumbnails || wantsBeats else { continue }
            nextToken += 1
            let lease = Lease(generation: generation, id: clip.id, token: nextToken)
            owners[clip.id] = Owner(token: nextToken, input: input, wantsReference: wantsReference)
            progress[clip.id] = 0
            waiting.append(Job(
                lease: lease, url: url,
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

    /// Takes whatever the package already holds for an asset that has
    /// nothing in memory, as for one imported again under the ID it had
    /// before, so it isn't analyzed twice.
    private func loadSaved(for clip: MediaClip, from packageURL: URL, includingScores: Bool) {
        let id = clip.id
        if includingScores, tracks[id] == nil, let saved = ProjectStore.readChangeScores(for: id, in: packageURL) { tracks[id] = saved }
        if beats[id] == nil, let saved = ProjectStore.readBeats(for: id, in: packageURL) { beats[id] = saved }
        guard !clip.referenceForgotten else { return }
        if references[id] == nil, let saved = ProjectStore.readReference(for: id, in: packageURL) { references[id] = saved }
        if ProjectStore.hasThumbnails(for: id, in: packageURL) { thumbnailed.insert(id) }
    }

    /// Drops beats found in a file the asset no longer uses, or in one that
    /// has lost its sound, so they are not shown and are found again.
    private func discardStaleBeats(of clip: MediaClip, file: AnalyzedFile) {
        let id = clip.id
        guard beats[id] != nil || beatFailures[id] != nil else { return }
        guard let analyzed = beatFiles[id] else {
            if clip.hasAudio {
                beatFiles[id] = file
                return
            }
            discardBeats(of: id)
            return
        }
        if analyzed != file || !clip.hasAudio { discardBeats(of: id) }
    }

    private func discardBeats(of id: UUID) {
        beats[id] = nil
        beatFailures[id] = nil
        beatFiles[id] = nil
        dirtyBeats[id] = nil
        // Stays discarded until the file is confirmed gone: here if there is
        // a package, otherwise in the next save. The deletion is queued behind
        // any write already started, so an older write can't bring the file back.
        nextRevision += 1
        let revision = nextRevision
        discardRevisions[id] = revision
        guard let package = packageURL else { return }
        let epoch = packageEpoch
        Task {
            let removed = await attempt(on: package) { package in
                let url = ProjectStore.referenceFolder(for: id, in: package).appending(path: ProjectStore.beatFileName)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            if removed, epoch == packageEpoch, discardRevisions[id] == revision { discardRevisions[id] = nil }
        }
    }

    /// Analyzes again what was skipped because its file was gone, for when
    /// files may have come back.
    func retryUnavailable(in project: EditingProject) {
        guard !unavailable.isEmpty else { return }
        unavailable = [:]
        analyzeMissing(in: project)
    }

    /// For a person's explicit "re-detect": the stored score goes, from
    /// memory and from the package, any job still working on it is replaced,
    /// and exactly one new attempt is made that does not read the saved score.
    /// Reference pictures are original-reference artifacts and are kept.
    func reanalyze(_ clip: MediaClip, in project: EditingProject) {
        let id = clip.id
        revoke(id)
        tracks[id] = nil
        failures[id] = nil
        dirtyScores[id] = nil
        // Whatever else the package holds is read now; the score is not, and
        // the old file is deleted, so a failed attempt can't bring it back.
        if let packageURL {
            if checkedPackage.insert(id).inserted { loadSaved(for: clip, from: packageURL, includingScores: false) }
            Task {
                _ = await attempt(on: packageURL) { package in
                    try ProjectStore.removeChangeScores(for: id, in: package)
                }
            }
        }
        analyzeMissing(in: project)
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
        fileprivate var discards: [UUID: Int] = [:]

        var changeScores: [UUID: ChangeScoreTrack] { scores.mapValues(\.value) }
        var referenceData: [UUID: AssetReference] { references.mapValues(\.value) }
        var thumbnails: [UUID: ReferenceThumbnails] { pictures.mapValues(\.value) }
        var beatTracks: [UUID: BeatTrack] { beats.mapValues(\.value) }
        var discardedBeats: Set<UUID> { Set(discards.keys) }
    }

    func unsavedResults() -> UnsavedResults {
        var results = UnsavedResults()
        for (id, revision) in dirtyScores { if let value = tracks[id] { results.scores[id] = (revision, value) } }
        for (id, revision) in dirtyReferences { if let value = references[id] { results.references[id] = (revision, value) } }
        for (id, revision) in dirtyPictures { if let value = heldPictures[id] { results.pictures[id] = (revision, value) } }
        for (id, revision) in dirtyBeats { if let value = beats[id] { results.beats[id] = (revision, value) } }
        results.discards = discardRevisions
        return results
    }

    func markSaved(_ results: UnsavedResults) {
        for (id, held) in results.scores { acknowledge(\.dirtyScores, id, held.revision) }
        for (id, held) in results.references { acknowledge(\.dirtyReferences, id, held.revision) }
        for (id, held) in results.pictures { acknowledge(\.dirtyPictures, id, held.revision) }
        for (id, held) in results.beats { acknowledge(\.dirtyBeats, id, held.revision) }
        for (id, revision) in results.discards { acknowledge(\.discardRevisions, id, revision) }
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
    var discardedBeats: Set<UUID> { Set(discardRevisions.keys) }

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
        let held = unsavedResults()
        var unchanged: Bool { generation == expected && packageEpoch == epoch }
        for (id, entry) in held.scores {
            guard unchanged else { return }
            await persist(\.dirtyScores, id, entry.revision, to: package, epoch: epoch) {
                try ProjectStore.writeChangeScores(entry.value, for: id, in: $0)
            }
        }
        for (id, entry) in held.references {
            guard unchanged else { return }
            await persist(\.dirtyReferences, id, entry.revision, to: package, epoch: epoch) {
                try ProjectStore.writeReference(entry.value, for: id, in: $0)
            }
        }
        for (id, entry) in held.pictures {
            guard unchanged else { return }
            await persist(\.dirtyPictures, id, entry.revision, to: package, epoch: epoch) {
                try ProjectStore.writeThumbnails(entry.value, for: id, in: $0)
            }
        }
        for (id, entry) in held.beats {
            guard unchanged else { return }
            await persist(\.dirtyBeats, id, entry.revision, to: package, epoch: epoch) {
                try ProjectStore.writeBeats(entry.value, for: id, in: $0)
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
            referenceFailures[id] = nil
            dirtyReferences[id] = nil
            dirtyPictures[id] = nil
            heldPictures[id] = nil
            thumbnailed.remove(id)
            if owners[id]?.wantsReference == true {
                revoke(id)
                revoked = true
            }
        }
        if revoked { analyzeMissing(in: saved) }
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
            if let project = self.latestProject, !Task.isCancelled { self.analyzeMissing(in: project) }
        }
    }

    private func run(_ job: Job) async {
        let lease = job.lease
        let id = lease.id
        // However the job ends, it lets go of what it still owns.
        defer { release(lease) }
        // An offline file can't be analyzed, and isn't a failure: it waits.
        guard FileManager.default.fileExists(atPath: job.url.path) else {
            if let file = owners[id]?.input.file { unavailable[id] = file }
            return
        }
        if job.wantsReference {
            let proceed = await runStage(
                .reference, lease: lease,
                work: { [backend] progress in try await backend.captureReference(job.url, progress) },
                commit: { reference in
                    references[id] = reference
                    let revision = markDirty(\.dirtyReferences, id)
                    await persist(\.dirtyReferences, id, revision, to: packageURL, epoch: packageEpoch) {
                        try ProjectStore.writeReference(reference, for: id, in: $0)
                    }
                },
                failed: { referenceFailures[id] = $0 }
            )
            guard proceed else { return }
        }
        if job.wantsScores {
            let proceed = await runStage(
                .scenes, lease: lease,
                work: { [backend] progress in try await backend.scoreFrames(job.url, progress) },
                commit: { track in
                    tracks[id] = track
                    let revision = markDirty(\.dirtyScores, id)
                    await persist(\.dirtyScores, id, revision, to: packageURL, epoch: packageEpoch) {
                        try ProjectStore.writeChangeScores(track, for: id, in: $0)
                    }
                },
                failed: { failures[id] = $0 }
            )
            guard proceed else { return }
        }
        if job.wantsThumbnails, let track = tracks[id] {
            let proceed = await runStage(
                .pictures, lease: lease,
                work: { [backend] progress in try await backend.capturePictures(job.url, track, progress) },
                commit: { pictures in
                    heldPictures[id] = pictures
                    thumbnailed.insert(id)
                    let revision = markDirty(\.dirtyPictures, id)
                    await persist(\.dirtyPictures, id, revision, to: packageURL, epoch: packageEpoch) {
                        try ProjectStore.writeThumbnails(pictures, for: id, in: $0)
                    }
                },
                failed: { _ in thumbnailFailures.insert(id) }
            )
            guard proceed else { return }
        }
        if job.wantsBeats, let file = owners[id]?.input.file {
            _ = await runStage(
                .beats, lease: lease,
                work: { [backend] progress in try await backend.detectBeats(job.url, progress) },
                commit: { track in
                    beats[id] = track
                    beatFiles[id] = file
                    discardRevisions[id] = nil
                    let revision = markDirty(\.dirtyBeats, id)
                    await persist(\.dirtyBeats, id, revision, to: packageURL, epoch: packageEpoch) {
                        try ProjectStore.writeBeats(track, for: id, in: $0)
                    }
                },
                failed: {
                    beatFailures[id] = $0
                    beatFiles[id] = file
                }
            )
        }
    }

    /// One stage of a job. `commit` runs only while the lease is held, and
    /// the lease is checked again before the next stage. Returns whether the
    /// job should go on: false once it was replaced or cancelled.
    private func runStage<Result: Sendable>(
        _ stage: Stage,
        lease: Lease,
        work: (@escaping @Sendable (Double) -> Void) async throws -> Result,
        commit: (Result) async -> Void,
        failed: (String) -> Void
    ) async -> Bool {
        guard isCurrent(lease), !Task.isCancelled else { return false }
        stages[lease.id] = stage
        progress[lease.id] = 0
        let relay = ProgressRelay { [weak self] fraction in
            self?.apply(fraction, stage: stage, lease: lease)
        }
        do {
            let result = try await work(relay.report)
            guard isCurrent(lease), !Task.isCancelled else { return false }
            await commit(result)
            return isCurrent(lease)
        } catch {
            guard isCurrent(lease) else { return false }
            if error is CancellationError {
                // Cancelled by reset, which ends the lease too. Anything else
                // is recorded rather than retried, so it can't loop.
                if Task.isCancelled { return false }
                failed("The analysis was interrupted.")
            } else {
                failed(error.localizedDescription)
            }
            return true
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
        _ id: UUID,
        _ revision: Int,
        to package: URL?,
        epoch: Int,
        _ body: @escaping @Sendable (URL) throws -> Void
    ) async {
        guard let package else { return }
        let written = await attempt(on: package, body)
        if written, epoch == packageEpoch { acknowledge(keyPath, id, revision) }
    }

    /// Runs package work off the main actor. False when it failed.
    private func attempt(on package: URL, _ body: @escaping @Sendable (URL) throws -> Void) async -> Bool {
        do {
            try await backend.perform(package, body)
            return true
        } catch {
            NSLog("Couldn't write analysis results into the project: \(error.localizedDescription)")
            return false
        }
    }
}

/// Runs package file work one piece at a time, in the order asked.
actor PackageWriter {
    static let shared = PackageWriter()

    func perform(on package: URL, _ body: @Sendable (URL) throws -> Void) throws {
        try body(package)
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
