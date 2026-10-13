import Foundation
import Observation

/// Runs frame scoring for the project's video assets in the background, one
/// at a time, and holds the results until the views need them. Scores are not
/// part of `EditingProject`: they are large, recomputable, and have no place
/// in undo.
@MainActor
@Observable
final class AssetAnalysis {
    private(set) var tracks: [UUID: ChangeScoreTrack] = [:]
    /// 0...1 for assets being analyzed right now or waiting their turn.
    private(set) var progress: [UUID: Double] = [:]
    private(set) var failures: [UUID: String] = [:]

    @ObservationIgnored private var unsaved: Set<UUID> = []
    @ObservationIgnored private var waiting: [(id: UUID, url: URL)] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Bumped by `reset` so a result that arrives after the project was
    /// replaced is dropped.
    @ObservationIgnored private var generation = 0

    /// Starts over for a different project, with whatever scores it had saved.
    func reset(tracks: [UUID: ChangeScoreTrack] = [:]) {
        worker?.cancel()
        worker = nil
        generation += 1
        waiting = []
        progress = [:]
        failures = [:]
        unsaved = []
        self.tracks = tracks
    }

    /// Queues every video asset that has no scores yet and isn't already queued.
    func analyzeMissing(in project: EditingProject) {
        for clip in project.clips where clip.kind == .video {
            guard let url = clip.url, tracks[clip.id] == nil, progress[clip.id] == nil, failures[clip.id] == nil else { continue }
            progress[clip.id] = 0
            waiting.append((clip.id, url))
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

    func markSaved(_ ids: some Collection<UUID>) {
        unsaved.subtract(ids)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !waiting.isEmpty else { return }
        let expected = generation
        worker = Task { [weak self] in
            while let self, self.generation == expected, !self.waiting.isEmpty {
                let next = self.waiting.removeFirst()
                await self.run(next.id, url: next.url, generation: expected)
            }
            if let self, self.generation == expected { self.worker = nil }
        }
    }

    private func run(_ id: UUID, url: URL, generation expected: Int) async {
        do {
            let track = try await FrameScorer.score(url: url) { [weak self] fraction in
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
