import AVFoundation
import CoreImage
import Foundation
import os

/// The frames matte wipes read their map from, loaded while a composition
/// is built: `LayeredCompositor` draws each frame synchronously and can't
/// wait for a file. A map is the first frame of a video in the project,
/// kept until its file changes.
final class MatteMaps: @unchecked Sendable {
    static let shared = MatteMaps()

    private struct Entry {
        var stamp: String
        var image: CIImage
    }

    private let entries = OSAllocatedUnfairLock<[UUID: Entry]>(uncheckedState: [:])

    /// The map for the video `clipID`, if it has been loaded.
    func image(for clipID: UUID) -> CIImage? {
        entries.withLockUnchecked { $0[clipID]?.image }
    }

    /// What the map for `clipID` was loaded from, for the render cache's
    /// key: a changed file changes it.
    func stamp(for clipID: UUID) -> String? {
        entries.withLockUnchecked { $0[clipID]?.stamp }
    }

    /// Sets a map directly, as a test does.
    func store(_ image: CIImage, for clipID: UUID) {
        entries.withLockUnchecked { $0[clipID] = Entry(stamp: "", image: image) }
    }

    /// Loads the map of every video a matte wipe in `project` reads that
    /// isn't loaded yet or whose file has changed. One that can't be read
    /// is left out, and its wipes use noise instead.
    func load(for project: EditingProject) async {
        var wanted: Set<UUID> = []
        for timeline in project.timelines {
            for layer in timeline.layers {
                for clip in layer.clips {
                    for transition in [clip.transitionIn, clip.transitionOut].compactMap({ $0 }) {
                        if transition.kind == .matteWipe, case .clip(let id) = transition.options.matte {
                            wanted.insert(id)
                        }
                    }
                }
            }
        }
        for id in wanted {
            guard let url = project.clips.first(id: id)?.url else { continue }
            let stamp = FileStamp(url: url).map { "\(url.path) \($0.byteCount) \($0.modified ?? 0)" } ?? url.path
            if entries.withLockUnchecked({ $0[id]?.stamp == stamp }) { continue }
            let generator = AVAssetImageGenerator(asset: MediaFile.asset(at: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1920)
            generator.requestedTimeToleranceAfter = .positiveInfinity
            guard let frame = try? await generator.image(at: .zero).image else { continue }
            let image = CIImage(cgImage: frame, options: [.colorSpace: NSNull()])
            entries.withLockUnchecked { $0[id] = Entry(stamp: stamp, image: image) }
        }
    }
}
