import CoreMedia
import Foundation

/// A stretch of one asset to put on a timeline, in the asset's original
/// time: a whole clip, a scene, or a range picked in the browser.
struct MediaPiece: Equatable, Sendable {
    var assetID: UUID
    var start: CMTime
    var end: CMTime
}

extension EditingProject {
    /// Puts pieces on the timeline as ordinary clips, back to back with no
    /// gaps in the order given, from `start`. The media is not touched; each
    /// clip is its asset trimmed to the piece.
    ///
    /// They go on one new layer at the top of its area. With `kind` (a drop
    /// on an area) every piece must suit that kind, or nothing is added.
    /// Without, each piece goes on a new layer of its asset's default kind,
    /// one layer per kind, keeping its time in the run, so video and sound
    /// picked together land as one run across two layers. Returns the layer
    /// of the first piece and every new clip's ID, in the pieces' order; nil
    /// for an unknown asset or timeline.
    @discardableResult
    mutating func addPieces(
        _ pieces: [MediaPiece],
        intoTimeline timelineID: UUID,
        at start: CMTime = .zero,
        kind: LayerKind? = nil
    ) -> (layerID: UUID, clipIDs: [UUID])? {
        guard !pieces.isEmpty, pieces.allSatisfy({ mediaClip(id: $0.assetID) != nil }),
              let index = timelines.firstIndex(where: { $0.id == timelineID })
        else { return nil }

        let timeline = timelines[index]
        var offset = start
        var layers: [TimelineLayer] = []
        var clipIDs: [UUID] = []
        for piece in pieces {
            var clip = coveringWholeFrames(
                TimelineClip(source: .media(piece.assetID), startOffset: .zero, trimStart: piece.start, trimEnd: piece.end),
                in: timeline
            )
            clip.startOffset = timeline.placementTime(CMTimeMaximum(.zero, offset), .nearest, frameLocked: isFrameLocked(clip))
            let pieceKind = kind ?? defaultLayerKind(forAsset: piece.assetID)
            guard layerKind(pieceKind, accepts: clip) else { return nil }
            if let layer = layers.firstIndex(where: { $0.kind == pieceKind }) {
                layers[layer].clips.append(clip)
            } else {
                layers.append(TimelineLayer(customName: nil, kind: pieceKind, clips: [clip]))
            }
            clipIDs.append(clip.id)
            offset = clip.endOffset
        }
        // Each new layer goes at the top; the first piece's ends up first.
        for layer in layers.reversed() {
            timelines[index].layers.insert(layer, at: 0)
        }
        return (layers[0].id, clipIDs)
    }

    /// Puts pieces on an existing layer, back to back from near `start`,
    /// each moved to the nearest gap it fits in. Nothing is added unless
    /// every piece fits and the layer is the right kind for all of them;
    /// returns the new clips' IDs.
    @discardableResult
    mutating func addPieces(
        _ pieces: [MediaPiece],
        intoLayer layerID: UUID,
        in timelineID: UUID,
        at start: CMTime
    ) -> [UUID]? {
        guard !pieces.isEmpty, pieces.allSatisfy({ mediaClip(id: $0.assetID) != nil }),
              let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else { return nil }

        let timeline = timelines[tIndex]
        var clips = timeline.layers[lIndex].clips
        var cursor = CMTimeMaximum(.zero, start)
        var added: [UUID] = []
        for piece in pieces {
            var clip = coveringWholeFrames(
                TimelineClip(source: .media(piece.assetID), startOffset: .zero, trimStart: piece.start, trimEnd: piece.end),
                in: timeline
            )
            guard layer(timeline.layers[lIndex], accepts: clip),
                  let placed = freeStart(for: clip, among: clips, in: timeline, near: cursor)
            else { return nil }
            clip.startOffset = placed
            clips.append(clip)
            added.append(clip.id)
            cursor = clip.endOffset
        }
        timelines[tIndex].layers[lIndex].clips = clips.sorted { $0.startOffset < $1.startOffset }
        return added
    }
}

extension EditingProject {
    /// The clips `addPieces(_:intoLayer:in:at:)` would make, where they
    /// would land, without changing the project; nil where it would refuse.
    /// Drawn on a layer while media is dragged over it.
    func landing(of pieces: [MediaPiece], onLayer layerID: UUID, in timelineID: UUID, at start: CMTime) -> [TimelineClip]? {
        var copy = self
        guard let ids = copy.addPieces(pieces, intoLayer: layerID, in: timelineID, at: start),
              let layer = copy.timeline(id: timelineID)?.layer(id: layerID)
        else { return nil }
        let added = Set(ids)
        return layer.clips.filter { added.contains($0.id) }
    }
}
