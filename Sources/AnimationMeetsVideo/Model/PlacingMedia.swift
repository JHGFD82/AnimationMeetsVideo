import CoreMedia
import Foundation

/// A stretch of one asset to put on a timeline, in the asset's original
/// time: a whole clip, a scene, or a range picked in the browser.
struct MediaPiece: Equatable, Sendable {
    var assetID: UUID
    var start: CMTime
    var end: CMTime
}

extension TimelineClip {
    /// The stretch of its asset the clip plays, which Show in Clips Browser
    /// picks there; nil for clips that aren't of media.
    var footagePiece: MediaPiece? {
        guard case .media(let assetID) = source else { return nil }
        return MediaPiece(assetID: assetID, start: trimStart, end: trimEnd)
    }
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
    /// picked together land as one run across two layers. With
    /// `mutingSound`, video clips come with their sound muted (see
    /// `TimelineClip.soundMuted`). Returns the layer of the first piece and
    /// every new clip's ID, in the pieces' order; nil for an unknown asset
    /// or timeline.
    @discardableResult
    mutating func addPieces(
        _ pieces: [MediaPiece],
        intoTimeline timelineID: UUID,
        at start: CMTime = .zero,
        kind: LayerKind? = nil,
        mutingSound: Bool = false
    ) -> (layerID: UUID, clipIDs: [UUID])? {
        guard !pieces.isEmpty, pieces.allSatisfy({ mediaClip(id: $0.assetID) != nil }),
              let index = timelines.firstIndex(id: timelineID)
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
            if mutingSound, hasLinkedAudio(clip) { clip.soundMuted = true }
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

    /// Puts pieces on an existing layer, back to back, landing as a clip
    /// moved there would (`insertion(lasting:...)`): dropped inside a clip
    /// they go to its nearer edge, and the clips from there on move right
    /// just far enough to make room. Nothing is added unless the layer is
    /// the right kind for every piece; returns the new clips' IDs.
    /// `mutingSound` mutes video clips' sound, as for a new layer.
    @discardableResult
    mutating func addPieces(
        _ pieces: [MediaPiece],
        intoLayer layerID: UUID,
        in timelineID: UUID,
        at start: CMTime,
        mutingSound: Bool = false
    ) -> [UUID]? {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID),
              let (clips, move) = pieceInsertion(pieces, onLayer: layerID, in: timelineID, at: start, mutingSound: mutingSound)
        else { return nil }

        let timeline = timelines[tIndex]
        var layerClips = timeline.layers[lIndex].clips
        layerClips.makeRoom(for: move)
        var cursor = move.start
        for var clip in clips {
            clip.startOffset = timeline.placementTime(cursor, .nearest, frameLocked: isFrameLocked(clip))
            layerClips.append(clip)
            cursor = clip.endOffset
        }
        timelines[tIndex].layers[lIndex].clips = layerClips.sorted { $0.startOffset < $1.startOffset }
        return clips.map(\.id)
    }

    /// The clips pieces would make on a layer (not yet placed), and where
    /// the run of them lands and what moves aside; nil for an unknown asset,
    /// timeline or layer, or a layer of the wrong kind for any piece.
    func pieceInsertion(
        _ pieces: [MediaPiece], onLayer layerID: UUID, in timelineID: UUID, at start: CMTime, mutingSound: Bool = false
    ) -> ([TimelineClip], ClipMove)? {
        guard !pieces.isEmpty, pieces.allSatisfy({ mediaClip(id: $0.assetID) != nil }),
              let timeline = timeline(id: timelineID), let layer = timeline.layer(id: layerID)
        else { return nil }
        var clips: [TimelineClip] = []
        var length = CMTime.zero
        for piece in pieces {
            var clip = coveringWholeFrames(
                TimelineClip(source: .media(piece.assetID), startOffset: .zero, trimStart: piece.start, trimEnd: piece.end),
                in: timeline
            )
            if mutingSound, hasLinkedAudio(clip) { clip.soundMuted = true }
            guard self.layer(layer, accepts: clip) else { return nil }
            clips.append(clip)
            length = CMTimeAdd(length, clip.placedDuration)
        }
        let move = insertion(lasting: length, frameLocked: clips.contains(where: isFrameLocked), among: layer.clips, in: timeline, at: start)
        return (clips, move)
    }

    /// The clips of a layer moving right for pieces dropped there: where
    /// each is and where it would go. Empty where nothing moves.
    func pushedByPieces(_ pieces: [MediaPiece], onLayer layerID: UUID, in timelineID: UUID, at start: CMTime) -> [UUID: PushedClip] {
        guard let (_, move) = pieceInsertion(pieces, onLayer: layerID, in: timelineID, at: start), move.push > .zero,
              let layer = timeline(id: timelineID)?.layer(id: layerID)
        else { return [:] }
        var pushed: [UUID: PushedClip] = [:]
        for clip in layer.clips where clip.startOffset >= move.pushFrom {
            pushed[clip.id] = PushedClip(from: clip.startOffset, to: CMTimeAdd(clip.startOffset, move.push))
        }
        return pushed
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
