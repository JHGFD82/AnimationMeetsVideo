import Foundation
import os

/// The beats analysis has detected in each file, mirrored from
/// `AssetAnalysis` for the model to read while it makes Beat Keys'
/// keyframes (see docs/keyframing-effects.md), which isn't on the main
/// actor. The editor keeps it current.
final class DetectedBeats: Sendable {
    static let shared = DetectedBeats()

    private let state = OSAllocatedUnfairLock(initialState: [UUID: BeatTrack]())

    /// Beat tracks by asset.
    var tracks: [UUID: BeatTrack] { state.withLock { $0 } }

    /// Takes the analysis's tracks; returns whether they changed.
    @discardableResult
    func update(_ tracks: [UUID: BeatTrack]) -> Bool {
        state.withLock { current in
            guard current != tracks else { return false }
            current = tracks
            return true
        }
    }
}
