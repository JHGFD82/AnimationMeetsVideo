import AVFoundation
import CoreMedia
import Observation
import SwiftUI

/// One opening of the motion designer on a run of clips: the run with an
/// undo history of its own, the music under it with its beats, what is
/// selected, and the view's zoom and scroll. Each change to the run is
/// written into the project at once (`onDraftChange`), so the timeline
/// shows the clips where they now play and their speed keyframes as they
/// are made, and the editor's own player plays them. Only the timing of
/// the clips it changed is written, onto the project as it is then, so
/// edits made elsewhere while the panel is open stay. See
/// docs/motion-designer.md.
@MainActor @Observable
final class MotionDesignSession: SecondsViewport {
    /// The run being edited.
    private(set) var run: MotionRun {
        didSet {
            guard run.pieces != oldValue.pieces else { return }
            let run = run
            onDraftChange { run.write(into: &$0, over: oldValue) }
        }
    }
    /// The run as it opened, which Cancel writes back (`writeOpened`).
    let opened: MotionRun
    /// Whether the project differs from how it was when the panel opened.
    var isChanged: Bool { run.isChanged }
    /// The panel's own undo history, for the run.
    @ObservationIgnored let undoManager = UndoManager()
    /// Hears each change to the run as an edit that writes it into the
    /// project: the timing of the clips it changed, and nothing else.
    @ObservationIgnored var onDraftChange: ((inout EditingProject) -> Void) -> Void = { _ in }

    /// The project as it was when the panel opened, for names, files and
    /// the music. The run is written into the live project, not this.
    let project: EditingProject
    let timeline: Timeline
    /// The Music layers with a song under the run, in order: the first with
    /// a song at a moment is the one the footage is cut to then.
    let musicLayers: [TimelineLayer]
    /// The beats of the song in charge at each moment, in timeline time.
    let beats: [BeatMarker]

    // MARK: Editing

