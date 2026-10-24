import CoreMedia
import Foundation

// Timeline clips follow the scenes they were cut from: splitting a scene
// in the browser splits the clips that play across the new cut, and
// merging scenes joins clips that meet at the cut taken away. See
// docs/scene-cuts.md, "Clips follow their scenes".

/// The cuts an edit of an asset's scenes added and took away, in the
/// asset's original time.
struct SceneCutChange: Equatable {
    var added: [CMTime] = []
    var removed: [CMTime] = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    /// The scene starts in `new` but not `old` are added cuts, and those in
    /// `old` but not `new` removed ones. The start of a stretch of footage
    /// is a scene start in both, so it is never taken for a cut.
    init(from old: [SceneRange], to new: [SceneRange]) {
        let before = old.map(\.start), after = new.map(\.start)
        added = after.filter { time in !before.contains { CMTimeCompare($0, time) == 0 } }
        removed = before.filter { time in !after.contains { CMTimeCompare($0, time) == 0 } }
    }

    init(added: [CMTime] = [], removed: [CMTime] = []) {
        self.added = added
        self.removed = removed
    }
}

/// Where a timeline clip is.
struct ClipLocation: Hashable {
    var timelineID: UUID
    var layerID: UUID
    var clipID: UUID
}

/// What following a scene edit did to the timelines.
struct SceneFollowResult: Equatable {
    /// Clips split in two (or more) at the new cuts.
    var split: [ClipLocation] = []
    /// Clips whose animation ran across a new cut, put into a timeline of
    /// their own and split there; the clip keeps its place and its
    /// animation, and now plays that timeline.
    var embedded: [ClipLocation] = []
    /// Pairs of clips joined into one where a cut was taken away.
    var joined: Int = 0
    /// Pairs of clips that met at a cut taken away but stayed two: a
    /// transition between them, different effects, speeds or settings.
    var keptApart: Int = 0
}

extension EditingProject {
    /// Changes an asset's scene edits and brings the timelines along (see
    /// `followSceneCuts(_:ofAsset:)`), as one edit.
    @discardableResult
    mutating func editScenesFollowingClips(
        ofAsset assetID: UUID, track: ChangeScoreTrack?, _ change: (inout SceneEdits) -> Void
    ) -> SceneFollowResult {
        let before = scenes(ofAsset: assetID, track: track)
        editScenes(ofAsset: assetID, change)
        let after = scenes(ofAsset: assetID, track: track)
        return followSceneCuts(SceneCutChange(from: before, to: after), ofAsset: assetID)
    }

    /// The cuts an edit would add and take away, without making it.
    func sceneCutChange(ofAsset assetID: UUID, track: ChangeScoreTrack?, applying change: (inout SceneEdits) -> Void) -> SceneCutChange {
        var copy = self
        let before = copy.scenes(ofAsset: assetID, track: track)
        copy.editScenes(ofAsset: assetID, change)
        return SceneCutChange(from: before, to: copy.scenes(ofAsset: assetID, track: track))
    }

    /// Whether any clip showing the asset's picture has keyframes at all,
    /// so that a new cut might embed one. Cheap, unlike finding the cuts.
    func hasAnimatedClips(ofAsset assetID: UUID) -> Bool {
        timelines.contains { timeline in
            timeline.layers.contains { layer in
                layer.clips.contains { follows($0, assetID) && !$0.animatedRanges.isEmpty }
            }
        }
    }

    /// The clips of the asset whose keyframes run across one of `cuts`, so
    /// that following them would put the clip into a timeline of its own
    /// rather than split it; see `followSceneCuts(_:ofAsset:)`.
    func clipsAnimated(across cuts: [CMTime], ofAsset assetID: UUID) -> [ClipLocation] {
        var found: [ClipLocation] = []
        for timeline in timelines {
            for layer in timeline.layers {
                for clip in layer.clips where follows(clip, assetID) {
                    if cuts.contains(where: { clip.plays($0) && clip.isAnimated(across: $0) }) {
                        found.append(ClipLocation(timelineID: timeline.id, layerID: layer.id, clipID: clip.id))
                    }
                }
            }
        }
        return found
    }

