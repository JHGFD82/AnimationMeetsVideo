import CoreMedia
import Foundation

extension ChangeScoreTrack {
    /// The time of the frame closest to `time`, so hand-placed cuts land on a
    /// real frame. Returns `time` unchanged when there are no frames.
    func nearestFrameTime(to time: CMTime) -> CMTime {
        guard !times.isEmpty else { return time }
        return self.time(at: index(nearestTo: time.convertScale(timescale, method: .default).value))
    }
}

extension ChangeScoreTrack {
    /// Snaps a time in the original's time to a real frame of the file the
    /// track describes: the file time is `time` plus the offset, the nearest
    /// frame is found among the track's actual timestamps (not a frame
    /// grid), and the result is brought back into original time. With an
    /// `interval` (original time) the result stays strictly inside it: the
    /// nearest frame that is; and `time` is returned unchanged if none is,
    /// or if it was not inside to begin with.
    func nearestFrameTime(
        toOriginal time: CMTime, mapping: OriginalTimeMapping, within interval: CMTimeRange? = nil
    ) -> CMTime {
        guard !times.isEmpty else { return time }
        func isInside(_ candidate: CMTime) -> Bool {
            guard let interval else { return true }
            return CMTimeCompare(candidate, interval.start) > 0 && CMTimeCompare(candidate, interval.end) < 0
        }
        guard isInside(time) else { return time }
        let nearest = index(nearestTo: mapping.file(fromOriginal: time).convertScale(timescale, method: .default).value)
        var best: (index: Int, distance: Double)?
        for candidate in max(nearest - 2, 0)...min(nearest + 2, times.count - 1) {
            let original = mapping.original(fromFile: self.time(at: candidate))
            guard isInside(original) else { continue }
            let distance = abs(CMTimeSubtract(original, time).seconds)
            if best == nil || distance < best!.distance { best = (candidate, distance) }
        }
        guard let best else { return time }
        return mapping.original(fromFile: self.time(at: best.index))
    }
}

extension SceneEdits {
    /// Adds a cut by hand. If it lands on an automatic cut that was ignored,
    /// that cut simply comes back.
    mutating func addCut(at time: CMTime) {
        if let index = ignoredCuts.firstIndex(where: { CMTimeCompare($0, time) == 0 }) {
            ignoredCuts.remove(at: index)
        } else if !manualCuts.contains(where: { CMTimeCompare($0, time) == 0 }) {
            manualCuts.append(time)
        }
    }

    /// Removes a cut, joining the scene it starts to the one before. A manual
    /// cut is deleted; an automatic one is remembered as ignored so it
    /// doesn't return when the sensitivity changes.
    mutating func removeCut(_ cut: SceneCut) {
        switch cut.origin {
        case .manual:
            manualCuts.removeAll { CMTimeCompare($0, cut.time) == 0 }
        case .auto:
            if !ignoredCuts.contains(where: { CMTimeCompare($0, cut.time) == 0 }) {
                ignoredCuts.append(cut.time)
            }
        }
    }

    mutating func moveCut(_ cut: SceneCut, to time: CMTime) {
        removeCut(cut)
        addCut(at: time)
    }

    /// Sets the sensitivity for the stretch between `start` and `end`, the
    /// span of the selected scenes. The cuts at the two edges are untouched.
    /// Because the person is deliberately re-deciding this stretch, cuts they
    /// ignored inside it become available again; cuts they placed by hand stay.
    mutating func applySensitivity(_ value: Double, from start: CMTime, to end: CMTime) {
        regions.removeAll { region in
            CMTimeCompare(region.start, start) >= 0 && CMTimeCompare(region.end, end) <= 0
        }
        regions.append(SensitivityRegion(start: start, end: end, value: value.clamped(between: 0, and: 1)))
        ignoredCuts.removeAll { CMTimeCompare($0, start) > 0 && CMTimeCompare($0, end) < 0 }
    }
}

extension EditingProject {
    /// The scenes of an asset: detected cuts with the person's edits applied.
    /// An asset that hasn't been analyzed yet is a single scene.
    func scenes(ofAsset assetID: UUID, track: ChangeScoreTrack?) -> [SceneRange] {
        sceneCoverage(ofAsset: assetID, track: track)?.scenes ?? []
    }