    /// The points picked, one or several (see `SelectClick`).
    var pickedPoints = SelectionSet<UUID>()
    /// The point picked alone, whose settings and handles show.
    var selectedPointID: UUID? {
        get { pickedPoints.single }
        set { pickedPoints.set(newValue.map { [$0] } ?? [], anchor: newValue) }
    }
    var selectedPieceID: UUID?
    /// Shows the beats, and lets points and clips snap to them. Kept
    /// between sessions, as the timeline keeps its beat markers.
    var showsBeats = UserDefaults.standard.object(forKey: Preferences.motionDesignerShowsBeats) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsBeats, forKey: Preferences.motionDesignerShowsBeats) }
    }
    var snaps = true
    /// Shows the frame under the pointer in the monitor as it moves over
    /// the lanes, without moving the playhead, as the timeline's skimming
    /// does. Kept between sessions.
    var skims = UserDefaults.standard.object(forKey: Preferences.motionDesignerSkimming) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(skims, forKey: Preferences.motionDesignerSkimming)
            if !skims { playback.endSkim() }
        }
    }
    /// What an edit couldn't do and why, until the next one.
    private(set) var message: String?
    /// A notice over the lanes, which any click puts away: why a clip held
    /// by a locked marker didn't move.
    var notice: String?
    // MARK: View

    /// The run as it opened, and the room the window keeps either side of
    /// it (`window`).
    private let openedSpan: (start: Double, end: Double)
    private let windowRoom: Double

    /// The stretch of the timeline the designer shows and plays: the run as
    /// it opened, and wherever it has been moved or grown to since, with a
    /// tenth of its length to spare either side. Only the music along it is
    /// drawn, and playing stops at its end, so the panel is about these
    /// clips and the music they are cut to, not the whole song.
    var window: (start: Double, end: Double) {
        let span = run.span
        let start = min(openedSpan.start, span.start.seconds), end = max(openedSpan.end, span.end.seconds)
        return (max(0, start - windowRoom), end + windowRoom)
    }

    /// The left edge of the lanes, in timeline seconds, and the zoom.
    var visibleStart = 0.0
    var secondsPerPoint = 0.02
    var viewWidth: CGFloat = 800 {
        didSet {
            guard viewWidth > 0, viewWidth != oldValue else { return }
            if !hasFitted { return fit() }
            secondsPerPoint = secondsPerPoint.clamped(between: closestZoom, and: farthestZoom)
            clampView()
        }
    }
    @ObservationIgnored private var hasFitted = false

    // MARK: Transport

    /// The editor's player, which plays the project as the run leaves it,
    /// as the viewer does: with its renders, its preview size and its mix.
    @ObservationIgnored let playback: PlaybackModel
    /// Where the playhead is, in timeline seconds.
    var playhead: Double { playback.currentTime.seconds }

    /// `time` as hh:mm:ss:ff at the timeline's frame rate (negative times
    /// read as zero).
    func timecode(_ time: CMTime) -> String {
        time.timecode(frameRate: timeline.frameRate)
    }

    func timecode(seconds: Double) -> String {
        timecode(CMTime(seconds: seconds, preferredTimescale: 600))
    }
    var isPlaying: Bool { playback.isPlaying }
    /// The run before a drag began, which its one undo step goes back to.
    @ObservationIgnored private var dragStart: MotionRun?
    /// The run a drag's steps apply to (`dragEdit`).
    @ObservationIgnored private var dragBase: MotionRun?

    init(run: MotionRun, project: EditingProject, playback: PlaybackModel) {
        self.run = run
        opened = run
        self.project = project
        let timeline = project.timeline(id: run.timelineID)!
        self.timeline = timeline
        let span = run.span
        openedSpan = (span.start.seconds, span.end.seconds)
        windowRoom = max(0.5, span.duration.seconds * 0.1)
        let music = timeline.layers.filter { layer in
            layer.kind == .music && layer.clips.contains { CMTimeRangeGetIntersection(CMTimeRange(start: $0.startOffset, end: $0.endOffset), otherRange: span).duration > .zero }
        }
        musicLayers = music
        beats = project.musicBeats(in: timeline, tracks: DetectedBeats.shared.tracks)
        self.playback = playback
        playback.seek(to: span.start)
    }

    func end() {
        playback.endSkim()
        if playback.isPlaying { playback.player.pause() }
        if let windowEndObserver { playback.player.removeTimeObserver(windowEndObserver) }
        windowEndObserver = nil
    }

    /// Puts the clips the run changed back as they were when the panel
    /// opened (Cancel), leaving the rest of the project as it now is.
    func writeOpened(into project: inout EditingProject) {
        opened.write(into: &project, over: run)
    }

    // MARK: Edits

    /// Applies an edit as one undo step, unless a drag is under way, whose
    /// edits are one step when it ends.
    func perform(_ name: String, _ change: (inout MotionRun) -> Void) {
        var edited = run
        change(&edited)
        guard edited != run else { return }
        message = nil
        if dragStart == nil { registerUndo(restoring: run, name: name) } else { dragBase = edited }
        run = edited
    }

    func beginDrag() {
        dragStart = run
        dragBase = run
        announcedLockedMarker = false
        announcedLockedEdge = false
    }

    /// Begins a drag on its first change.
    func beginDragIfNeeded() {
        if dragStart == nil { beginDrag() }
    }

    /// Applies a step of a drag to the run as the drag found it, not as
    /// its last step left it, so going back undoes what going further did
    /// (markers moved or handles shaped) and a drag back to
    /// where it began changes nothing. An edit made during the drag (the
    /// marker it grabbed) is part of where it began.
    func dragEdit(_ change: (inout MotionRun) -> Void) {
        guard let base = dragBase else { return }
        var edited = base
        change(&edited)
        message = nil
        if edited != run { run = edited }
    }

    var isDragging: Bool { dragStart != nil }

    /// Says why a clip with a locked marker didn't move, in the notice over the lanes.
    func explainHeldPiece() {
        let text = Self.heldPieceNotice
        notice = text
        AccessibilityNotification.Announcement(text).post()
    }

    static let heldPieceNotice = "This clip is held by a locked marker. Unlock its markers to move it."
    static let lockedMarkerNotice = "This marker is locked. Click it to unlock it."
    static let lockedEdgeNotice = "This edge is locked. Click its marker to unlock it."
    private var announcedLockedMarker = false
    private var announcedLockedEdge = false

    func explainLockedMarker() {
        guard !announcedLockedMarker else { return }
        announce(Self.lockedMarkerNotice)
        announcedLockedMarker = true
    }

    private func explainLockedEdge() {
        guard !isDragging || !announcedLockedEdge else { return }
        announce(Self.lockedEdgeNotice)
        announcedLockedEdge = true
    }

    private func announce(_ text: String) {
        notice = text
        AccessibilityNotification.Announcement(text).post()
    }

    func setLocked(_ locked: Bool, ofPoint id: UUID) {
        perform(locked ? "Lock Marker" : "Unlock Marker") { $0.setLocked(locked, ofPoint: id) }
    }

    func setLockedOfPicked(_ locked: Bool) {
        let ids = pickedPointIDs
        perform("\(locked ? "Lock" : "Unlock") \(ids.count == 1 ? "Marker" : "Markers")") { run in
            for id in ids { run.setLocked(locked, ofPoint: id) }
        }
    }

    func togglePickedLocks() {
        let points = run.pieces.flatMap(\.map.points).filter { pickedPointIDs.contains($0.id) }
        setLockedOfPicked(points.contains { !$0.locked })
    }

    func edgeIsLocked(_ id: UUID, _ edge: MotionRun.Edge) -> Bool {
        guard let piece = run.pieces.first(id: id) else { return false }
        return (edge == .start ? piece.map.points.first : piece.map.points.last)?.locked == true
    }

    func endDrag(_ name: String) {
        dragSnapTime = nil
        dragBase = nil
        guard let start = dragStart else { return }
        dragStart = nil
        if start != run { registerUndo(restoring: start, name: name) }
    }

    /// Moves a whole clip `delta` from where it was when the drag began.
    /// With a `snapTolerance` (in seconds), whichever of its edges comes
    /// nearer something to snap to lands on it (`snapped`), to the nearest
    /// frame, as a moved clip does.
    func dragPiece(_ id: UUID, by delta: CMTime, snapTolerance: Double? = nil) {
        guard let start = dragStart, let piece = start.pieces.first(id: id) else { return }
        var seconds = delta.seconds
        dragSnapTime = nil
        if let snapTolerance {
            let edges = [piece.span.start.seconds, piece.span.end.seconds]
            let nearest = edges.compactMap { edge -> (shift: Double, at: Double)? in
                snapped(edge + seconds, tolerance: snapTolerance, excluding: id).map { ($0 - edge, $0) }
            }.min { abs($0.shift - seconds) < abs($1.shift - seconds) }
            if let nearest {
                seconds = nearest.shift
                dragSnapTime = nearest.at
            }
        }
        var edited = start
        edited.movePiece(id, by: CMTime(seconds: seconds, preferredTimescale: ClipTimeMap.timescale))
        if edited != run { run = edited }
    }

    /// Where a clip being moved snapped, for the lanes to draw.
    private(set) var dragSnapTime: Double?

    /// Trims a clip's edge to `seconds`, from where it was when the drag
    /// began.
    func dragTrim(_ id: UUID, edge: MotionRun.Edge, to seconds: Double) {
        guard let start = dragStart else { return }
        guard !edgeIsLocked(id, edge) else { return explainLockedEdge() }
        var edited = start
        edited.trim(id, edge: edge, to: CMTime(seconds: seconds, preferredTimescale: ClipTimeMap.timescale))
        if edited != run { run = edited }
    }

    /// Trims the selected clip's edge by whole frames: later reveals footage
    /// at the end and hides it at the start.
    func trimSelectedPiece(_ edge: MotionRun.Edge, byFrames frames: Int) {
        guard let id = selectedPieceID, let piece = run.pieces.first(id: id) else { return }
        guard !edgeIsLocked(id, edge) else { return explainLockedEdge() }
        let at = edge == .start ? piece.span.start : piece.span.end
        let delta = CMTimeMultiply(run.frameDuration, multiplier: Int32(frames))
        perform("Trim Clip") { $0.trim(id, edge: edge, to: CMTimeAdd(at, delta)) }
    }

    /// Puts the draft back as it was when the drag began (Escape).
    func cancelDrag() {
        dragSnapTime = nil
        dragBase = nil
        guard let start = dragStart else { return }
        dragStart = nil
        run = start
    }

    private func registerUndo(restoring snapshot: MotionRun, name: String) {
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                let current = session.run
                session.run = snapshot
                session.registerUndo(restoring: current, name: name)
            }
        }
        undoManager.setActionName(name)
        undoRevision += 1
    }

    /// Counts changes to the undo stack, which `UndoManager` doesn't
    /// publish, so Undo and Redo follow it. Undoing and redoing register
    /// the way back, so ⌘Z from the Edit menu counts too.
    private var undoRevision = 0

    /// Whether there is a change to undo; not during a drag, whose start
    /// the undo would land under.
    var canUndo: Bool {
        _ = undoRevision
        return undoManager.canUndo && !isDragging
    }

    var canRedo: Bool {
        _ = undoRevision
        return undoManager.canRedo && !isDragging
    }

    /// What Undo and Redo would do, as the Edit menu names them.
    var undoTitle: String {
        _ = undoRevision
        return undoManager.undoMenuItemTitle
    }

    var redoTitle: String {
        _ = undoRevision
        return undoManager.redoMenuItemTitle
    }

    /// Undoes the last change to the draft, as ⌘Z does.
    func undo() {
        guard canUndo else { return }
        undoManager.undo()
    }

    func redo() {
        guard canRedo else { return }
        undoManager.redo()
    }

    /// Puts a marker on the frame of a piece playing at `seconds`, and
    /// selects it.
    @discardableResult
    func addMarker(toPiece id: UUID, atTime seconds: Double) -> UUID? {
        guard let index = run.index(of: id) else { return nil }
        let drafted = drafted(run.pieces[index])
        let time = CMTime(seconds: seconds, preferredTimescale: ClipTimeMap.timescale)
        guard drafted.startOffset <= time, time <= drafted.endOffset else { return nil }
        let source = drafted.sourceTime(atTimelineTime: time)
        var added: UUID?
        perform("Add Marker") { added = $0.addMarker(toPiece: id, atSource: source) }
        if let added { select(point: added) }
        return added
    }

    /// Adds a marker on the frame under the playhead, in the selected clip
    /// or the one there.
    func addMarkerAtPlayhead() {
        let time = CMTime(seconds: playhead, preferredTimescale: ClipTimeMap.timescale)
        let piece = run.pieces.first { $0.id == selectedPieceID && $0.span.containsTime(time) }
            ?? run.pieces.first { $0.span.containsTime(time) }
        guard let piece else {
            message = "The playhead isn't over a clip in the designer."
            return
        }
        addMarker(toPiece: piece.id, atTime: playhead)
    }

    func select(point id: UUID?) {
        selectedPointID = id
        if let id, let (piece, _) = run.piece(holdingPoint: id) { selectedPieceID = run.pieces[piece].id }
    }

    /// Every point of the run, in time order: what Shift-click picks along.
    var pointOrder: [UUID] {
        run.pieces.flatMap(\.map.points).sorted { $0.time < $1.time }.map(\.id)
    }

    /// A click on a point, as `click` says: alone, added or taken out, or
    /// the run from the point last clicked.
    func click(point id: UUID, _ click: SelectClick) {
        if click == .only, let (p, i) = run.piece(holdingPoint: id) {
            setLocked(!run.pieces[p].map.points[i].locked, ofPoint: id)
        }
        pickedPoints.click(id, click, in: pointOrder)
        if let only = pickedPoints.single, let (piece, _) = run.piece(holdingPoint: only) { selectedPieceID = run.pieces[piece].id }
    }

    /// The points a lasso covers, with those picked when it began.
    func lasso(points ids: Set<UUID>, keeping kept: Set<UUID>) {
        pickedPoints.lasso(ids, keeping: kept)
    }

    /// The picked points that are still in the run.
    var pickedPointIDs: Set<UUID> {
        pickedPoints.items.filter { run.piece(holdingPoint: $0) != nil }
    }

    /// Moves points from where they were (`from`, in seconds) by `delta`
    /// seconds together, the leading ones first so none is stopped by
    /// another of them; each stops as a point dragged alone does.
    static func movePoints(_ from: [UUID: Double], by delta: Double, in run: inout MotionRun) {
        let ordered = from.sorted { a, b in
            if a.value != b.value { return delta > 0 ? a.value > b.value : a.value < b.value }
            let pa = run.piece(holdingPoint: a.key)?.piece ?? 0
            let pb = run.piece(holdingPoint: b.key)?.piece ?? 0
            return delta > 0 ? pa > pb : pa < pb
        }
        for (id, seconds) in ordered {
            run.movePoint(id, to: CMTime(seconds: seconds + delta, preferredTimescale: ClipTimeMap.timescale))
        }
    }

    var selectedPoint: TimePoint? {
        guard let id = selectedPointID, let (piece, point) = run.piece(holdingPoint: id) else { return nil }
        return run.pieces[piece].map.points[point]
    }

    /// Nudges the picked points by whole frames of the timeline.
    func nudgeSelected(byFrames frames: Int) {
        var from: [UUID: Double] = [:]
        for id in pickedPointIDs {
            if let (p, i) = run.piece(holdingPoint: id) { from[id] = run.pieces[p].map.points[i].time.seconds }
        }
        guard !from.isEmpty else { return }
        let delta = CMTimeMultiply(run.frameDuration, multiplier: Int32(frames)).seconds
        perform(from.count == 1 ? "Move Point" : "Move Points") { Self.movePoints(from, by: delta, in: &$0) }
    }

    /// Sets the ease of every picked point that can take it.
    func setEaseOfPicked(_ preset: KeyframeEase.Preset) {
        let ids = pickedPointIDs
        guard ids.count > 1 else {
            if let id = ids.first { setEase(preset, ofPoint: id) }
            return
        }
        perform(preset.name) { run in
            for id in ids where preset == .linear || run.canEase(point: id) { run.setEase(preset, ofPoint: id) }
        }
    }

    /// Sets a point's ease by its preset, as a keyframe's is set, named so
    /// in the undo menu. A point neither side of which can ease says so
    /// instead.
    func setEase(_ preset: KeyframeEase.Preset, ofPoint id: UUID) {
        guard preset == .linear || run.canEase(point: id) else {
            message = Self.nothingToEase
            return
        }
        perform(preset.name) { $0.setEase(preset, ofPoint: id) }
    }

    static let nothingToEase = "This marker has no stretch on that side to ease."

    /// The selected point's piece's map, and where the point is in it.
    var selectedPlace: (map: ClipTimeMap, index: Int)? {
        guard let id = selectedPointID, let (piece, point) = run.piece(holdingPoint: id) else { return nil }
        return (run.pieces[piece].map, point)
    }

    /// Lengthens or shortens the handle on a side of the selected point by
    /// `step` of its stretch, putting one out on the straight line on a
    /// side that has none.
    func reshapeSelectedEase(_ side: TimePoint.Side, by step: Double) {
        guard let point = selectedPoint, let place = selectedPlace, place.map.canEase(side, of: place.index) else { return }
        let ease = point.ease(side) ?? KeyframeEase(influence: KeyframeEase.linearInfluence, speed: 1)
        perform(side == .before ? "Shape Ease In" : "Shape Ease Out") {
            $0.setHandle(side, ofPoint: point.id, to: KeyframeEase(influence: ease.influence + step, speed: ease.speed))
        }
    }

    /// Sets the speed the line has at the selected point on a side, as a
    /// percentage, as tilting its handle does: the other side's handle
    /// follows while they are in line.
    func setSelectedSpeed(_ side: TimePoint.Side, to percent: Double) {
        guard let point = selectedPoint, let place = selectedPlace, place.map.canEase(side, of: place.index) else { return }
        let straight = place.map.straightSpeed(side, of: place.index)
        guard straight > 0 else { return }
        let ease = point.ease(side) ?? KeyframeEase(influence: KeyframeEase.linearInfluence, speed: 1)
        perform(side == .before ? "Shape Ease In" : "Shape Ease Out") {
            $0.setHandle(side, ofPoint: point.id, to: KeyframeEase(influence: ease.influence, speed: max(0, percent) / straight), alone: !point.smooth)
        }
    }

    var canRemovePicked: Bool {
        run.pieces.contains { piece in
            piece.map.points.contains { pickedPointIDs.contains($0.id) && !$0.locked && !piece.map.isEdge($0.id) }
        }
    }

    func deleteSelected() {
        let ids = pickedPointIDs
        guard !ids.isEmpty else { return }
        let locked = run.pieces.flatMap(\.map.points).contains { ids.contains($0.id) && $0.locked }
        if locked { announce(Self.lockedMarkerNotice) }
        perform(ids.count == 1 ? "Remove Marker" : "Remove Markers") { run in
            for id in ids {
                guard let (p, i) = run.piece(holdingPoint: id) else { continue }
                let map = run.pieces[p].map
                if map.points[i].locked { continue }
                if map.isEdge(id) { run.setEase(.linear, ofPoint: id) }
                else { run.removePoint(id) }
            }
        }
        pickedPoints.set(ids.filter { run.piece(holdingPoint: $0) != nil })
    }

    /// Moves the selected clip by whole frames, if it has no locked marker.
    func nudgeSelectedPiece(byFrames frames: Int) {
        guard let id = selectedPieceID else { return }
        guard run.canMove(id) else { return explainHeldPiece() }
        perform("Move Clip") { $0.movePiece(id, by: CMTimeMultiply(run.frameDuration, multiplier: Int32(frames))) }
    }

    /// A piece as it plays in the draft, kept until its map or start
    /// changes, since an eased map is solved to write it.
    func drafted(_ piece: MotionRun.Piece) -> TimelineClip {
        if let kept = draftCache[piece.id], kept.map == piece.map { return kept.clip }
        let clip = piece.drafted
        draftCache[piece.id] = (piece.map, clip)
        return clip
    }

    @ObservationIgnored private var draftCache: [UUID: (map: ClipTimeMap, clip: TimelineClip)] = [:]

    // MARK: Snapping

    /// The beats along the window, which are drawn and snapped to.
    var beatsInWindow: [BeatMarker] {
        let window = window
        return beats.filter { window.start <= $0.time.seconds && $0.time.seconds <= window.end }
    }

    /// What a dragged time snaps to: the beats while shown, the playhead,
    /// and the edges of the layer's clips, the run's own but the piece
    /// `excluding` (the one being dragged) included, within `tolerance`
    /// seconds.
    func snapped(_ seconds: Double, tolerance: Double, excluding id: UUID? = nil) -> Double? {
        guard snaps else { return nil }
        let clips = run.others + run.pieces.filter { $0.id != id }.map(\.span)
        var targets = [playhead] + clips.flatMap { [$0.start.seconds, $0.end.seconds] }
        if showsBeats { targets += beatsInWindow.map(\.time.seconds) }
        let nearest = targets.min { abs($0 - seconds) < abs($1 - seconds) }
        guard let nearest, abs(nearest - seconds) <= tolerance else { return nil }
        return nearest
    }

    // MARK: Transport

    /// Plays from the playhead to the window's end, starting over from the
    /// window's start when the playhead is there already.
    func togglePlayback() {
        if isPlaying { return playback.togglePlayback() }
        let window = window
        if playhead >= window.end - run.frameDuration.seconds || playhead < window.start { seek(to: window.start) }
        stopsAtWindowEnd(window.end)
        playback.togglePlayback()
    }

    /// Pauses the player when it reaches `end`.
    private func stopsAtWindowEnd(_ end: Double) {
        let player = playback.player
        if let windowEndObserver { player.removeTimeObserver(windowEndObserver) }
        windowEndObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 48_000))], queue: .main
        ) { [weak player] in
            player?.pause()
        }
    }

    @ObservationIgnored private var windowEndObserver: Any?

    /// Moves the playhead to `seconds`, within the window.
    func seek(to seconds: Double) {
        let window = window
        playback.seek(to: CMTime(seconds: seconds.clamped(between: window.start, and: window.end), preferredTimescale: 48_000))
    }

    /// Shows the frame under the pointer at `x` in the lanes, within the
    /// window, without moving the playhead; ends the skim off the lanes,
    /// or with skimming off.
    func skim(atX x: CGFloat?) {
        guard skims, let x else {
            playback.endSkim()
            return
        }
        let seconds = seconds(atX: x).clamped(between: window.start, and: window.end)
        playback.skim(to: timeline.snappedToFrame(CMTime(seconds: seconds, preferredTimescale: 600_000)))
    }

    /// Where the playhead is at `date`: the player's time while it plays.
    func playhead(at date: Date) -> Double {
        isPlaying ? playback.player.currentTime().seconds : playhead
    }

    // MARK: View

    /// Fits the run, with the window's room either side.
    func fit() {
        let span = run.span
        let length = span.duration.seconds + 2 * windowRoom
        secondsPerPoint = (length / Double(max(viewWidth, 100))).clamped(between: closestZoom, and: farthestZoom)
        visibleStart = span.start.seconds - windowRoom
        clampView()
        hasFitted = true
    }

    /// The zoom's edge: a zoom past the whole window, or closer than the
    /// closest, stretches the lanes and springs back (`RubberBandZoom`).
    var zoomBand = RubberBandZoom()
    /// The scroll's edge: past the window's start or end the lanes slide
    /// on and spring back. Only sideways, the one way they zoom.
    var scrollBand = RubberBandScroll()

    /// The closest zoom: a frame about 80 points across, as the effects
    /// panel's lanes allow.
    var closestZoom: Double { run.frameDuration.seconds / 80 }
    /// The farthest zoom: the whole window across.
    var farthestZoom: Double {
        let window = window
        return max((window.end - window.start) / Double(max(viewWidth, 100)), closestZoom)
    }

    /// The lanes show the window.
    var viewBounds: (start: Double, end: Double) { window }
    /// Zooming in zooms about the selected point, or the playhead.
    var zoomFocus: Double { selectedPoint?.time.seconds ?? playhead }
}