    /// Brings the clips cut from an asset in line with a change to its
    /// cuts, in every timeline. Only clips that show the asset's picture
    /// follow (sound taken off on its own is left whole).
    ///
    /// - A clip that plays across an added cut is split there, as the
    ///   blade splits it: nothing about how it plays changes. If any of its
    ///   keyframes are on both sides of the cut, it is instead put into a
    ///   new timeline, split there, and the clip plays that timeline with
    ///   all its effects and keyframes, which stay one animation.
    /// - Two clips that meet at a removed cut, the first ending where the
    ///   second starts in the footage and on the layer, are joined into
    ///   one. Their keyframes are joined; where a value differs on the two
    ///   sides, the first holds its value up to its last frame and the
    ///   second's value starts at the cut, so the joined clip plays as the
    ///   two did. Clips with a transition between them, or different
    ///   effects, speeds or settings, stay apart.
    @discardableResult
    mutating func followSceneCuts(_ change: SceneCutChange, ofAsset assetID: UUID) -> SceneFollowResult {
        var result = SceneFollowResult()
        guard !change.isEmpty else { return result }
        let frame = mediaClip(id: assetID).map(Self.sourceFrame(of:)) ?? CMTime(value: 1, timescale: 30)
        let removed = change.removed.sorted { CMTimeCompare($0, $1) < 0 }
        let added = change.added.sorted { CMTimeCompare($0, $1) < 0 }
        var newTimelines: [Timeline] = []
        for t in timelines.indices {
            for l in timelines[t].layers.indices {
                for cut in removed {
                    join(atCut: cut, ofAsset: assetID, timeline: t, layer: l, frame: frame, into: &result)
                }
                guard !added.isEmpty else { continue }
                let host = timelines[t]
                let layer = host.layers[l]
                var clips: [TimelineClip] = []
                for clip in layer.clips {
                    let cuts = follows(clip, assetID) ? added.filter(clip.plays) : []
                    guard !cuts.isEmpty else {
                        clips.append(clip)
                        continue
                    }
                    let location = ClipLocation(timelineID: host.id, layerID: layer.id, clipID: clip.id)
                    if cuts.contains(where: clip.isAnimated(across:)) {
                        let name = "\(mediaClip(id: assetID)?.name ?? "Clip") Scenes"
                        let (outer, nested) = Self.embedding(clip, splitAt: cuts, named: name, kind: layer.kind, like: host)
                        newTimelines.append(nested)
                        clips.append(outer)
                        result.embedded.append(location)
                    } else {
                        clips += clip.pieces(splitAt: cuts)
                        result.split.append(location)
                    }
                }
                timelines[t].layers[l].clips = clips
            }
        }
        timelines += newTimelines
        return result
    }

    /// Whether a clip follows the asset's scenes: it plays the asset's
    /// picture.
    private func follows(_ clip: TimelineClip, _ assetID: UUID) -> Bool {
        guard case .media(let id) = clip.source, id == assetID else { return false }
        return clip.streams != .audio
    }

    /// How long a frame of the asset lasts in its own time.
    private static func sourceFrame(of media: MediaClip) -> CMTime {
        let rate = media.frameRate > 0 ? media.frameRate : 30
        return CMTime(value: 1_000_000, timescale: Int32((rate * 1_000_000).rounded()))
    }

    // MARK: Splitting

    /// The clip put into a new timeline of its own, `like` the one it is
    /// in, split there at `cuts` with none of its effects, keyframes,
    /// speed or transitions: those stay on the clip, which keeps its ID and
    /// place and now plays the new timeline. Its keyframes move from the
    /// footage's time into the new timeline's, which starts where its trim
    /// did.
    static func embedding(
        _ clip: TimelineClip, splitAt cuts: [CMTime], named name: String, kind: LayerKind, like host: Timeline
    ) -> (outer: TimelineClip, nested: Timeline) {
        var inner = TimelineClip(source: clip.source, startOffset: .zero, trimStart: clip.trimStart, trimEnd: clip.trimEnd)
        inner.streams = clip.streams
        inner.soundMuted = clip.soundMuted
        inner.autoMatteEnabled = clip.autoMatteEnabled
        let nested = Timeline(
            name: name,
            layers: [TimelineLayer(customName: nil, kind: kind, clips: inner.pieces(splitAt: cuts))],
            frameSize: host.frameSize, frameRate: host.frameRate, colorSpace: host.colorSpace
        )
        var outer = clip
        outer.source = .timeline(nested.id)
        outer.trimStart = .zero
        outer.trimEnd = clip.trimmedDuration
        outer.streams = .videoAndAudio
        outer.soundMuted = false
        outer.autoMatteEnabled = false
        outer.shiftKeyframes(by: CMTimeMultiply(clip.trimStart, multiplier: -1))
        return (outer, nested)
    }