    /// The scenes of an asset in original time, and which stretches of
    /// original time its file can and cannot play. The scores are in the
    /// file's time, so detected cuts are moved into original time by the
    /// asset's alignment offset; scenes are made only where the original's
    /// domain and the file's footage overlap, and what falls outside is
    /// reported, not filled in. Nil for an unknown asset.
    func sceneCoverage(ofAsset assetID: UUID, track: ChangeScoreTrack?) -> SceneCoverage? {
        guard let clip = mediaClip(id: assetID) else { return nil }
        let mapping = clip.timeMapping
        let cuts = SceneDetector.cuts(in: track, defaultSensitivity: defaultSensitivity, edits: clip.sceneEdits, mapping: mapping)
        // The file's footage: its whole length except the empty stretches its
        // edit list leaves (the scores know them), which are never playable.
        let footage = SceneDomain.footage(duration: clip.duration, emptySpans: track?.emptySpans ?? [], timescale: track?.timescale ?? 1)
            .map(mapping.original(fromFile:))
        let usable = footage.compactMap { SceneDomain.intersection($0, start: .zero, end: clip.originalDomainEnd) }
        return SceneCoverage(
            scenes: SceneDetector.scenes(from: cuts, over: usable),
            usable: usable,
            uncovered: SceneDomain.uncovered(domainEnd: clip.originalDomainEnd, usable: usable)
        )
    }

    mutating func editScenes(ofAsset assetID: UUID, _ change: (inout SceneEdits) -> Void) {
        guard let index = clips.firstIndex(where: { $0.id == assetID }) else { return }
        change(&clips[index].sceneEdits)
    }

    /// Puts scenes of one asset on the timeline as ordinary clips, back to
    /// back on one new layer; see `addPieces(_:intoTimeline:at:kind:)`.
    @discardableResult
    mutating func addScenes(
        _ scenes: [SceneRange],
        ofAsset assetID: UUID,
        intoTimeline timelineID: UUID,
        at start: CMTime = .zero,
        kind: LayerKind? = nil
    ) -> (layerID: UUID, clipIDs: [UUID])? {
        addPieces(scenes.pieces(ofAsset: assetID), intoTimeline: timelineID, at: start, kind: kind)
    }

    /// Puts scenes of one asset on an existing layer; see
    /// `addPieces(_:intoLayer:in:at:)`.
    @discardableResult
    mutating func addScenes(
        _ scenes: [SceneRange],
        ofAsset assetID: UUID,
        intoLayer layerID: UUID,
        in timelineID: UUID,
        at start: CMTime
    ) -> [UUID]? {
        addPieces(scenes.pieces(ofAsset: assetID), intoLayer: layerID, in: timelineID, at: start)
    }
}

extension Array where Element == SceneRange {
    func pieces(ofAsset assetID: UUID) -> [MediaPiece] {
        map { MediaPiece(assetID: assetID, start: $0.start, end: $0.end) }
    }

    /// The time covered from the earliest start to the latest end, or nil when empty.
    var span: (start: CMTime, end: CMTime)? {
        guard let first else { return nil }
        var start = first.start, end = first.end
        for scene in self {
            if CMTimeCompare(scene.start, start) < 0 { start = scene.start }
            if CMTimeCompare(scene.end, end) > 0 { end = scene.end }
        }
        return (start, end)
    }
}

extension EditingProject {
    /// The scenes that would exist if `change` were applied to the asset's
    /// edits, limited to `span` when given, without changing the project.
    /// Drives the live preview while a slider moves.
    func scenesPreviewing(
        ofAsset assetID: UUID,
        track: ChangeScoreTrack?,
        applying change: (inout SceneEdits) -> Void,
        within span: (start: CMTime, end: CMTime)? = nil
    ) -> [SceneRange] {
        var preview = self
        preview.editScenes(ofAsset: assetID, change)
        let scenes = preview.scenes(ofAsset: assetID, track: track)
        guard let span else { return scenes }
        return scenes.filter { CMTimeCompare($0.start, span.start) >= 0 && CMTimeCompare($0.end, span.end) <= 0 }
    }
}
