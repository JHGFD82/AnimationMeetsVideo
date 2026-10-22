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
        let music = timeline.layers.filter { layer in
            layer.kind == .music && layer.clips.contains { CMTimeRangeGetIntersection(CMTimeRange(start: $0.startOffset, end: $0.endOffset), otherRange: span).duration > .zero }
        }
        musicLayers = music
        beats = project.musicBeats(in: timeline, tracks: DetectedBeats.shared.tracks)
        player = AVPlayer(playerItem: Self.musicItem(of: music, in: project))
        player.actionAtItemEnd = .pause
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
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                let composed = try await CompositionExporter.buildComposedTimeline(for: draft, timelineID: timelineID, forPreview: true)
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
        guard let start = dragStart else { return }
        dragStart = nil
        if start != run {
            registerUndo(restoring: start, name: name)
            schedulePreview()
        }
    }

    /// Moves a whole clip `delta` from where it was when the drag began.
    func dragPiece(_ id: UUID, by delta: CMTime) {
        guard let start = dragStart else { return }
        var edited = start
        edited.movePiece(id, by: delta)
        if edited != run { run = edited }
    }

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
        secondsPerPoint = min(max(length * 1.2 / Double(max(viewWidth, 100)), closestZoom), farthestZoom)
        visibleStart = span.start.seconds - length * 0.1
        clampView()
        hasFitted = true
    }

    /// The zoom's edge: a zoom past the whole timeline, or closer than the
    /// closest, stretches the lanes and springs back (`RubberBandZoom`).
    var zoomBand = RubberBandZoom()
    /// The scroll's edge: past the timeline's start or end the lanes slide
    /// on and spring back. Only sideways, the one way they zoom.
    var scrollBand = RubberBandScroll()

    /// The closest zoom: a frame about 80 points across, as the effects
    /// panel's lanes allow.
    var closestZoom: Double { run.frameDuration.seconds / 80 }
    /// Where the lanes end: the timeline's end, or the run's if it runs on.
    private var contentEnd: Double { max(timeline.duration.seconds, run.span.end.seconds) }
    /// The farthest zoom: the whole timeline across, with a tenth to spare.
    var farthestZoom: Double { max(contentEnd * 1.1 / Double(max(viewWidth, 100)), closestZoom) }

    /// Zooms by `factor` (above 1 zooms in) about a point `x` in the lanes.
    /// Zooming past the whole timeline or the closest zoom stretches the
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

    /// Scrolls the lanes sideways; past the timeline's ends they slide on
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

    /// The timeline's start sits at the left edge at most, and the lanes'
    /// end at the right edge at least, while the whole fits.
    private func clampView() {
        let span = Double(viewWidth) * secondsPerPoint
        visibleStart = min(max(visibleStart, 0), max(0, contentEnd - span))
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
