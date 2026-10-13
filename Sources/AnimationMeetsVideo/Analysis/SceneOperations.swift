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
        regions.append(SensitivityRegion(start: start, end: end, value: min(max(value, 0), 1)))
        ignoredCuts.removeAll { CMTimeCompare($0, start) > 0 && CMTimeCompare($0, end) < 0 }
    }
}

extension EditingProject {
    /// The scenes of an asset: detected cuts with the person's edits applied.
    /// An asset that hasn't been analyzed yet is a single scene.
    func scenes(ofAsset assetID: UUID, track: ChangeScoreTrack?) -> [SceneRange] {
        guard let clip = mediaClip(id: assetID) else { return [] }
        let cuts = SceneDetector.cuts(in: track, defaultSensitivity: defaultSensitivity, edits: clip.sceneEdits)
        return SceneDetector.scenes(from: cuts, duration: clip.duration)
    }

    mutating func editScenes(ofAsset assetID: UUID, _ change: (inout SceneEdits) -> Void) {
        guard let index = clips.firstIndex(where: { $0.id == assetID }) else { return }
        change(&clips[index].sceneEdits)
    }

    /// Puts scenes on the timeline as ordinary clips, back to back with no
    /// gaps in the order given, on one new layer at the top. The media is not
    /// touched; each clip is the asset trimmed to the scene's range.
    @discardableResult
    mutating func addScenes(_ scenes: [SceneRange], ofAsset assetID: UUID, intoTimeline timelineID: UUID) -> (layerID: UUID, clipIDs: [UUID])? {
        guard !scenes.isEmpty, mediaClip(id: assetID) != nil,
              let index = timelines.firstIndex(where: { $0.id == timelineID })
        else { return nil }

        var offset = CMTime.zero
        var added: [TimelineClip] = []
        for scene in scenes {
            let clip = TimelineClip(source: .media(assetID), startOffset: offset, trimStart: scene.start, trimEnd: scene.end)
            added.append(clip)
            offset = clip.endOffset
        }
        let layer = TimelineLayer(customName: nil, clips: added)
        timelines[index].layers.insert(layer, at: 0)
        return (layer.id, added.map(\.id))
    }
}

extension Array where Element == SceneRange {
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
