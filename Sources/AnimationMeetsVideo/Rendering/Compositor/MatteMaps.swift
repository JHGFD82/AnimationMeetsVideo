import AVFoundation
import CoreImage
import Foundation
import os

/// The matte wipe maps one composition was built with, by asset ID: its
/// instructions draw with these, whatever a later build loads.
/// CIImage is immutable, so it is shared across the compositor's queues.
struct MatteMapSet: @unchecked Sendable {
    var images: [UUID: CIImage] = [:]
    /// What each was loaded from, for the render key.
    var stamps: [UUID: String] = [:]
}

/// Loads the frames matte wipes read their map from while a composition
/// is built: `LayeredCompositor` draws each frame synchronously and can't
/// wait for a file. A map is the first frame of a video in the project.
/// This is a cache of the latest version read of each map, so a build
/// doesn't decode a file again; each build keeps its own `MatteMapSet`,
/// so a later build reading another version doesn't change what an
/// earlier composition draws.
final class MatteMaps: @unchecked Sendable {
    static let shared = MatteMaps()

    private struct Entry {
        var stamp: String
        var image: CIImage
    }

    private let entries = OSAllocatedUnfairLock<[UUID: Entry]>(uncheckedState: [:])

    /// The map of every video a matte wipe in `project` reads, decoding
    /// those not cached yet or whose file has changed. One that can't be
    /// read is left out, and its wipes use noise instead.
    func load(for project: EditingProject) async -> MatteMapSet {
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
        var loaded = MatteMapSet()
        for id in wanted {
            guard let url = project.clips.first(id: id)?.url else { continue }
            let stamp = FileStamp(url: url).map { "\(url.path) \($0.byteCount) \($0.modified ?? 0)" } ?? url.path
            if let kept = entries.withLockUnchecked({ $0[id] }), kept.stamp == stamp {
                loaded.images[id] = kept.image
                loaded.stamps[id] = stamp
                continue
            }
            let generator = AVAssetImageGenerator(asset: MediaFile.asset(at: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1920)
            generator.requestedTimeToleranceAfter = .positiveInfinity
            guard let frame = try? await generator.image(at: .zero).image else { continue }
            let image = CIImage(cgImage: frame, options: [.colorSpace: NSNull()])
            entries.withLockUnchecked { $0[id] = Entry(stamp: stamp, image: image) }
            loaded.images[id] = image
            loaded.stamps[id] = stamp
        }
        return loaded
    }
}