    // MARK: Joining

    /// Joins the clips on one layer that meet at `cut`, where it was taken
    /// away; see `followSceneCuts(_:ofAsset:)`.
    private mutating func join(
        atCut cut: CMTime, ofAsset assetID: UUID, timeline t: Int, layer l: Int, frame: CMTime, into result: inout SceneFollowResult
    ) {
        var clips = timelines[t].layers[l].clips.sorted { $0.startOffset < $1.startOffset }
        var index = 0
        while index + 1 < clips.count {
            let first = clips[index], second = clips[index + 1]
            guard follows(first, assetID), follows(second, assetID), Self.meet(first, second, at: cut) else {
                index += 1
                continue
            }
            guard let joined = Self.joined(first, second, at: cut, frame: frame) else {
                result.keptApart += 1
                index += 1
                continue
            }
            clips.replaceSubrange(index...index + 1, with: [joined])
            result.joined += 1
        }
        // Keep the layer's own order where nothing was joined.
        if clips.count != timelines[t].layers[l].clips.count {
            timelines[t].layers[l].clips = clips
        }
    }

    /// Whether `second` carries on from `first` at `cut`: next to each
    /// other on the layer, and in the footage on either side of the cut.
    private static func meet(_ first: TimelineClip, _ second: TimelineClip, at cut: CMTime) -> Bool {
        guard first.isReversed == second.isReversed,
              CMTimeAbsoluteValue(CMTimeSubtract(second.startOffset, first.endOffset)) < Timeline.abutmentTolerance
        else { return false }
        if first.isReversed {
            return CMTimeCompare(first.trimStart, cut) == 0 && CMTimeCompare(second.trimEnd, cut) == 0
        }
        return CMTimeCompare(first.trimEnd, cut) == 0 && CMTimeCompare(second.trimStart, cut) == 0
    }

    /// The two clips as one, or nil when they differ in more than their
    /// keyframed values. `frame` is a frame of the footage, how long
    /// before the cut the first clip's value is held.
    static func joined(_ first: TimelineClip, _ second: TimelineClip, at cut: CMTime, frame: CMTime) -> TimelineClip? {
        guard first.transitionOut == nil, second.transitionIn == nil,
              first.streams == second.streams, first.enabled == second.enabled,
              first.soundMuted == second.soundMuted, first.autoMatteEnabled == second.autoMatteEnabled,
              first.passThrough == second.passThrough, first.reach == second.reach,
              first.time == second.time, first.shutter == second.shutter,
              first.followsMusic == second.followsMusic,
              sameShape(first.effects, second.effects), sameShape(first.audioEffects, second.audioEffects)
        else { return nil }
        var joined = first
        joined.transitionOut = second.transitionOut
        if first.isReversed {
            // Backwards, keyframes can't be told apart by side of the cut
            // the way holds need, so only clips animated alike join.
            guard first.anchorPoint == second.anchorPoint, first.volume == second.volume, first.pan == second.pan,
                  first.effects == second.effects, first.audioEffects == second.audioEffects
            else { return nil }
            joined.trimStart = second.trimStart
            return joined
        }
        joined.trimEnd = second.trimEnd
        let hold = CMTimeMaximum(first.trimStart, CMTimeSubtract(cut, frame))
        func join<V>(_ a: AnimatedValue<V>, _ b: AnimatedValue<V>) -> AnimatedValue<V> {
            a.joined(with: b, at: cut, holdingFrom: hold)
        }
        joined.anchorPoint = join(first.anchorPoint, second.anchorPoint)
        joined.volume = join(first.volume, second.volume)
        joined.pan = join(first.pan, second.pan)
        joined.effects = zip(first.effects, second.effects).map { a, b in
            var effect = a
            effect.controls = zip(a.controls, b.controls).map { x, y in
                var control = x
                control.number = join(x.number, y.number)
                return control
            }
            return effect
        }
        joined.audioEffects = zip(first.audioEffects, second.audioEffects).map { a, b in
            var effect = a
            effect.controls = zip(a.controls, b.controls).map { x, y in
                var control = x
                control.number = join(x.number, y.number)
                return control
            }
            return effect
        }
        return joined
    }

