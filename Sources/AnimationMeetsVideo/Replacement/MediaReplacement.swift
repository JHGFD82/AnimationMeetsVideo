import CoreMedia
import Foundation

extension EditingProject {
    /// The parts of an asset's original time that clips in any timeline use.
    func usedRanges(ofMedia assetID: UUID) -> [CMTimeRange] {
        var ranges: [CMTimeRange] = []
        for timeline in timelines {
            for layer in timeline.layers {
                for clip in layer.clips where clip.source == .media(assetID) {
                    let range = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
                    if range.isValid, range.duration > .zero { ranges.append(range) }
                }
            }
        }
        return ranges + usedInputRanges(ofMedia: assetID)
    }

    /// Points an asset at a different file. Clips, scenes and trims refer to
    /// the asset, so nothing else changes; `offset` says where original time
    /// falls in the new file. The old path is remembered, but no file is
    /// copied or deleted.
    mutating func replaceMedia(id assetID: UUID, with replacement: MediaClip, offset: CMTime) {
        guard let index = clips.firstIndex(where: { $0.id == assetID }), let newURL = replacement.url else { return }
        if let oldURL = clips[index].url, oldURL.path != newURL.path {
            let old = oldURL.path
            clips[index].previousPaths.removeAll { $0 == old }
            clips[index].previousPaths.append(old)
        }
        // Pointing back at an earlier file takes it off the list of earlier files.
        clips[index].previousPaths.removeAll { $0 == newURL.path }

        clips[index].url = newURL
        clips[index].kind = replacement.kind
        clips[index].duration = replacement.duration
        clips[index].frameRate = replacement.frameRate
        clips[index].colorSpace = replacement.colorSpace
        clips[index].codecName = replacement.codecName
        clips[index].hasAudio = replacement.hasAudio
        clips[index].acceptedStamp = replacement.acceptedStamp
        clips[index].alignmentOffset = offset
    }

    /// Records that the original was forgotten. The reference data itself is
    /// deleted when the project is next saved, so this can be undone until then.
    mutating func markReferenceForgotten(forAsset assetID: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == assetID }) else { return }
        clips[index].referenceForgotten = true
    }

    /// Changes only the alignment, for when the person re-syncs the file
    /// already in place.
    mutating func setAlignmentOffset(_ offset: CMTime, forAsset assetID: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == assetID }) else { return }
        clips[index].alignmentOffset = offset
    }
}

/// Matches files in a folder to assets by name, for replacing many at once.
enum BulkReplacementMatcher {
    struct Match: Equatable {
        var assetID: UUID
        var url: URL
    }

    /// For each asset, the file in `candidates` with its name: the current
    /// file name or the original's, ignoring case. When none matches exactly,
    /// a single file with the same name apart from the extension is accepted,
    /// since a stand-in is often a different container. A name that more than
    /// one file could match is left out rather than guessed.
    static func matches(
        for assets: [(id: UUID, fileNames: [String])],
        among candidates: [URL]
    ) -> [Match] {
        var byName: [String: [URL]] = [:]
        var byBase: [String: [URL]] = [:]
        for url in candidates {
            byName[url.lastPathComponent.lowercased(), default: []].append(url)
            byBase[url.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(url)
        }

        var matches: [Match] = []
        var claimed: Set<URL> = []
        for asset in assets {
            var found: URL?
            var ambiguous = false
            for name in asset.fileNames {
                let exact = byName[name.lowercased()] ?? []
                if exact.count == 1 { found = exact[0]; break }
                if exact.count > 1 { ambiguous = true; break }
            }
            if found == nil, !ambiguous {
                for name in asset.fileNames {
                    let base = (name as NSString).deletingPathExtension.lowercased()
                    let similar = byBase[base] ?? []
                    if similar.count == 1 { found = similar[0]; break }
                    if similar.count > 1 { break }
                }
            }
            if let found, claimed.insert(found).inserted {
                matches.append(Match(assetID: asset.id, url: found))
            }
        }
        return matches
    }
}
