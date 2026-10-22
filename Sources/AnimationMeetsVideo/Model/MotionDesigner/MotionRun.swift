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

    /// Which edge of a clip.
    enum Edge { case start, end }

    /// One clip of the run.
    struct Piece: Identifiable, Equatable {
        /// The clip as it was when the designer opened.
        let clip: TimelineClip
        /// Its points, and the footage it plays (`trimStart` to `trimEnd`).
        var map: ClipTimeMap
        /// Where the clip starts while it has no points to place it.
        var start: CMTime
        /// The footage its trim may reach, in source time: its scene (or the
        /// scenes it already spans), or the whole file.
        let footage: CMTimeRange
        /// Whether the person changed it, so Done writes it.
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
            if let written = map.writtenSpeed() {
                drafted.time.speed = written.speed
                drafted.startOffset = written.start
            } else {
                drafted.startOffset = start
            }
            return drafted
        }

        /// Where it plays on the timeline.
        var span: CMTimeRange {
            if let span = map.span { return CMTimeRange(start: span.start, end: span.end) }
            return CMTimeRange(start: start, duration: drafted.placedDuration)
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
                    clip: clip, map: ClipTimeMap(reading: clip, frameDuration: frame), start: clip.startOffset,
                    footage: (footage(clip) ?? file).union(trim)
                )
            },
            others: layer.clips.filter { !ids.contains($0.id) }.map { CMTimeRange(start: $0.startOffset, end: $0.endOffset) }
        ))
    }

    func index(of id: UUID) -> Int? { pieces.firstIndex { $0.id == id } }

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
        let spans = pieces.map(\.span)
        guard spans.allSatisfy({ $0.start >= CMTimeMultiplyByRatio(frameDuration, multiplier: -1, divisor: 2) }) else { return false }
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
        return edit(p, holdingEdges: false) { $0.addMarker(atSource: source, time: time) } ?? nil
    }

    /// Moves a point along the timeline as `ClipTimeMap.move` does. The
    /// clip's outer edges stay where they are, taking in footage or giving
    /// it back, as far as its footage goes; past that an edge moves, and it
    /// stops against a neighbouring clip, which is the person's to move.
    mutating func movePoint(_ id: UUID, to time: CMTime) {
        guard let (p, _) = piece(holdingPoint: id) else { return }
        let original = self
        let span = pieces[p].span
        let start = pieces[p].map.points.first { $0.id == id }!.time.seconds
        let fitted = Self.furthest { fraction in
            var copy = original
            copy.pieces[p].map.move(id, to: CMTime(seconds: start + (time.seconds - start) * fraction, preferredTimescale: ClipTimeMap.timescale))
            copy.hold(p, to: span)
            copy.pieces[p].isEdited = true
            return copy
        }
        if let fitted { self = fitted }
    }

    /// Trims a piece's edge to `time` on the timeline, revealing footage or
    /// hiding it: as far as its footage goes, never past its outermost
    /// point or to under a frame, and stopping against a neighbour.
    mutating func trim(_ id: UUID, edge: Edge, to time: CMTime) {
        guard let p = index(of: id) else { return }
        let original = self
        let from = (edge == .start ? pieces[p].span.start : pieces[p].span.end).seconds
        let fitted = Self.furthest { fraction in
            var copy = original
            copy.setEdge(p, edge, to: CMTime(seconds: from + (time.seconds - from) * fraction, preferredTimescale: ClipTimeMap.timescale))
            return copy
        }
        if let fitted { self = fitted }
    }

    private mutating func setEdge(_ p: Int, _ edge: Edge, to time: CMTime) {
        var piece = pieces[p]
        let drafted = piece.drafted
        let frame = frameDuration
        let source = piece.map.source(atTime: time) ?? drafted.sourceTime(atTimelineTime: time)
        switch edge {
        case .start:
            let latest = piece.map.points.first?.source ?? CMTimeSubtract(piece.map.trimEnd, frame)
            piece.map.trimStart = CMTimeMinimum(CMTimeMaximum(source, piece.footage.start), latest)
            // Without points, the start follows the footage it now starts on.
            if piece.map.points.isEmpty { piece.start = drafted.timelineTime(forSourceTime: piece.map.trimStart) }
        case .end:
            let earliest = piece.map.points.last?.source ?? CMTimeAdd(piece.map.trimStart, frame)
            piece.map.trimEnd = CMTimeMaximum(CMTimeMinimum(source, piece.footage.end), earliest)
        }
        piece.isEdited = true
        pieces[p] = piece
    }

    /// Keeps piece `p` spanning `span` by moving its trim, as far as its
    /// footage and its outermost points allow.
    private mutating func hold(_ p: Int, to span: CMTimeRange) {
        var map = pieces[p].map
        guard let first = map.points.first, let last = map.points.last,
              let start = map.source(atTime: span.start), let end = map.source(atTime: span.end)
        else { return }
        let footage = pieces[p].footage
        map.trimStart = CMTimeMinimum(CMTimeMaximum(start, footage.start), first.source)
        map.trimEnd = CMTimeMaximum(CMTimeMinimum(end, footage.end), last.source)
        pieces[p].map = map
    }

    /// Sets a point's kind, as `ClipTimeMap.setKind` does; refused, with
    /// the conflict, when the person must agree first or the clip
    /// wouldn't fit.
    @discardableResult
    mutating func setKind(_ kind: TimePoint.Kind, ofPoint id: UUID, confirmed: Bool = false) -> ClipTimeMap.Conflict? {
        guard let (p, _) = piece(holdingPoint: id) else { return nil }
        var copy = self
        if let conflict = copy.pieces[p].map.setKind(kind, of: id, confirmed: confirmed) { return conflict }
        copy.hold(p, to: pieces[p].span)
        copy.pieces[p].isEdited = true
        guard copy.fits else { return .noRoom }
        self = copy
        return nil
    }

    mutating func setEased(_ eased: Bool, ofPoint id: UUID) {
        guard let (p, _) = piece(holdingPoint: id) else { return }
        edit(p, holdingEdges: true) { $0.setEased(eased, of: id) }
    }

    /// Shapes an eased point's ramps (`ClipTimeMap.setEase`).
    mutating func setEase(_ ease: TimeEase, ofPoint id: UUID) {
        guard let (p, _) = piece(holdingPoint: id) else { return }
        edit(p, holdingEdges: true) { $0.setEase(ease, of: id) }
    }

    mutating func removePoint(_ id: UUID) {
        guard let (p, _) = piece(holdingPoint: id) else { return }
        edit(p, holdingEdges: true) { $0.remove(id) }
    }

    /// Whether a piece can be moved: one with a hit is held by its beat.
    func canMove(_ id: UUID) -> Bool {
        guard let p = index(of: id) else { return false }
        return !pieces[p].map.points.contains(where: \.isHit)
    }

    /// Moves a whole piece along the timeline, as far toward `delta` as it
    /// fits, on the timeline's frames. Not one with a hit.
    mutating func movePiece(_ id: UUID, by delta: CMTime) {
        guard let p = index(of: id), canMove(id) else { return }
        let original = self
        let frames = (delta.seconds / frameDuration.seconds).rounded()
        let fitted = Self.furthest(steps: Int(abs(frames))) { count in
            var copy = original
            let shift = CMTimeMultiply(frameDuration, multiplier: Int32(frames < 0 ? -count : count))
            copy.pieces[p].map.shift(by: shift)
            copy.pieces[p].start = CMTimeAdd(copy.pieces[p].start, shift)
            copy.pieces[p].isEdited = true
            return copy
        }
        if let fitted { self = fitted }
    }

    /// Applies a change to one piece's map, holding its edges if asked,
    /// kept only if the run still fits.
    @discardableResult
    private mutating func edit<Result>(_ p: Int, holdingEdges: Bool, _ change: (inout ClipTimeMap) -> Result) -> Result? {
        var copy = self
        let result = change(&copy.pieces[p].map)
        if holdingEdges { copy.hold(p, to: pieces[p].span) }
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
    private static func furthest(steps: Int, _ edit: (Int) -> MotionRun) -> MotionRun? {
        for count in stride(from: steps, to: 0, by: -1) where edit(count).fits { return edit(count) }
        return nil
    }

    // MARK: Done

    /// Writes the pieces the person changed into the project: their speed
    /// keyframes and starts, a clip with pictures rounded onto the
    /// timeline's frames by moving its trim, not its footage. Pieces left
    /// alone keep their keyframes exactly.
    func write(into project: inout EditingProject) {
        guard let timeline = project.timeline(id: timelineID) else { return }
        for piece in pieces where piece.isEdited {
            var clip = piece.drafted
            if project.isFrameLocked(clip) {
                var start = timeline.frameAligned(clip.startOffset, .nearest)
                // Rounding earlier mustn't ask for footage before its own.
                if clip.sourceTime(atTimelineTime: start) < piece.footage.start { start = timeline.frameAligned(clip.startOffset, .up) }
                let source = clip.sourceTime(atTimelineTime: start)
                clip.trimStart = source
                clip.startOffset = start
                clip = project.coveringWholeFrames(clip, in: timeline)
            }
            project.editClip(piece.id, in: timelineID) { $0 = clip }
        }
        if let t = project.timelines.firstIndex(where: { $0.id == timelineID }),
           let l = project.timelines[t].layers.firstIndex(where: { $0.id == layerID }) {
            project.timelines[t].layers[l].clips.sort { $0.startOffset < $1.startOffset }
        }
    }

    /// Whether Done would change anything.
    var isChanged: Bool { pieces.contains(where: \.isEdited) }
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