    /// Whether two stacks hold the same effects and controls in the same
    /// order (as the two halves of a split clip do), whatever their values.
    private static func sameShape(_ a: [Effect], _ b: [Effect]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.id == y.id && x.kind == y.kind && x.controls.map(\.id) == y.controls.map(\.id)
        }
    }
}

extension TimelineClip {
    /// Whether the clip plays the moment `time` of its source, other than
    /// at its very first or last.
    func plays(_ time: CMTime) -> Bool {
        CMTimeCompare(trimStart, time) < 0 && CMTimeCompare(time, trimEnd) < 0
    }

    /// Whether any of the clip's keyframed values has keyframes on both
    /// sides of `time` in its source.
    func isAnimated(across time: CMTime) -> Bool {
        animatedRanges.contains { CMTimeCompare($0.lowerBound, time) < 0 && CMTimeCompare(time, $0.upperBound) < 0 }
    }

    /// The first to last keyframe of every keyframed value on the clip.
    var animatedRanges: [ClosedRange<CMTime>] {
        var ranges = [anchorPoint.animatedRange, volume.animatedRange, pan.animatedRange, time.speed.animatedRange]
        for effect in effects + audioEffects {
            ranges += effect.controls.map(\.number.animatedRange)
        }
        return ranges.compactMap { $0 }
    }

    /// Moves every keyframe on the clip by `delta`.
    mutating func shiftKeyframes(by delta: CMTime) {
        anchorPoint = anchorPoint.shifted(by: delta)
        volume = volume.shifted(by: delta)
        pan = pan.shifted(by: delta)
        time.speed = time.speed.shifted(by: delta)
        for e in effects.indices {
            for c in effects[e].controls.indices {
                effects[e].controls[c].number = effects[e].controls[c].number.shifted(by: delta)
            }
        }
        for e in audioEffects.indices {
            for c in audioEffects[e].controls.indices {
                audioEffects[e].controls[c].number = audioEffects[e].controls[c].number.shifted(by: delta)
            }
        }
    }

    /// The clip split at each of `cuts` it plays, as the blade splits it.
    func pieces(splitAt cuts: [CMTime]) -> [TimelineClip] {
        var pieces = [self]
        for cut in cuts.sorted(by: { CMTimeCompare($0, $1) < 0 }) {
            guard let piece = pieces.first(where: { $0.plays(cut) }) else { continue }
            pieces.splitClip(piece.id, at: cut)
        }
        return pieces
    }
}

extension AnimatedValue {
    /// This value, which applies up to `cut` in the source, followed by
    /// `next`, which applies from it. Alike, it stays as it is. Otherwise
    /// this one's keyframes before `hold` are kept with a hold keyframe at
    /// `hold` (the last frame before the cut) holding its value, and
    /// `next`'s keyframes after the cut with one at the cut taking its
    /// value there; where the two values meet at the cut, no hold is
    /// needed.
    func joined(with next: AnimatedValue, at cut: CMTime, holdingFrom hold: CMTime) -> AnimatedValue {
        guard self != next else { return self }
        let mine = value(at: hold), theirs = next.value(at: cut)
        var frames = keyframes.filter { CMTimeCompare($0.time, hold) < 0 }
        if mine != theirs {
            var held = keyframe(at: hold) ?? Keyframe(time: hold, value: mine)
            held.value = mine
            held.hold = true
            held.easeOut = nil
            frames.append(held)
        } else {
            // One value across the cut: this side's own keyframes up to it.
            frames += keyframes.filter { CMTimeCompare($0.time, hold) >= 0 && CMTimeCompare($0.time, cut) < 0 }
        }
        var start = next.keyframe(at: cut) ?? Keyframe(time: cut, value: theirs)
        start.value = theirs
        frames.append(start)
        frames += next.keyframes.filter { CMTimeCompare($0.time, cut) > 0 }
        return AnimatedValue(value, keyframes: frames)
    }
}
