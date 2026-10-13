import Foundation
import Observation

/// Runs the background work on a project's assets, one at a time: capturing
/// each asset's reference data (first, since it can only be read from the
/// original file) and frame scoring for video. Results are held until the
/// views need them. They are not part of `EditingProject`: they are large,
/// mostly recomputable, and have no place in undo.
@MainActor
@Observable
final class AssetAnalysis {
    private(set) var tracks: [UUID: ChangeScoreTrack] = [:]
    /// 0...1 for assets being analyzed right now or waiting their turn.
    private(set) var progress: [UUID: Double] = [:]
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

    private struct Job {
        var id: UUID
        var url: URL
        var wantsScores: Bool
        var wantsReference: Bool
        var wantsThumbnails: Bool
        var wantsBeats: Bool
    }

    @ObservationIgnored private var unsavedBeatIDs: Set<UUID> = []
    @ObservationIgnored private var unsaved: Set<UUID> = []
    @ObservationIgnored private var unsavedReferenceIDs: Set<UUID> = []
    /// Pictures captured since the last save; dropped once saved, since they
    /// are read back from the package when needed.
    @ObservationIgnored private var unsavedPictures: [UUID: ReferenceThumbnails] = [:]
    @ObservationIgnored private var thumbnailFailures: Set<UUID> = []
    @ObservationIgnored private var waiting: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Bumped by `reset` so a result that arrives after the project was
    /// replaced is dropped.
    @ObservationIgnored private var generation = 0

    /// Starts over for a different project, with whatever scores it had saved.
    func reset(
        tracks: [UUID: ChangeScoreTrack] = [:],
        references: [UUID: AssetReference] = [:],
        thumbnailed: Set<UUID> = [],
        beats: [UUID: BeatTrack] = [:]
    ) {
        worker?.cancel()
        worker = nil
        generation += 1
        waiting = []
        progress = [:]
        failures = [:]
        unsaved = []
        unsavedReferenceIDs = []
        unsavedPictures = [:]
        thumbnailFailures = []
        referenceFailures = [:]
        beatFailures = [:]
        unsavedBeatIDs = []
        self.beats = beats
        self.thumbnailed = thumbnailed
        self.tracks = tracks
        self.references = references
    }

    /// Queues every asset that lacks reference data, and every video asset
    /// that lacks scores or reference pictures, unless already queued or failed.
    func analyzeMissing(in project: EditingProject) {
        for clip in project.clips {
            guard let url = clip.url, progress[clip.id] == nil else { continue }
            let wantsScores = clip.kind == .video && tracks[clip.id] == nil && failures[clip.id] == nil
            let wantsReference = !clip.referenceForgotten && references[clip.id] == nil && referenceFailures[clip.id] == nil
            // Pictures are chosen from the scores, so they need scores to exist or be coming.
            let wantsThumbnails = clip.kind == .video && !clip.referenceForgotten && !thumbnailed.contains(clip.id)
                && !thumbnailFailures.contains(clip.id) && (wantsScores || tracks[clip.id] != nil)
            let wantsBeats = clip.hasAudio && beats[clip.id] == nil && beatFailures[clip.id] == nil
            guard wantsScores || wantsReference || wantsThumbnails || wantsBeats else { continue }
            progress[clip.id] = 0
            waiting.append(Job(
                id: clip.id, url: url,
                wantsScores: wantsScores, wantsReference: wantsReference,
                wantsThumbnails: wantsThumbnails, wantsBeats: wantsBeats
            ))
        }
        startWorkerIfNeeded()
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

    /// Drops the original's reference data from memory. The clip's
    /// `referenceForgotten` flag keeps it from being captured again.
    func forgetReference(for id: UUID) {
        references[id] = nil
        referenceFailures[id] = nil
        unsavedReferenceIDs.remove(id)
        unsavedPictures[id] = nil
        thumbnailed.remove(id)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !waiting.isEmpty else { return }
        let expected = generation
        worker = Task { [weak self] in
            while let self, self.generation == expected, !self.waiting.isEmpty {
                let next = self.waiting.removeFirst()
                await self.run(next, generation: expected)
            }
            if let self, self.generation == expected { self.worker = nil }
        }
    }

    private func run(_ job: Job, generation expected: Int) async {
        let id = job.id
        if job.wantsReference {
            do {
                let reference = try await ReferenceCapture.capture(url: job.url)
                guard generation == expected else { return }
                references[id] = reference
                unsavedReferenceIDs.insert(id)
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                referenceFailures[id] = error.localizedDescription
            }
        }
        if job.wantsScores {
            do {
                let track = try await FrameScorer.score(url: job.url) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == expected, self.progress[id] != nil else { return }
                        self.progress[id] = fraction
                    }
                }
                guard generation == expected else { return }
                tracks[id] = track
                unsaved.insert(id)
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                failures[id] = error.localizedDescription
            }
        }

        if job.wantsThumbnails, let track = tracks[id] {
            progress[id] = 0
            do {
                let pictures = try await ReferenceThumbnailCapture.capture(
                    url: job.url, times: ReferenceThumbnailCapture.times(for: track)
                ) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == expected, self.progress[id] != nil else { return }
                        self.progress[id] = fraction
                    }
                }
                guard generation == expected else { return }
                unsavedPictures[id] = pictures
                thumbnailed.insert(id)
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                thumbnailFailures.insert(id)
            }
        }

        if job.wantsBeats {
            do {
                let track = try await BeatDetector.detect(url: job.url) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == expected, self.progress[id] != nil else { return }
                        self.progress[id] = fraction
                    }
                }
                guard generation == expected else { return }
                beats[id] = track
                unsavedBeatIDs.insert(id)
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                beatFailures[id] = error.localizedDescription
            }
        }
        progress[id] = nil
    }
}
