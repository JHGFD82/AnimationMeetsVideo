import Foundation
import Observation

/// Runs the background work on a project's assets, one at a time: capturing
/// each asset's reference data (first, since it can only be read from the
/// original file) and frame scoring for video. Each result is written into
/// the project package as soon as it exists, and pictures are then dropped
/// from memory. Results only wait for a save when writing fails. They are
/// not part of `EditingProject`: they are large, mostly recomputable, and
/// have no place in undo.
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
    /// again when any of it changes.
    struct Input: Equatable {
        var id: UUID
        var file: AnalyzedFile?
        var hasAudio: Bool
    }

    /// The file a result was computed from. Beats are in the time of the
    /// file they were found in, so they are found again when it changes.
    struct AnalyzedFile: Equatable {
        var path: String
        var stamp: FileStamp?
    }

    static func inputs(of project: EditingProject) -> [Input] {
        project.clips.map { Input(id: $0.id, file: analyzedFile(of: $0), hasAudio: $0.hasAudio) }
    }

    private static func analyzedFile(of clip: MediaClip) -> AnalyzedFile? {
        clip.url.map { AnalyzedFile(path: $0.path, stamp: clip.acceptedStamp) }
    }

    private struct Job {
        var id: UUID
        var url: URL
        var file: AnalyzedFile
        var wantsScores: Bool
        var wantsReference: Bool
        var wantsThumbnails: Bool
        var wantsBeats: Bool
    }

    @ObservationIgnored private var unsavedBeatIDs: Set<UUID> = []
    /// Which file each asset's beats, or beat failure, came from. Beats read
    /// from the package are taken to match the file the asset has when it
    /// is first analyzed.
    @ObservationIgnored private var beatFiles: [UUID: AnalyzedFile] = [:]
    /// Assets whose saved beats no longer match their file, for the next
    /// save to delete.
    @ObservationIgnored private(set) var discardedBeats: Set<UUID> = []
    /// The project last analyzed, checked again once the queue drains in
    /// case a file changed while its job was running.
    @ObservationIgnored private var latestProject: EditingProject?
    @ObservationIgnored private var unsaved: Set<UUID> = []
    @ObservationIgnored private var unsavedReferenceIDs: Set<UUID> = []
    /// Pictures captured since the last save; dropped once saved, since they
    /// are read back from the package when needed.
    @ObservationIgnored private var unsavedPictures: [UUID: ReferenceThumbnails] = [:]
    @ObservationIgnored private var thumbnailFailures: Set<UUID> = []
    /// Assets whose file was gone when their job ran. They aren't queued
    /// again, or recorded as failed, until `retryUnavailable` says files
    /// may be back.
    @ObservationIgnored private var unavailable: Set<UUID> = []
    /// Assets whose saved results were looked for in the package already.
    @ObservationIgnored private var checkedPackage: Set<UUID> = []
    @ObservationIgnored private var waiting: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Bumped by `reset` so a result that arrives after the project was
    /// replaced is dropped.
    @ObservationIgnored private var generation = 0
    /// Where results are written as they arrive; nil holds them until a
    /// save. Set by `reset`, and directly after Save As moves the project.
    @ObservationIgnored var packageURL: URL?

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
        waiting = []
        progress = [:]
        stages = [:]
        failures = [:]
        unsaved = []
        unsavedReferenceIDs = []
        unsavedPictures = [:]
        thumbnailFailures = []
        checkedPackage = []
        referenceFailures = [:]
        beatFailures = [:]
        unsavedBeatIDs = []
        beatFiles = [:]
        discardedBeats = []
        latestProject = nil
        unavailable = []
        self.packageURL = packageURL
        self.beats = beats
        self.thumbnailed = thumbnailed
        self.tracks = tracks
        self.references = references
    }

    /// Queues every asset that lacks reference data, and every video asset
    /// that lacks scores or reference pictures, unless already queued or failed.
    func analyzeMissing(in project: EditingProject) {
        latestProject = project
        for clip in project.clips {
            guard let url = clip.url, let file = Self.analyzedFile(of: clip) else { continue }
            if let packageURL, checkedPackage.insert(clip.id).inserted {
                loadSaved(for: clip, from: packageURL)
            }
            // Even while a job runs, so outdated beats stop showing at once.
            discardStaleBeats(of: clip, file: file)
            guard progress[clip.id] == nil, !unavailable.contains(clip.id) else { continue }
            let wantsScores = clip.kind == .video && tracks[clip.id] == nil && failures[clip.id] == nil
            // Reference data describes the original, so it is never taken
            // from a file that replaced it.
            let canCapture = !clip.referenceForgotten && !clip.wasReplaced
            let wantsReference = canCapture && references[clip.id] == nil && referenceFailures[clip.id] == nil
            // Pictures are chosen from the scores, so they need scores to exist or be coming.
            let wantsThumbnails = clip.kind == .video && canCapture && !thumbnailed.contains(clip.id)
                && !thumbnailFailures.contains(clip.id) && (wantsScores || tracks[clip.id] != nil)
            let wantsBeats = clip.hasAudio && beats[clip.id] == nil && beatFailures[clip.id] == nil
            guard wantsScores || wantsReference || wantsThumbnails || wantsBeats else { continue }
            progress[clip.id] = 0
            waiting.append(Job(
                id: clip.id, url: url, file: file,
                wantsScores: wantsScores, wantsReference: wantsReference,
                wantsThumbnails: wantsThumbnails, wantsBeats: wantsBeats
            ))
        }
        startWorkerIfNeeded()
    }

    /// Takes whatever the package already holds for an asset that has
    /// nothing in memory, as for one imported again under the ID it had
    /// before, so it isn't analyzed twice.
    private func loadSaved(for clip: MediaClip, from packageURL: URL) {
        let id = clip.id
        if tracks[id] == nil, let saved = ProjectStore.readChangeScores(for: id, in: packageURL) { tracks[id] = saved }
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
        unsavedBeatIDs.remove(id)
        // With a package the outdated file goes now; otherwise the next save deletes it.
        if let packageURL {
            let url = ProjectStore.referenceFolder(for: id, in: packageURL).appending(path: ProjectStore.beatFileName)
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: url.path) || (try? fileManager.removeItem(at: url)) != nil { return }
        }
        discardedBeats.insert(id)
    }

    /// Records that a save deleted these assets' outdated beats.
    func markBeatsDiscarded(_ ids: some Collection<UUID>) {
        discardedBeats.subtract(ids)
    }

    /// Analyzes again what was skipped because its file was gone, for when
    /// files may have come back.
    func retryUnavailable(in project: EditingProject) {
        guard !unavailable.isEmpty else { return }
        unavailable = []
        analyzeMissing(in: project)
    }

    /// Drops a stored result and analyzes again, for a person's explicit "re-detect".
    func reanalyze(_ clip: MediaClip, in project: EditingProject) {
        tracks[clip.id] = nil
        failures[clip.id] = nil
        unsaved.remove(clip.id)
        analyzeMissing(in: project)
    }

    /// Scores computed since the last save, for `ProjectStore.save`.
    var unsavedTracks: [UUID: ChangeScoreTrack] {
        tracks.filter { unsaved.contains($0.key) }
    }

    /// Reference data captured since the last save.
    var unsavedReferences: [UUID: AssetReference] {
        references.filter { unsavedReferenceIDs.contains($0.key) }
    }

    func markSaved(_ ids: some Collection<UUID>) {
        unsaved.subtract(ids)
    }

    /// Beats found since the last save.
    var unsavedBeats: [UUID: BeatTrack] {
        beats.filter { unsavedBeatIDs.contains($0.key) }
    }

    func markBeatsSaved(_ ids: some Collection<UUID>) {
        unsavedBeatIDs.subtract(ids)
    }

    /// Reference pictures captured since the last save.
    var unsavedThumbnails: [UUID: ReferenceThumbnails] { unsavedPictures }

    func markReferencesSaved(_ ids: some Collection<UUID>) {
        unsavedReferenceIDs.subtract(ids)
    }

    func markThumbnailsSaved(_ ids: some Collection<UUID>) {
        for id in ids { unsavedPictures[id] = nil }
    }

    /// Drops the reference data of originals that `saved` marks forgotten,
    /// once that save has deleted it from the package. Until then it is
    /// kept, so undoing Forget Original brings it back.
    func dropForgottenReferences(in saved: EditingProject) {
        for clip in saved.clips where clip.referenceForgotten {
            let id = clip.id
            references[id] = nil
            referenceFailures[id] = nil
            unsavedReferenceIDs.remove(id)
            unsavedPictures[id] = nil
            thumbnailed.remove(id)
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !waiting.isEmpty else { return }
        let expected = generation
        worker = Task { [weak self] in
            while let self, self.generation == expected, !self.waiting.isEmpty {
                let next = self.waiting.removeFirst()
                await self.run(next, generation: expected)
            }
            guard let self, self.generation == expected else { return }
            self.worker = nil
            if let project = self.latestProject { self.analyzeMissing(in: project) }
        }
    }

    private func run(_ job: Job, generation expected: Int) async {
        let id = job.id
        let package = packageURL
        // An offline file can't be analyzed, and isn't a failure: it waits.
        guard FileManager.default.fileExists(atPath: job.url.path) else {
            unavailable.insert(id)
            progress[id] = nil
            stages[id] = nil
            return
        }
        if job.wantsReference {
            begin(.reference, for: id)
            do {
                let reference = try await ReferenceCapture.capture(
                    url: job.url, progress: reporter(for: id, stage: .reference, generation: expected)
                )
                guard generation == expected else { return }
                references[id] = reference
                if !(await write(to: package, { try ProjectStore.writeReference(reference, for: id, in: $0) })) {
                    unsavedReferenceIDs.insert(id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                referenceFailures[id] = error.localizedDescription
            }
        }
        if job.wantsScores {
            begin(.scenes, for: id)
            do {
                let track = try await FrameScorer.score(
                    url: job.url, progress: reporter(for: id, stage: .scenes, generation: expected)
                )
                guard generation == expected else { return }
                tracks[id] = track
                if !(await write(to: package, { try ProjectStore.writeChangeScores(track, for: id, in: $0) })) {
                    unsaved.insert(id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                failures[id] = error.localizedDescription
            }
        }

        if job.wantsThumbnails, let track = tracks[id] {
            begin(.pictures, for: id)
            do {
                let pictures = try await ReferenceThumbnailCapture.capture(
                    url: job.url, times: ReferenceThumbnailCapture.times(for: track),
                    progress: reporter(for: id, stage: .pictures, generation: expected)
                )
                guard generation == expected else { return }
                if !(await write(to: package, { try ProjectStore.writeThumbnails(pictures, for: id, in: $0) })) {
                    unsavedPictures[id] = pictures
                }
                thumbnailed.insert(id)
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                thumbnailFailures.insert(id)
            }
        }

        if job.wantsBeats {
            begin(.beats, for: id)
            do {
                let track = try await BeatDetector.detect(
                    url: job.url, progress: reporter(for: id, stage: .beats, generation: expected)
                )
                guard generation == expected else { return }
                beats[id] = track
                beatFiles[id] = job.file
                discardedBeats.remove(id)
                if !(await write(to: package, { try ProjectStore.writeBeats(track, for: id, in: $0) })) {
                    unsavedBeatIDs.insert(id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                beatFailures[id] = error.localizedDescription
                beatFiles[id] = job.file
            }
        }
        progress[id] = nil
        stages[id] = nil
    }

    /// Writes a result into the package off the main actor. False when
    /// there is no package or the write failed, so the result is kept for
    /// the next save instead.
    private func write(to package: URL?, _ body: @escaping @Sendable (URL) throws -> Void) async -> Bool {
        guard let package else { return false }
        do {
            try await Task.detached(priority: .utility) { try body(package) }.value
            return true
        } catch {
            NSLog("Couldn't write analysis results into the project: \(error.localizedDescription)")
            return false
        }
    }

    /// Starts a stage's progress from zero, so the bar doesn't sit full or
    /// jump back when the next stage begins.
    private func begin(_ stage: Stage, for id: UUID) {
        stages[id] = stage
        progress[id] = 0
    }

    /// Reports a stage's progress. Updates arrive on the main actor later,
    /// so one from a stage that has ended is dropped.
    private func reporter(for id: UUID, stage: Stage, generation expected: Int) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.generation == expected, self.stages[id] == stage else { return }
                self.progress[id] = fraction
            }
        }
    }
}
