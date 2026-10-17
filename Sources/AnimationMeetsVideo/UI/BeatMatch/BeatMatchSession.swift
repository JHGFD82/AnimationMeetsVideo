import AVFoundation
import CoreMedia
import Observation
import SwiftUI

/// One opening of the beat match panel for one song: its audio, a player
/// of its own that plays the song alone with the tick, what is selected,
/// and the zoom. The beat map itself stays in the project; edits go back
/// through `onEdit`, so each is an undo step. See docs/beat-matching.md.
@MainActor @Observable
final class BeatMatchSession {
    let assetID: UUID
    let assetName: String
    /// The song's editing time, in original time.
    let duration: CMTime
    /// Original time `t` is at `t + alignment` in the file.
    let alignment: CMTime

    private(set) var audio: BeatMatchAudio?
    private(set) var loadProgress = 0.0
    private(set) var loadError: String?
    /// The map as the project has it now.
    private(set) var map: BeatMap
    @ObservationIgnored var onEdit: ((inout BeatMap) -> Void) -> Void = { _ in }

    // MARK: Transport

    let player: AVPlayer
    let clicks: BeatClickPlayer
    /// Where the song is, in seconds of original time.
    private(set) var playhead = 0.0
    private(set) var isPlaying = false
    /// Repeats the two measures around the selected beat.
    var isLooping = false
    var clicksOn = true {
        didSet { clicks.isEnabled = clicksOn }
    }

    // MARK: View

    /// The waveform's left edge, in seconds, and its zoom.
    var visibleStart = 0.0
    var secondsPerPoint = 0.05
    /// The waveform's width, which zooming and fitting work from. A resize
    /// keeps the same stretch of song in view, so the waveform scales with
    /// the panel.
    var viewWidth: CGFloat = 800 {
        didSet {
            guard viewWidth > 0, viewWidth != oldValue else { return }
            guard hasFitted, oldValue > 0 else { return fit() }
            secondsPerPoint = min(max(secondsPerPoint * Double(oldValue / viewWidth), closestZoom), farthestZoom)
            clampView()
        }
    }
    @ObservationIgnored private var hasFitted = false

    // MARK: Editing

