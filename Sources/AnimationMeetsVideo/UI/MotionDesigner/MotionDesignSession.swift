import AVFoundation
import CoreMedia
import Observation
import SwiftUI

/// One opening of the motion designer on a run of clips: the draft run with
/// an undo history of its own, the music under it with its beats, what is
/// selected, the view's zoom and scroll, and a player of the music alone.
/// Nothing reaches the project until Done. See docs/motion-designer.md.
@MainActor @Observable
final class MotionDesignSession {
    /// The draft being edited.
    private(set) var run: MotionRun
    /// Whether Done would change the project.
    var isChanged: Bool { run.isChanged }
    /// The panel's own undo history, for the draft.
    @ObservationIgnored let undoManager = UndoManager()

    /// The project as it was when the panel opened, for names, files and
    /// the music; the run is the only thing that changes.
    let project: EditingProject
    let timeline: Timeline
    /// The Music layer the run's clips are cut to: the first with a song
    /// under the run.
    let musicLayer: TimelineLayer?
    /// That layer's beats, in timeline time.
    let beats: [BeatMarker]

    // MARK: Editing

    var selectedPointID: UUID?
    var selectedPieceID: UUID?
    /// Asks the sidebar to focus the pace field (P, and Set Pace…).
    var focusesPace = false
    /// Shows the beats, and lets points and clips snap to them.
    var showsBeats = true
    var snaps = true
    /// What an edit couldn't do and why, until the next one.
    private(set) var message: String?
    /// An edit waiting on the person to agree to what it costs.
    struct PendingConflict: Identifiable {
        let id = UUID()
        let conflict: ClipTimeMap.Conflict
        let retry: () -> Void
    }
    var pendingConflict: PendingConflict?

    // MARK: View

    /// The left edge of the lanes, in timeline seconds, and the zoom.
    var visibleStart = 0.0
    var secondsPerPoint = 0.02
    var viewWidth: CGFloat = 800 {
        didSet {
            guard viewWidth > 0, viewWidth != oldValue else { return }
            if !hasFitted { fit() }
        }
    }
    @ObservationIgnored private var hasFitted = false

    // MARK: Transport

    @ObservationIgnored let player: AVPlayer
    /// Where the playhead is, in timeline seconds: where it was put or
    /// stopped. While playing, `livePlayhead` reads the player instead.
    private(set) var playhead = 0.0
    private(set) var isPlaying = false
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// The draft before a drag began, which its one undo step goes back to.
    @ObservationIgnored private var dragStart: MotionRun?

