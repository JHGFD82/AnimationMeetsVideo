import AVFoundation
import CoreMedia
import Observation
import SwiftUI

/// One opening of the motion designer on a run of clips: the draft run with
/// an undo history of its own, the music under it with its beats, what is
/// selected, the view's zoom and scroll, and a player of the draft. The
/// player plays the timeline as Done would leave it, picture and sound,
/// rebuilt shortly after each edit; until the first build is ready it
/// plays the music alone. Nothing reaches the project until Done. See
/// docs/motion-designer.md.
@MainActor @Observable
final class MotionDesignSession {
    /// The draft being edited.
    private(set) var run: MotionRun {
        // A drag rebuilds the preview once it ends.
        didSet { if dragStart == nil, run != oldValue { schedulePreview() } }
    }
    /// Whether Done would change the project.
    var isChanged: Bool { run.isChanged }
    /// The panel's own undo history, for the draft.
    @ObservationIgnored let undoManager = UndoManager()

    /// The project as it was when the panel opened, for names, files and
    /// the music; the run is the only thing that changes.
    let project: EditingProject
    let timeline: Timeline
    /// The Music layers with a song under the run, in order: the first with
    /// a song at a moment is the one the footage is cut to then.
    let musicLayers: [TimelineLayer]
    /// The beats of the song in charge at each moment, in timeline time.
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
            secondsPerPoint = min(max(secondsPerPoint, closestZoom), farthestZoom)
            clampView()
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
        openedSpan = (span.start.seconds, span.end.seconds)
        windowRoom = max(0.5, span.duration.seconds * 0.1)
        let music = timeline.layers.filter { layer in
            layer.kind == .music && layer.clips.contains { CMTimeRangeGetIntersection(CMTimeRange(start: $0.startOffset, end: $0.endOffset), otherRange: span).duration > .zero }
        }
        musicLayers = music
        beats = project.musicBeats(in: timeline, tracks: DetectedBeats.shared.tracks)
        player = AVPlayer(playerItem: Self.musicItem(of: music, in: project))
        player.actionAtItemEnd = .pause
        // Media is local: play starts at once, as the viewer's does,
        // rather than waiting for the player to judge its buffer full.
        player.automaticallyWaitsToMinimizeStalling = false
        drawingOptions.update(motionBlurInPreview: UserDefaults.standard.object(forKey: Preferences.motionBlurInPreview) as? Bool ?? true)
        player.audioOutputDeviceUniqueID = AudioDevices.playbackUID
        playhead = span.start.seconds
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.playingChanged(playing) }
        }
        schedulePreview(after: .zero)
    }

    func end() {
        previewTask?.cancel()
        previewTask = nil
        player.pause()
        if let windowEndObserver { player.removeTimeObserver(windowEndObserver) }
        windowEndObserver = nil
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
    }

    // MARK: Preview

    /// Whether the player has the draft's picture to show yet, and whether
    /// a newer one is being made.
    private(set) var showsDraft = false
    private(set) var isUpdatingPreview = false
    /// Why the draft couldn't be played, until a later build can.
    private(set) var previewError: String?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// The draft's volumes and pans, which its sound plays at.
    @ObservationIgnored private let mixCurves = MixCurves()
    /// What the compositor is told, as the viewer tells it: drawing for
    /// display, so retimed footage blends its frames rather than working out
    /// optical flow, and motion blur takes fewer samples while playing.
    /// Without it the draft would be drawn as for export, too slowly to play.
    @ObservationIgnored private let drawingOptions = DrawingOptions()
    /// The monitor is small, so the picture is drawn at half size.
    static let previewScale = 0.5
    /// Draws paused frames of the draft, which a player layer may not show
    /// until it plays; counted up with each build, so a frame drawn from an
    /// older draft is asked for again.
    @ObservationIgnored private var frameGenerator: AVAssetImageGenerator?
    private(set) var draftSerial = 0

    /// The last paused frame drawn, which the monitor shows at once when it
    /// comes back (after playing, say) until the frame it asks for is drawn.
    @ObservationIgnored private(set) var lastDraftFrame: CGImage?

    /// The draft's frame at `seconds`, drawn from the latest build.
    func draftFrame(at seconds: Double) async -> CGImage? {
        guard let frameGenerator else { return nil }
        let image = await Self.frame(HandedOver(value: frameGenerator), at: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        if let image { lastDraftFrame = image }
        return image
    }

    /// Set up once and never changed after, so it can be asked from off the
    /// main actor, as `FrameThumbnails` does.
    private nonisolated static func frame(_ generator: HandedOver<AVAssetImageGenerator>, at time: CMTime) async -> CGImage? {
        try? await generator.value.image(at: time).image
    }

    /// The timeline as Done would leave it.
    var draftProject: EditingProject {
        var draft = project
        run.write(into: &draft)
        return draft
    }

    /// Builds the draft's player item after `delay`, replacing any build
    /// under way, so a run of edits builds once.
    private func schedulePreview(after delay: Duration = .milliseconds(250)) {
        previewTask?.cancel()
        isUpdatingPreview = true
        let draft = draftProject
        let timelineID = run.timelineID
        let drawingOptions = drawingOptions
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                let composed = try await CompositionExporter.buildComposedTimeline(
                    for: draft, timelineID: timelineID, forPreview: true, options: drawingOptions
                )
                try Task.checkCancellation()
                await self?.present(composed, of: draft)
            } catch is CancellationError {
            } catch {
                self?.previewError = error.localizedDescription
                self?.isUpdatingPreview = false
            }
        }
    }

    /// Swaps the player onto a newly built draft at the same moment,
    /// playing on if it was.
    private func present(_ composed: ComposedTimeline, of draft: EditingProject) async {
        let item = AVPlayerItem(asset: composed.composition)
        item.videoComposition = composed.videoComposition(scaledBy: Self.previewScale)
        mixCurves.replace(with: MixCurves.of(draft))
        item.audioMix = composed.audioMix(curves: mixCurves)
        let wasPlaying = isPlaying
        let time = wasPlaying ? player.currentTime() : CMTime(seconds: playhead, preferredTimescale: 48_000)
        // Seeked before it's shown, so the swap doesn't flash its first frame.
        _ = await item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        guard !Task.isCancelled else { return }
        player.replaceCurrentItem(with: item)
        if wasPlaying { player.play() }
        if composed.hasPictures {
            let generator = AVAssetImageGenerator(asset: composed.composition)
            generator.videoComposition = item.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 960, height: 540)
            frameGenerator = generator
        } else {
            frameGenerator = nil
        }
        draftSerial += 1
        showsDraft = composed.hasPictures
        previewError = nil
        isUpdatingPreview = false
    }

    /// The Music layers' songs as one sound, each layer a track, at their
    /// places on the timeline, so the player's time is the timeline's.
    private static func musicItem(of layers: [TimelineLayer], in project: EditingProject) -> AVPlayerItem? {
        guard !layers.isEmpty else { return nil }
        let composition = AVMutableComposition()
        for layer in layers {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            add(layer, to: track, in: project)
        }
        return AVPlayerItem(asset: composition)
    }

    private static func add(_ layer: TimelineLayer, to track: AVMutableCompositionTrack, in project: EditingProject) {
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
        dragSnapTime = nil
        guard let start = dragStart else { return }
        dragStart = nil
        if start != run {
            registerUndo(restoring: start, name: name)
            schedulePreview()
        }
    }

    /// Moves a whole clip `delta` from where it was when the drag began.
    /// With a `snapTolerance` (in seconds), whichever of its edges comes
    /// nearer something to snap to lands on it (`snapped`), to the nearest
    /// frame, as a moved clip does.
    func dragPiece(_ id: UUID, by delta: CMTime, snapTolerance: Double? = nil) {
        guard let start = dragStart, let piece = start.pieces.first(where: { $0.id == id }) else { return }
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
        var edited = start
        edited.trim(id, edge: edge, to: CMTime(seconds: seconds, preferredTimescale: ClipTimeMap.timescale))
        if edited != run { run = edited }
    }

    /// Trims the selected clip's edge by whole frames: later reveals footage
    /// at the end and hides it at the start.
    func trimSelectedPiece(_ edge: MotionRun.Edge, byFrames frames: Int) {
        guard let id = selectedPieceID, let piece = run.pieces.first(where: { $0.id == id }) else { return }
        let at = edge == .start ? piece.span.start : piece.span.end
        let delta = CMTimeMultiply(run.frameDuration, multiplier: Int32(frames))
        perform("Trim Clip") { $0.trim(id, edge: edge, to: CMTimeAdd(at, delta)) }
    }

    /// Puts the draft back as it was when the drag began (Escape).
    func cancelDrag() {
        dragSnapTime = nil
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

    /// Lengthens or shortens one of the selected point's ramps by `step` of
    /// its stretch, easing it first if it wasn't.
    func reshapeSelectedEase(before: Bool, by step: Double) {
        guard let point = selectedPoint else { return }
        var ease = point.ease ?? TimeEase()
        if before { ease.before += step } else { ease.after += step }
        perform("Shape Ease") {
            $0.setEased(true, ofPoint: point.id)
            $0.setEase(TimeEase(before: ease.before, after: ease.after), ofPoint: point.id)
        }
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
        if isPlaying {
            player.pause()
        } else {
            let window = window
            if playhead >= window.end - run.frameDuration.seconds { playhead = window.start }
            player.seek(to: CMTime(seconds: playhead, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
            stopsAtWindowEnd(window.end)
            player.play()
        }
    }

    /// Pauses the player when it reaches `end`.
    private func stopsAtWindowEnd(_ end: Double) {
        if let windowEndObserver { player.removeTimeObserver(windowEndObserver) }
        windowEndObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 48_000))], queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated { self?.player.pause() }
        }
    }

    @ObservationIgnored private var windowEndObserver: Any?

    /// Moves the playhead to `seconds`, within the window.
    func seek(to seconds: Double) {
        let window = window
        playhead = min(max(seconds, window.start), window.end)
        player.seek(to: CMTime(seconds: playhead, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Where the playhead is at `date`: the player's time while it plays.
    func playhead(at date: Date) -> Double {
        isPlaying ? player.currentTime().seconds : playhead
    }

    private func playingChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        drawingOptions.update(isPlaying: playing)
        if !playing { playhead = player.currentTime().seconds }
    }

    // MARK: View

    /// Fits the run, with the window's room either side.
    func fit() {
        let span = run.span
        let length = span.duration.seconds + 2 * windowRoom
        secondsPerPoint = min(max(length / Double(max(viewWidth, 100)), closestZoom), farthestZoom)
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

    /// Zooms by `factor` (above 1 zooms in) about a point `x` in the lanes.
    /// Zooming past the whole window or the closest zoom stretches the
    /// lanes instead (`zoomBand`), until the pinch lifts, or at once for
    /// any other zoom.
    func zoom(by factor: Double, aboutX x: CGFloat, pinching: Bool = false) {
        var band = zoomBand
        band.zoom(by: factor, about: viewWidth > 0 ? x / viewWidth : 0.5, pinching: pinching) { factor in
            let anchor = seconds(atX: x)
            let before = secondsPerPoint
            secondsPerPoint = min(max(secondsPerPoint / factor, closestZoom), farthestZoom)
            visibleStart = anchor - Double(x) * secondsPerPoint
            clampView()
            return before / secondsPerPoint
        }
        zoomBand = band
    }

    /// The pinch's fingers lifted: the stretch springs back.
    func endPinch() { zoomBand.endPinch() }

    /// Scrolls the lanes sideways; past the window's ends they slide on
    /// and spring back (`scrollBand`).
    func scroll(byPoints points: CGFloat, phase: ScrollInputPhase = .wheel) {
        var band = scrollBand
        band.scroll(by: points, phase: phase) { points in
            let before = visibleStart
            visibleStart += Double(points) * secondsPerPoint
            clampView()
            return CGFloat((visibleStart - before) / secondsPerPoint)
        }
        scrollBand = band
    }

    /// The window's start sits at the left edge at most, and its end at the
    /// right edge at least, while the whole fits.
    private func clampView() {
        let span = Double(viewWidth) * secondsPerPoint
        let window = window
        visibleStart = min(max(visibleStart, window.start), max(window.start, window.end - span))
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