    var selectedSectionID: UUID?
    /// The selected beat, by its time.
    var selectedBeat: CMTime?
    /// The kind a drawn or filled section gets.
    var drawKind: BeatSection.Kind = .consistent
    /// True while sections are being drawn, before they are marked.
    var isDrawing: Bool
    /// What went wrong with the last fill, or a hint, until the next edit.
    private(set) var message: String?
    private(set) var isFilling = false

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(asset: MediaClip, url: URL) {
        assetID = asset.id
        assetName = asset.name
        duration = asset.originalDuration ?? asset.duration
        alignment = asset.alignmentOffset
        map = asset.beatMap
        isDrawing = asset.beatMap.usesSections && !asset.beatMap.sections.contains { !$0.pinnedBeats.isEmpty || $0.isConfirmed }
        player = AVPlayer(playerItem: AVPlayerItem(url: url))
        player.actionAtItemEnd = .pause
        clicks = BeatClickPlayer(player: player)
        clicks.isEnabled = true
        selectedSectionID = asset.beatMap.sections.first { $0.kind == .consistent && !$0.isConfirmed }?.id
            ?? asset.beatMap.sections.first?.id

        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerMoved(to: time) }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        refreshTicks()
        loading = Task { [weak self] in
            do {
                let audio = try await BeatMatchAudio.load(url: url, alignment: asset.alignmentOffset) { value in
                    Task { @MainActor in self?.loadProgress = value }
                }
                self?.audio = audio
            } catch is CancellationError {
            } catch {
                self?.loadError = error.localizedDescription
            }
        }
    }

    /// Stops playing and reading; the session is done with.
    func end() {
        loading?.cancel()
        player.pause()
        clicks.isEnabled = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
    }

    /// The project's map changed, by an edit here or an undo.
    func mapChanged(_ map: BeatMap) {
        guard map != self.map else { return }
        self.map = map
        if let id = selectedSectionID, map.section(id: id) == nil { selectedSectionID = map.sections.first?.id }
        if let beat = selectedBeat, map.beat(at: beat) == nil { selectedBeat = nil }
        if map.isEmpty && !map.usesSections { isDrawing = false }
        refreshTicks()
    }

    /// Changes the project's map, as one undo step, and gives what the
    /// change returned.
    @discardableResult
    private func edit<Result>(_ change: (inout BeatMap) -> Result) -> Result? {
        message = nil
        var result: Result?
        onEdit { map in result = change(&map) }
        return result
    }

    // MARK: Steps

    enum Step: Equatable {
        /// Nothing marked yet: one tempo, or sections.
        case chooseMode
        case drawSections
        case mark
    }

    var step: Step {
        if map.sections.isEmpty && !map.usesSections { return .chooseMode }
        return isDrawing || map.sections.isEmpty ? .drawSections : .mark
    }

    var selectedSection: BeatSection? { selectedSectionID.flatMap(map.section(id:)) }

    /// Whether any beat or anchor has been placed, which the tick needs.
    var hasBeats: Bool { map.sections.contains { !$0.beats.isEmpty } }

    func chooseOneTempo() {
        edit { [duration] map in map = .oneTempo(duration: duration) }
        isDrawing = false
        selectedSectionID = map.sections.first?.id
    }

    func chooseSections() {
        edit { map in map.usesSections = true }
        isDrawing = true
    }

    func finishDrawing() {
        isDrawing = false
        selectedSectionID = map.sections.first { $0.kind == .consistent && !$0.isConfirmed }?.id ?? map.sections.first?.id
    }

    func startOver() {
        edit { map in map = BeatMap() }
        isDrawing = false
        selectedSectionID = nil
        selectedBeat = nil
    }

    /// The next thing to do, for the panel's prompt.
    var instructions: String {
        switch step {
        case .chooseMode:
            return "Does the song keep one tempo all the way through? Pick Sections if it changes tempo, speeds up or slows down."
        case .drawSections:
            return "Pick a kind, then drag across the waveform to mark a section; double-click a gap to fill it. Drag an edge to move it, and near a neighbour it clicks in. Get the edges between sections close; the song's start and end needn't be exact."
        case .mark:
            break
        }
        guard let section = selectedSection else { return "Select a section to mark." }
        switch section.kind {
        case .none:
            return "This section isn't analyzed."
        case .ramp:
            if section.isConfirmed { return reviewHint }
            return "Fill the sections either side first, then Fill Ramp. At the start or end of the song, or beside an unmarked stretch, mark every beat of one measure at that end (M)."
        case .consistent:
            if section.isConfirmed { return reviewHint }
            switch section.pinnedBeats.count {
            case 0:
                return "Play the song and find a downbeat, beat 1 of a measure, near the middle of this section. Press M to drop an anchor at the playhead, or double-click the waveform."
            case 1:
                return "Line the tick up with the beat: ← → move the anchor 1 ms, with ⌥ one sample, with ⇧ 10 ms. Then place a second anchor well away from it, ideally near the far end of the section."
            default:
                return "Check both anchors by ear, then Fill Beats (Return)."
            }
        }
    }

    private var reviewHint: String {
        "Listen through. Drag a beat to move it, which pins it; double-click to add one; Delete removes the selected beat. Reanalyze keeps pinned beats and fits the rest to them."
    }

    // MARK: Filling

    /// The tempo of the selected section's beats, from their median gap.
    var selectedTempo: Double? {
        guard let section = selectedSection, section.isConfirmed,
              let gap = BeatFitting.medianGap(of: section.beats.map(\.time.seconds))
        else { return nil }
        return 60 / gap
    }

    /// Fills (or reanalyzes) the selected section, at `tempo` if given.
    func fillSelected(tempo: Double? = nil) {
        guard let audio, let id = selectedSectionID, !isFilling else { return }
        let map = self.map, duration = self.duration
        isFilling = true
        message = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BeatFitting.fill(map, section: id, curve: audio.curve, sampleRate: audio.sampleRate, duration: duration, tempo: tempo) }
            }.value
            isFilling = false
            switch result {
            case .success(let filled):
                edit { map in map = filled }
                selectNextToMark(after: id)
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    /// After a fill, the next consistent section to mark, then ramps.
    private func selectNextToMark(after id: UUID) {
        guard map.usesSections else { return }
        if let next = map.sections.first(where: { $0.kind == .consistent && !$0.isConfirmed })
            ?? map.sections.first(where: { $0.kind == .ramp && !$0.isConfirmed }) {
            selectedSectionID = next.id
        }
    }

    // MARK: Sections

    func drawSection(from: Double, to: Double, snap: Double) {
        let id = edit { [duration, drawKind] map in
            map.drawSection(drawKind, from: Self.time(from), to: Self.time(to), duration: duration, snap: Self.time(snap))
        }
        if let id = id ?? nil { selectedSectionID = id }
    }

    func fillGap(at seconds: Double) {
        let id = edit { [duration, drawKind] map in map.fill(at: Self.time(seconds), with: drawKind, duration: duration) }
        if let id = id ?? nil { selectedSectionID = id }
    }

    func moveEdge(_ edge: BeatMap.Edge, of id: UUID, to seconds: Double, snap: Double) {
        edit { [duration] map in map.moveEdge(edge, of: id, to: Self.time(seconds), duration: duration, snap: Self.time(snap)) }
    }

    /// Moves the selected section's edge to the playhead: the keyboard way
    /// to set an edge.
    func moveSelectedEdgeToPlayhead(_ edge: BeatMap.Edge) {
        guard let id = selectedSectionID else { return }
        moveEdge(edge, of: id, to: playhead, snap: 0)
    }

    func setKind(_ kind: BeatSection.Kind) {
        guard let id = selectedSectionID else { return }
        edit { map in map.setKind(of: id, to: kind) }
    }

    func setBeatsPerMeasure(_ count: Int) {
        guard let id = selectedSectionID else { return }
        edit { map in map.setBeatsPerMeasure(of: id, to: count) }
    }

    func setSteadiness(_ steadiness: BeatSection.Steadiness) {
        guard let id = selectedSectionID else { return }
        edit { map in map.updateSection(id) { $0.steadiness = steadiness } }
    }

    func deleteSelectedSection() {
        guard let id = selectedSectionID else { return }
        edit { map in map.removeSection(id) }
        selectedSectionID = nil
    }

    // MARK: Beats

    /// Drops a pinned beat (an anchor, before a section is filled) at a time.
    func addBeat(at seconds: Double) {
        let time = sampleTime(seconds)
        edit { map in map.addBeat(at: time, reach: CMTime(value: 1, timescale: 1)) }
        selectedBeat = time
        if let index = map.sectionIndex(containing: time) { selectedSectionID = map.sections[index].id }
    }

    func addBeatAtPlayhead() { addBeat(at: playhead) }

    func moveBeat(at time: CMTime, to seconds: Double) {
        let target = sampleTime(seconds)
        if let moved = edit({ map in map.moveBeat(at: time, to: target) }) ?? nil { selectedBeat = moved }
    }

    /// Moves the selected beat by `seconds`, landing on a sample.
    func nudgeSelected(by seconds: Double) {
        guard let beat = selectedBeat else { return }
        moveBeat(at: beat, to: beat.seconds + seconds)
    }

    /// One sample of the file, for the finest nudge.
    var sampleDuration: Double { 1 / (audio?.sampleRate ?? 48_000) }

    func deleteSelectedBeat() {
        guard let beat = selectedBeat else { return }
        edit { map in map.removeBeat(at: beat) }
        selectedBeat = nil
    }

    func setSelectedPosition(_ position: Int) {
        guard let beat = selectedBeat else { return }
        edit { map in map.setPosition(of: beat, to: position) }
    }

    func unpinSelected() {
        guard let beat = selectedBeat else { return }
        edit { map in map.unpin(at: beat) }
    }

    /// Selects the beat before or after the selected one (or the playhead),
    /// and moves the playhead a little before it, to hear it come.
    func selectBeat(step: Int) {
        let beats = map.sections.flatMap(\.beats).map(\.time)
        guard !beats.isEmpty else { return }
        let reference = selectedBeat?.seconds ?? playhead
        let target = step > 0
            ? beats.first { $0.seconds > reference + 1e-6 }
            : beats.last { $0.seconds < reference - 1e-6 }
        guard let target else { return }
        selectedBeat = target
        if let index = map.sectionIndex(containing: target) { selectedSectionID = map.sections[index].id }
        reveal(target.seconds)
    }

    var selectedMappedBeat: MappedBeat? { selectedBeat.flatMap(map.beat(at:)) }

    // MARK: Transport

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if playhead >= duration.seconds - 0.01 { seek(to: 0) }
            player.play()
        }
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration.seconds)
        playhead = clamped
        let fileTime = CMTimeAdd(CMTime(seconds: clamped, preferredTimescale: 48_000), alignment)
        player.seek(to: fileTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func playerMoved(to time: CMTime) {
        guard time.isNumeric else { return }
        playhead = CMTimeSubtract(time, alignment).seconds
        if isPlaying, let loop = loopRange, playhead >= loop.upperBound {
            seek(to: loop.lowerBound)
        }
        if isPlaying, playhead > visibleStart + Double(viewWidth) * secondsPerPoint || playhead < visibleStart {
            visibleStart = max(0, playhead - Double(viewWidth) * secondsPerPoint * 0.1)
        }
    }

    /// Two measures around the selected beat, while looping.
    var loopRange: ClosedRange<Double>? {
        guard isLooping, let beat = selectedBeat, let index = map.beatIndex(at: beat) else { return nil }
        let section = map.sections[index.section]
        let period = BeatFitting.medianGap(of: section.beats.map(\.time.seconds)) ?? 0.5
        let measure = period * Double(section.beatsPerMeasure)
        return max(0, beat.seconds - measure)...(beat.seconds + measure)
    }

    /// The tick plays on every beat, anchors included, at its time in the file.
    private func refreshTicks() {
        clicks.beats = map.sections.flatMap(\.beats).map {
            BeatClickPlayer.Tick(time: CMTimeAdd($0.time, alignment), isDownbeat: $0.isDownbeat)
        }
    }

    // MARK: Zoom

    /// Down to four points a sample.
    var closestZoom: Double { sampleDuration / 4 }
    var farthestZoom: Double { max(duration.seconds, 1) / Double(max(viewWidth, 100)) }

    func fit() {
        hasFitted = true
        secondsPerPoint = farthestZoom
        visibleStart = 0
    }

    /// Zooms by `factor` (above 1 zooms in) about a point `x` in the view.
    func zoom(by factor: Double, aboutX x: CGFloat) {
        let anchor = visibleStart + Double(x) * secondsPerPoint
        secondsPerPoint = min(max(secondsPerPoint / factor, closestZoom), farthestZoom)
        visibleStart = anchor - Double(x) * secondsPerPoint
        clampView()
    }

    func scroll(byPoints points: CGFloat) {
        visibleStart += Double(points) * secondsPerPoint
        clampView()
    }

    /// Zooms in on the selected beat, or the playhead, far enough to place
    /// a beat by eye.
    func zoomIn() { zoom(by: 2, aboutX: x(of: selectedBeat?.seconds ?? playhead)) }
    func zoomOut() { zoom(by: 0.5, aboutX: x(of: selectedBeat?.seconds ?? playhead)) }

    func x(of seconds: Double) -> CGFloat { CGFloat((seconds - visibleStart) / secondsPerPoint) }
    func seconds(atX x: CGFloat) -> Double { visibleStart + Double(x) * secondsPerPoint }

    private func reveal(_ seconds: Double) {
        let span = Double(viewWidth) * secondsPerPoint
        if seconds < visibleStart || seconds > visibleStart + span {
            visibleStart = seconds - span / 2
            clampView()
        }
    }

    private func clampView() {
        let span = Double(viewWidth) * secondsPerPoint
        visibleStart = min(max(visibleStart, -span * 0.05), max(0, duration.seconds - span * 0.95))
    }

    // MARK: Times

    /// Seconds as a time on a sample of the file.
    private func sampleTime(_ seconds: Double) -> CMTime {
        BeatFitting.time(seconds, sampleRate: audio?.sampleRate ?? 48_000)
    }

    nonisolated private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 48_000)
    }
}