    init(run: MotionRun, project: EditingProject) {
        self.run = run
        self.project = project
        let timeline = project.timeline(id: run.timelineID)!
        self.timeline = timeline
        let span = run.span
        let music = timeline.layers.first { layer in
            layer.kind == .music && layer.clips.contains { CMTimeRangeGetIntersection(CMTimeRange(start: $0.startOffset, end: $0.endOffset), otherRange: span).duration > .zero }
        }
        musicLayer = music
        beats = music.map { project.beatMarkers(in: $0, tracks: DetectedBeats.shared.tracks) } ?? []
        player = AVPlayer(playerItem: music.flatMap { Self.musicItem(of: $0, in: project) })
        player.actionAtItemEnd = .pause
        player.audioOutputDeviceUniqueID = AudioDevices.playbackUID
        playhead = span.start.seconds
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.playingChanged(playing) }
        }
    }

    func end() {
        player.pause()
        statusObservation = nil
    }

    /// The music layer's songs as one sound, at their places on the
    /// timeline, so the player's time is the timeline's.
    private static func musicItem(of layer: TimelineLayer, in project: EditingProject) -> AVPlayerItem? {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        for clip in layer.clips {
            guard case .media(let id) = clip.source, let media = project.mediaClip(id: id), let url = media.url,
                  let sourceTrack = MediaFile.asset(at: url).tracks(withMediaType: .audio).first
            else { continue }
            let range = CMTimeRange(
                start: media.fileTime(forSourceTime: clip.trimStart),
                duration: clip.trimmedDuration
            )
            try? track.insertTimeRange(range, of: sourceTrack, at: clip.startOffset)
            if clip.isRetimed {
                track.scaleTimeRange(CMTimeRange(start: clip.startOffset, duration: clip.trimmedDuration), toDuration: clip.placedDuration)
            }
        }
        return AVPlayerItem(asset: composition)
    }

    // MARK: Edits

    /// Applies an edit as one undo step, unless a drag is under way, whose
    /// edits are one step when it ends.
    func perform(_ name: String, _ change: (inout MotionRun) -> Void) {
        var edited = run
        change(&edited)
        guard edited != run else { return }
        message = nil
        if dragStart == nil { registerUndo(restoring: run, name: name) }
        run = edited
    }

    func beginDrag() {
        dragStart = run
    }

    /// Begins a drag on its first change.
    func beginDragIfNeeded() {
        if dragStart == nil { dragStart = run }
    }

    var isDragging: Bool { dragStart != nil }

    /// Says why a clip with a hit didn't move.
    func explainHeldPiece() {
        message = "A clip with a hit is held by its beat. Make the hits markers to move it."
    }

    func endDrag(_ name: String) {
        guard let start = dragStart else { return }
        dragStart = nil
        if start != run { registerUndo(restoring: start, name: name) }
    }

    /// Moves a whole clip `delta` from where it was when the drag began.
    func dragPiece(_ id: UUID, by delta: CMTime) {
        guard let start = dragStart else { return }
        var edited = start
        edited.movePiece(id, by: delta)
        if edited != run { run = edited }
    }

    /// Puts the draft back as it was when the drag began (Escape).
    func cancelDrag() {
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
    }

    /// Sets a point's kind, asking first when it costs a hit or a pace.
    func setKind(_ kind: TimePoint.Kind, ofPoint id: UUID) {
        var edited = run
        if let conflict = edited.setKind(kind, ofPoint: id) {
            switch conflict {
            case .noRoom:
                message = "There isn't room for that: the clip would run into the one beside it, or past what it can play."
            case .hitWouldMove, .paceWouldEnd:
                pendingConflict = PendingConflict(conflict: conflict) { [weak self] in
                    self?.perform(Self.kindName(kind)) { _ = $0.setKind(kind, ofPoint: id, confirmed: true) }
                }
            }
            return
        }
        perform(Self.kindName(kind)) { $0 = edited }
    }

    static func kindName(_ kind: TimePoint.Kind) -> String {
        switch kind {
        case .hit: "Make Hit"
        case .marker: "Make Marker"
        case .pace: "Set Pace"
        }
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

    var selectedPoint: TimePoint? {
        guard let id = selectedPointID, let (piece, point) = run.piece(holdingPoint: id) else { return nil }
        return run.pieces[piece].map.points[point]
    }

    /// Nudges the selected point by whole frames of the timeline.
    func nudgeSelected(byFrames frames: Int) {
        guard let point = selectedPoint else { return }
        let delta = CMTimeMultiply(run.frameDuration, multiplier: Int32(frames))
        perform("Move Point") { $0.movePoint(point.id, to: CMTimeAdd(point.time, delta)) }
    }

    func deleteSelected() {
        guard let id = selectedPointID else { return }
        perform("Remove Point") { $0.removePoint(id) }
        selectedPointID = nil
    }

    /// Moves the selected clip by whole frames, if it has no hit.
    func nudgeSelectedPiece(byFrames frames: Int) {
        guard let id = selectedPieceID else { return }
        guard run.canMove(id) else { return explainHeldPiece() }
        perform("Move Clip") { $0.movePiece(id, by: CMTimeMultiply(run.frameDuration, multiplier: Int32(frames))) }
    }

    /// A piece as it plays in the draft, kept until its map or start
    /// changes, since an eased map is solved to write it.
    func drafted(_ piece: MotionRun.Piece) -> TimelineClip {
        if let kept = draftCache[piece.id], kept.map == piece.map, kept.start == piece.start { return kept.clip }
        let clip = piece.drafted
        draftCache[piece.id] = (piece.map, piece.start, clip)
        return clip
    }

    @ObservationIgnored private var draftCache: [UUID: (map: ClipTimeMap, start: CMTime, clip: TimelineClip)] = [:]

    // MARK: Snapping

    /// What a dragged time snaps to: the beats while shown, the playhead,
    /// and the edges of the clips, within `tolerance` seconds.
    func snapped(_ seconds: Double, tolerance: Double) -> Double? {
        guard snaps else { return nil }
        var targets = [playhead] + run.others.flatMap { [$0.start.seconds, $0.end.seconds] }
        if showsBeats { targets += beats.map(\.time.seconds) }
        let nearest = targets.min { abs($0 - seconds) < abs($1 - seconds) }
        guard let nearest, abs(nearest - seconds) <= tolerance else { return nil }
        return nearest
    }

    // MARK: Transport

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.seek(to: CMTime(seconds: playhead, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        }
    }

    func seek(to seconds: Double) {
        playhead = max(0, seconds)
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Where the playhead is at `date`: the player's time while it plays.
    func playhead(at date: Date) -> Double {
        isPlaying ? player.currentTime().seconds : playhead
    }

    private func playingChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if !playing { playhead = player.currentTime().seconds }
    }

    // MARK: View

    /// Fits the run, with a little room either side.
    func fit() {
        let span = run.span
        let length = max(span.duration.seconds, 1)
        secondsPerPoint = length * 1.2 / Double(max(viewWidth, 100))
        visibleStart = max(0, span.start.seconds - length * 0.1)
        hasFitted = true
    }

    func zoom(by factor: Double, aboutX x: CGFloat) {
        let anchor = seconds(atX: x)
        secondsPerPoint = min(max(secondsPerPoint / factor, 1.0 / 48_000), 2)
        visibleStart = max(0, anchor - Double(x) * secondsPerPoint)
    }

    func scroll(byPoints points: CGFloat) {
        visibleStart = max(0, visibleStart + Double(points) * secondsPerPoint)
    }

    func zoomIn() { zoom(by: 2, aboutX: x(of: selectedPoint?.time.seconds ?? playhead)) }
    func zoomOut() { zoom(by: 0.5, aboutX: x(of: selectedPoint?.time.seconds ?? playhead)) }

    func x(of seconds: Double) -> CGFloat { CGFloat((seconds - visibleStart) / secondsPerPoint) }
    func seconds(atX x: CGFloat) -> Double { visibleStart + Double(x) * secondsPerPoint }

    // MARK: Done

    /// Writes the changed clips into a project.
    func write(into project: inout EditingProject) {
        run.write(into: &project)
    }
}
