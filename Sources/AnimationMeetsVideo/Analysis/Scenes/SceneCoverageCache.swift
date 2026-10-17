import Foundation

/// Remembers each asset's scene coverage until something it is worked out
/// from changes: the asset (its scene edits, length and alignment), the
/// project's default sensitivity, or the change scores. Finding scenes runs
/// over every scored frame, too slow to repeat for each redraw of a view
/// that shows them. Comparing what it came from is cheap when nothing
/// changed: arrays that share storage compare equal without being read.
@MainActor
final class SceneCoverageCache {
    private struct Entry {
        var clip: MediaClip
        var sensitivity: Double
        var track: ChangeScoreTrack?
        var coverage: SceneCoverage?
    }

    private var entries: [UUID: Entry] = [:]
    /// How many times coverage was worked out rather than remembered.
    private(set) var computations = 0

    func coverage(of clip: MediaClip, in project: EditingProject, track: ChangeScoreTrack?) -> SceneCoverage? {
        if let entry = entries[clip.id], entry.clip == clip, entry.sensitivity == project.defaultSensitivity, entry.track == track {
            return entry.coverage
        }
        computations += 1
        let coverage = project.sceneCoverage(ofAsset: clip.id, track: track)
        entries[clip.id] = Entry(clip: clip, sensitivity: project.defaultSensitivity, track: track, coverage: coverage)
        return coverage
    }

    /// Forgets assets no longer in the project.
    func keep(only ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}
