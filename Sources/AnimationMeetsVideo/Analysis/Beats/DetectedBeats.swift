import Foundation
import os

/// The beats analysis has detected in each file, mirrored from
/// `AssetAnalysis` for the model to read while it makes Beat Keys'
/// keyframes (see docs/keyframing-effects.md), which isn't on the main
/// actor. Each open project's editor keeps its own analysis's tracks here
/// (its `owner`), so one window doesn't drop another's; asset IDs are
/// unique, so reading them all together is safe.
final class DetectedBeats: Sendable {
    static let shared = DetectedBeats()

    private let state = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: [UUID: BeatTrack]]())

    /// Beat tracks by asset, of every open project.
    var tracks: [UUID: BeatTrack] {
        state.withLock { owners in
            owners.values.reduce(into: [:]) { merged, tracks in merged.merge(tracks) { current, _ in current } }
        }
    }

    /// Takes one analysis's tracks; returns whether they changed.
    @discardableResult
    func update(_ tracks: [UUID: BeatTrack], owner: ObjectIdentifier) -> Bool {
        state.withLock { owners in
            guard owners[owner] != tracks else { return false }
            owners[owner] = tracks
            return true
        }
    }

    /// Forgets a closed project's tracks.
    func remove(owner: ObjectIdentifier) {
        state.withLock { _ = $0.removeValue(forKey: owner) }
    }
}
