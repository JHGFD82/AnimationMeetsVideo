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

    private struct Job {
        var id: UUID
        var url: URL
        var wantsScores: Bool
        var wantsReference: Bool
    }

    @ObservationIgnored private var unsaved: Set<UUID> = []
    @ObservationIgnored private var unsavedReferenceIDs: Set<UUID> = []
    @ObservationIgnored private var waiting: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Bumped by `reset` so a result that arrives after the project was
    /// replaced is dropped.
    @ObservationIgnored private var generation = 0

    /// Starts over for a different project, with whatever scores it had saved.
    func reset(tracks: [UUID: ChangeScoreTrack] = [:], references: [UUID: AssetReference] = [:]) {
        worker?.cancel()
        worker = nil
        generation += 1
        waiting = []
        progress = [:]
        failures = [:]
        unsaved = []
        unsavedReferenceIDs = []
        referenceFailures = [:]
        self.tracks = tracks
        self.references = references
    }

    /// Queues every asset that lacks reference data, and every video asset
    /// that has no scores, unless already queued or failed.
    func analyzeMissing(in project: EditingProject) {
        for clip in project.clips {
            guard let url = clip.url, progress[clip.id] == nil else { continue }
            let wantsScores = clip.kind == .video && tracks[clip.id] == nil && failures[clip.id] == nil
            let wantsReference = references[clip.id] == nil && referenceFailures[clip.id] == nil
            guard wantsScores || wantsReference else { continue }
            progress[clip.id] = 0
            waiting.append(Job(id: clip.id, url: url, wantsScores: wantsScores, wantsReference: wantsReference))
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

    func markReferencesSaved(_ ids: some Collection<UUID>) {
        unsavedReferenceIDs.subtract(ids)
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
        guard job.wantsScores else {
            progress[id] = nil
            return
        }
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
            progress[id] = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == expected else { return }
            failures[id] = error.localizedDescription
            progress[id] = nil
        }
    }
}
