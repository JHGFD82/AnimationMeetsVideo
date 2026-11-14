import CoreMedia
import Foundation

// The clips the motion designer has open: the person's selection on one
// layer, retimed as one piece, each with its time map and the footage it
// may use (see docs/motion-designer.md, "Several clips as one piece",
// "Lengths and positions" and "Footage available").

/// The selected clips of one layer, in order, with what bounds them.
struct MotionRun: Equatable {
    /// Why the designer doesn't open on a selection.
    enum OpenError: Error, Equatable {
        case nothingSelected
        /// The clips are on more than one layer; nesting them makes one.
        case severalLayers
        /// Songs are the music, which the designer retimes footage to.
        case musicLayer
        /// Clips that play backwards can't be designed.
        case reversed
    }

    typealias Edge = ClipTimeMap.Edge

    /// One clip of the run.
    struct Piece: Identifiable, Equatable {
        /// The clip as it was when the designer opened.
        let clip: TimelineClip
        /// Its points, and the footage it plays (`trimStart` to `trimEnd`).
        var map: ClipTimeMap
        /// The footage its trim may reach, in source time: its scene (or the
        /// scenes it already spans), or the whole file.
        let footage: CMTimeRange
        var isEdited = false

        var id: UUID { clip.id }

        /// Whether its trim has reached the end of its footage at `edge`.
        func isAtFootageEdge(_ edge: Edge) -> Bool {
            edge == .start ? map.trimStart <= footage.start : map.trimEnd >= footage.end
        }

        /// The clip as it plays now in the draft, before Done rounds it onto
        /// the timeline's frames.
        var drafted: TimelineClip {
            var drafted = clip
            drafted.trimStart = map.trimStart
            drafted.trimEnd = map.trimEnd
            guard isEdited else { return drafted }
            if let written = map.writtenSpeed() {
                drafted.time.speed = written.speed
                let design = MotionDesign(map, speed: written.speed)
                drafted.time.design = design.points.isEmpty && design.startEase == nil && design.endEase == nil ? nil : design
                drafted.startOffset = written.start
            }
            return drafted
        }

        /// Where it plays on the timeline.
        var span: CMTimeRange {
            if let span = map.span { return CMTimeRange(start: span.start, end: span.end) }
            return .zero
        }

        /// Where the frame `source` plays, along the line.
        func time(atSource source: CMTime) -> CMTime {
            map.time(atSource: source) ?? drafted.timelineTime(forSourceTime: source)
        }
    }

    let timelineID: UUID
    let layerID: UUID
    let frameDuration: CMTime
    /// In timeline order.
    private(set) var pieces: [Piece]
    /// Where the layer's other clips are, which the run may not cover.
    let others: [CMTimeRange]

    /// The run of the clips with these IDs, or why there is none. `footage`
    /// says what a clip's trim may reach (its scene); without one it is the
    /// whole file. Either way it holds the clip's own trim.
    static func opening(
        _ ids: Set<UUID>, in timelineID: UUID, of project: EditingProject,
        footage: (TimelineClip) -> CMTimeRange? = { _ in nil }
    ) -> Result<MotionRun, OpenError> {
        guard let timeline = project.timeline(id: timelineID) else { return .failure(.nothingSelected) }
        let layers = timeline.layers.filter { layer in layer.clips.contains { ids.contains($0.id) } }
        guard let layer = layers.first else { return .failure(.nothingSelected) }
        guard layers.count == 1 else { return .failure(.severalLayers) }
        guard layer.kind != .music else { return .failure(.musicLayer) }
        let picked = layer.clips.filter { ids.contains($0.id) }.sorted { $0.startOffset < $1.startOffset }
        guard !picked.contains(where: \.isReversed) else { return .failure(.reversed) }
        let frame = timeline.frameDuration
        return .success(MotionRun(
            timelineID: timelineID, layerID: layer.id, frameDuration: frame,
            pieces: picked.map { clip in
                let trim = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
                let file = CMTimeRange(start: .zero, end: project.sourceDuration(for: clip.source) ?? clip.trimEnd)
                return Piece(
                    clip: clip, map: ClipTimeMap(reading: clip, frameDuration: frame),
                    footage: (footage(clip) ?? file).union(trim)
                )
            },
            others: layer.clips.filter { !ids.contains($0.id) }.map { CMTimeRange(start: $0.startOffset, end: $0.endOffset) }
        ))
    }

    func index(of id: UUID) -> Int? { pieces.firstIndex(id: id) }

    /// The piece holding a point, and where.
    func piece(holdingPoint id: UUID) -> (piece: Int, point: Int)? {
        for (p, piece) in pieces.enumerated() {
            if let point = piece.map.index(of: id) { return (p, point) }
        }
        return nil
    }

    /// Where the run starts and ends.
    var span: CMTimeRange {
        let spans = pieces.map(\.span)
        guard let first = spans.first else { return .zero }
        return spans.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Whether every piece fits: none before zero, and none over another
    /// piece or the layer's other clips.
    var fits: Bool {
        guard pieces.allSatisfy({ $0.map.isPlayable }) else { return false }
        let spans = pieces.map(\.span)
        guard spans.allSatisfy({ $0.start >= .zero }) else { return false }
        let all = (spans + others).sorted { $0.start < $1.start }
        let tolerance = Timeline.abutmentTolerance
        for (a, b) in zip(all, all.dropFirst()) where CMTimeSubtract(a.end, b.start) > tolerance {
            return false
        }
        return true
    }

    // MARK: Editing

    /// Puts a marker on a frame of a piece, where it plays now.
    @discardableResult
    mutating func addMarker(toPiece id: UUID, atSource source: CMTime) -> UUID? {
        guard let p = index(of: id) else { return nil }
        let time = pieces[p].time(atSource: source)
        return edit(p) { $0.addMarker(atSource: source, time: time) } ?? nil
    }

    /// Moves an unlocked marker as far as fits, keeping its source frame.
    /// Edge markers move by whole frames, interior markers continuously.
    mutating func movePoint(_ id: UUID, to time: CMTime) {
        guard let (p, i) = piece(holdingPoint: id), !pieces[p].map.points[i].locked else { return }
        let original = self
        let start = pieces[p].map.points[i].time
        if pieces[p].map.isEdge(id) {
            let steps = Int(((time - start).seconds / frameDuration.seconds).rounded())
            if let fitted = Self.furthest(steps: abs(steps), { count in
                var copy = original
                let target = start + CMTimeMultiply(copy.frameDuration, multiplier: Int32(steps < 0 ? -count : count))
                copy.pieces[p].map.move(id, to: target)
                // A speed limit can stop a map between frames. Reject that
                // candidate and try the preceding whole-frame step.
                guard copy.pieces[p].map.points[i].time == target else { return nil }
                copy.pieces[p].isEdited = copy.pieces[p].map != original.pieces[p].map || original.pieces[p].isEdited
                return copy
            }) { self = fitted }
        } else if let fitted = Self.furthest({ fraction in
            var copy = original
            copy.pieces[p].map.move(id, to: CMTime(seconds: start.seconds + (time - start).seconds * fraction, preferredTimescale: ClipTimeMap.timescale))
            copy.pieces[p].isEdited = copy.pieces[p].map != original.pieces[p].map || original.pieces[p].isEdited
            return copy
        }) { self = fitted }
    }

    mutating func trim(_ id: UUID, edge: Edge, to time: CMTime) {
        guard let p = index(of: id) else { return }
        let original = self
        let from = edge == .start ? pieces[p].span.start : pieces[p].span.end
        if let fitted = Self.furthest({ fraction in
            var copy = original
            copy.pieces[p].map.trim(edge, to: CMTime(seconds: from.seconds + (time - from).seconds * fraction,
                                                    preferredTimescale: ClipTimeMap.timescale),
                                   within: copy.pieces[p].footage, frame: copy.frameDuration)
            copy.pieces[p].isEdited = copy.pieces[p].map != original.pieces[p].map || original.pieces[p].isEdited
            return copy
        }) { self = fitted }
    }

    mutating func setLocked(_ locked: Bool, ofPoint id: UUID) {
        guard let (p, _) = piece(holdingPoint: id) else { return }
        edit(p) { $0.setLocked(locked, of: id) }
    }

    /// Sets a point's ease by its preset (`ClipTimeMap.setEase`).
    mutating func setEase(_ preset: KeyframeEase.Preset, ofPoint id: UUID) {
        guard let (p, _) = piece(holdingPoint: id) else { return }
        edit(p) { $0.setEase(preset, of: id) }
    }

    /// Whether either side of a point can ease (`ClipTimeMap.canEase`).
    func canEase(point id: UUID) -> Bool {
        guard let (p, _) = piece(holdingPoint: id) else { return false }
        return pieces[p].map.canEase(id)
    }

    /// Sets the handle on a side of a point (`ClipTimeMap.setHandle`).
    mutating func setHandle(_ side: TimePoint.Side, ofPoint id: UUID, to ease: KeyframeEase?, alone: Bool = false) {
        guard let (p, _) = piece(holdingPoint: id) else { return }
        edit(p) { $0.setHandle(side, of: id, to: ease, alone: alone) }
    }

    /// Keeps a point's handles in line or lets them part (`ClipTimeMap.setSmooth`).
    mutating func setSmooth(_ smooth: Bool, ofPoint id: UUID) {
        guard let (p, _) = piece(holdingPoint: id) else { return }
        edit(p) { $0.setSmooth(smooth, of: id) }
    }

    mutating func removePoint(_ id: UUID) {
        guard let (p, _) = piece(holdingPoint: id) else { return }
        edit(p) { $0.remove(id) }
    }

    /// Whether a piece can be moved: one with any locked marker is held.
    func canMove(_ id: UUID) -> Bool {
        guard let p = index(of: id) else { return false }
        return !pieces[p].map.points.contains(where: \.locked)
    }

    /// Moves a whole piece along the timeline, as far toward `delta` as it
    /// fits, on the timeline's frames. Not one with a locked marker.
    mutating func movePiece(_ id: UUID, by delta: CMTime) {
        guard let p = index(of: id), canMove(id) else { return }
        let original = self
        let frames = (delta.seconds / frameDuration.seconds).rounded()
        let fitted = Self.furthest(steps: Int(abs(frames))) { count in
            var copy = original
            let shift = CMTimeMultiply(frameDuration, multiplier: Int32(frames < 0 ? -count : count))
            copy.pieces[p].map.shift(by: shift)
            copy.pieces[p].isEdited = true
            return copy
        }
        if let fitted { self = fitted }
    }

    /// Applies a change to one piece's map, keeping its footage if asked,
    /// kept only if the run still fits.
    @discardableResult
    private mutating func edit<Result>(_ p: Int, _ change: (inout ClipTimeMap) -> Result) -> Result? {
        var copy = self
        let result = change(&copy.pieces[p].map)
        guard copy.pieces[p].map != pieces[p].map else { return result }
        copy.pieces[p].isEdited = true
        guard copy.fits else { return nil }
        self = copy
        return result
    }

    /// `edit(1)` if it fits, else the fraction of it nearest 1 that does;
    /// nil when not even a little of it does.
    private static func furthest(_ edit: (Double) -> MotionRun) -> MotionRun? {
        let whole = edit(1)
        if whole.fits { return whole }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if edit(middle).fits { low = middle } else { high = middle }
        }
        return low > 0 ? edit(low) : nil
    }

    /// `edit(steps)` if it fits, else the most whole steps that do.
    private static func furthest(steps: Int, _ edit: (Int) -> MotionRun?) -> MotionRun? {
        for count in stride(from: steps, to: 0, by: -1) {
            if let candidate = edit(count), candidate.fits { return candidate }
        }
        return nil
    }

    // MARK: Done

    /// Writes the pieces the person changed into the project: their speed
    /// keyframes and starts, a clip with pictures rounded onto the
    /// timeline's frames by moving its trim, not its footage. Pieces left
    /// alone keep their keyframes exactly.
    ///
    /// Given the run as it was `previous`ly written, only the pieces that
    /// differ from it are written, one no longer edited going back to how
    /// it opened. So writing each change as it is made, or the run as it
    /// opened to put them all back, touches nothing else. Either way only
    /// a clip's timing is written (`takeTiming`): the rest of each clip,
    /// and of the project, stays as the project now has it, so edits made
    /// elsewhere meanwhile are kept.
    func write(into project: inout EditingProject, over previous: MotionRun? = nil) {
        guard let timeline = project.timeline(id: timelineID) else { return }
        var wrote = false
        for piece in pieces {
            if let previous {
                guard let old = previous.pieces.first(id: piece.id),
                      piece.map != old.map || piece.isEdited != old.isEdited else { continue }
            } else {
                guard piece.isEdited else { continue }
            }
            var clip = piece.isEdited ? piece.drafted : piece.clip
            if piece.isEdited, project.isFrameLocked(clip) {
                var start = timeline.frameAligned(clip.startOffset, .nearest)
                // Rounding earlier mustn't ask for footage before its own.
                if clip.sourceTime(atTimelineTime: start) < piece.footage.start { start = timeline.frameAligned(clip.startOffset, .up) }
                let source = clip.sourceTime(atTimelineTime: start)
                clip.trimStart = source
                clip.startOffset = start
                clip = project.coveringWholeFrames(clip, in: timeline)
            }
            project.editClip(piece.id, in: timelineID) { $0.takeTiming(of: clip) }
            wrote = true
        }
        if wrote, let t = project.timelines.firstIndex(id: timelineID),
           let l = project.timelines[t].layers.firstIndex(id: layerID) {
            project.timelines[t].layers[l].clips.sort { $0.startOffset < $1.startOffset }
        }
    }

    /// Whether Done would change anything.
    var isChanged: Bool { pieces.contains(where: \.isEdited) }
}

extension TimelineClip {
    /// Takes on what the motion designer sets of `other`: where it plays,
    /// the footage it plays, and its speed with the points it came from.
    mutating func takeTiming(of other: TimelineClip) {
        startOffset = other.startOffset
        trimStart = other.trimStart
        trimEnd = other.trimEnd
        time.speed = other.time.speed
        time.design = other.time.design
    }
}

extension EditingProject {
    /// The footage a clip's trim may reach in the motion designer: from the
    /// start of the scene its first frame is in to the end of the scene its
    /// last frame is in, so a clip of one scene stays in that scene and one
    /// placed whole reaches the whole file. Merged scenes are one scene.
    /// Nil for anything but video, which may use all of its source.
    func sceneFootage(of clip: TimelineClip, track: ChangeScoreTrack?) -> CMTimeRange? {
        guard case .media(let id) = clip.source, mediaClip(id: id)?.kind == .video else { return nil }
        let scenes = scenes(ofAsset: id, track: track)
        guard let first = scenes.first(where: { $0.start <= clip.trimStart && clip.trimStart < $0.end }),
              let last = scenes.last(where: { $0.start < clip.trimEnd && clip.trimEnd <= $0.end })
        else { return nil }
        return CMTimeRange(start: first.start, end: last.end)
    }
}
