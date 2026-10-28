import AppKit
import AVFoundation
import CoreMedia
import Observation
import SwiftUI

/// One opening of the beat match panel for one song: its audio, a player
/// of its own that plays the song alone with the ticks, what is selected,
/// and the zoom. The panel works on a draft of the song's beat map, with
/// an undo history of its own; nothing reaches the project until the
/// person confirms. See docs/beat-matching.md.
@MainActor @Observable
final class BeatMatchSession: SecondsViewport {
    let assetID: UUID
    let assetName: String
    /// The song's editing time, in original time.
    let duration: CMTime
    /// Original time `t` is at `t + alignment` in the file.
    let alignment: CMTime

    private(set) var audio: BeatMatchAudio? {
        didSet { refreshProvisionalTempo() }
    }
    private(set) var loadProgress = 0.0
    private(set) var loadError: String?
    /// The draft being edited.
    private(set) var map: BeatMap
    /// The map as the project had it when the panel opened.
    let original: BeatMap
    /// Whether confirming would change the project.
    var isChanged: Bool { map != original }
    /// The panel's own undo history, for the draft.
    @ObservationIgnored let undoManager = UndoManager()
    /// Counts changes to the undo history, which isn't observable itself,
    /// so the undo and redo buttons follow it.
    private var undoRevision = 0
    /// Whether confirming is offered: once a section has its beats.
    var canConfirm: Bool { map.hasConfirmedBeats }
    /// Whether the draft was emptied (by Start Over) of what the project
    /// has, so confirming removes the song's beats.
    var removesBeats: Bool { map.isEmpty && !original.isEmpty }

    // MARK: Transport

    let player: AVPlayer
    let clicks: BeatClickPlayer
    /// Where the song is, in seconds of original time: where it was put,
    /// or where it stopped. While playing this stays put, so the panel
    /// isn't rebuilt on every tick; `livePlayhead` and the views that draw
    /// the moving playhead read the player itself.
    private(set) var playhead = 0.0
    private(set) var isPlaying = false
    /// Repeats the two measures around the selected beat.
    var isLooping = false {
        didSet { if isLooping != oldValue { refreshLoop() } }
    }
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
            secondsPerPoint = (secondsPerPoint * Double(oldValue / viewWidth)).clamped(between: closestZoom, and: farthestZoom)
            clampView()
        }
    }
    @ObservationIgnored private var hasFitted = false
    /// The zoom's edge: a zoom past the whole song, or closer than the
    /// closest, stretches the waveform and springs back (`RubberBandZoom`).
    var zoomBand = RubberBandZoom()
    /// The scroll's edge: past the song's start or end the waveform slides
    /// on and springs back. Only sideways, the one way it zooms.
    var scrollBand = RubberBandScroll()

    // MARK: Editing

    var selectedSectionID: UUID? {
        didSet { if selectedSectionID != oldValue { refreshProvisionalTempo() } }
    }
    /// The selected beat, by its time.
    var selectedBeat: CMTime? {
        didSet { if selectedBeat != oldValue { refreshLoop() } }
    }
    /// The kind a drawn or filled section gets.
    var drawKind: BeatSection.Kind = .consistent
    /// True while sections are being drawn, before they are marked.
    var isDrawing: Bool
    /// What went wrong with the last fill, or a hint, until the next edit.
    private(set) var message: String?
    /// What the person should know about the last fill, until the next edit.
    private(set) var fillHints: [String] = []
    private(set) var isFilling = false
    /// The tempo the onsets around the selected section's lone anchor
    /// suggest, shown before the second anchor is placed.
    private(set) var provisionalTempo: Double?

    /// Jumps back at the end of the loop, only while one plays.
    @ObservationIgnored private var loopObserver: Any?
    /// The loop `loopObserver` watches the end of.
    @ObservationIgnored private var activeLoop: ClosedRange<Double>?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The fill running off the main thread, which an edit to the draft
    /// cancels, since its result would replace the edit.
    @ObservationIgnored private var filling: Task<(map: BeatMap, report: BeatFitting.FillReport), Error>?
    @ObservationIgnored private var estimating: Task<Void, Never>?
    /// The section and anchor `provisionalTempo` is for.
    @ObservationIgnored private var estimated: ProvisionalKey?

    private struct ProvisionalKey: Hashable {
        var sectionID: UUID
        var pin: CMTime
        var start: CMTime
        var end: CMTime
    }

    init(asset: MediaClip, url: URL) {
        assetID = asset.id
        assetName = asset.name
        duration = asset.originalDuration ?? asset.duration
        alignment = asset.alignmentOffset
        map = asset.beatMap
        original = asset.beatMap
        isDrawing = asset.beatMap.usesSections && !asset.beatMap.sections.contains { !$0.pinnedBeats.isEmpty || $0.isConfirmed }
        // Given the song's audio once its tracks are read (`audioOnly`).
        player = AVPlayer()
        player.actionAtItemEnd = .pause
        undoManager.levelsOfUndo = Self.undoLevels
        clicks = BeatClickPlayer(player: player)
        // Out of the devices chosen in Settings, like the editor's sound.
        player.audioOutputDeviceUniqueID = AudioDevices.playbackUID
        clicks.outputDeviceUID = AudioDevices.clicksUID
        clicks.isEnabled = true
        midi = MIDITaps { [weak self] hostTime in self?.addBeat(atHostTime: hostTime) }
        player.volume = Float(songVolume)
        selectedSectionID = asset.beatMap.sections.first { $0.kind == .consistent && !$0.isConfirmed }?.id
            ?? asset.beatMap.sections.first?.id

        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.playingChanged(playing) }
        }
        refreshTicks()
        loading = Task { [weak self] in
            do {
                let song = try await Self.audioOnly(url: url)
                // Reading tracks doesn't stop when the session ends.
                try Task.checkCancellation()
                self?.player.replaceCurrentItem(with: AVPlayerItem(asset: song))
                // Put where it was put while the tracks were read.
                if let self, playhead > 0 { seek(to: playhead) }
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
        filling?.cancel()
        estimating?.cancel()
        player.pause()
        clicks.isEnabled = false
        if let loopObserver { player.removeTimeObserver(loopObserver) }
        loopObserver = nil
        activeLoop = nil
        statusObservation = nil
    }

    /// The file's audio alone, at the file's own times, for the player, so
    /// a video's picture is never decoded: the tracks it plays by default,
    /// or the first if it has none on. Made off the main thread, since
    /// putting tracks in a composition reads them there and then.
    nonisolated private static func audioOnly(url: URL) async throws -> sending AVMutableComposition {
        let asset = MediaFile.asset(at: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var played: [AVAssetTrack] = []
        for track in tracks {
            if try await track.load(.isEnabled) { played.append(track) }
        }
        if played.isEmpty { played = Array(tracks.prefix(1)) }
        guard !played.isEmpty else { throw BeatDetector.DetectionError.noAudioTrack }
        let composition = AVMutableComposition()
        for track in played {
            let range = try await track.load(.timeRange)
            let part = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try part?.insertTimeRange(range, of: track, at: range.start)
        }
        return composition
    }

    /// Puts the draft back to `map`, as an undo or redo does, and makes
    /// the reverse undoable.
    private func restore(_ map: BeatMap) {
        let current = self.map
        self.map = map
        nudgeRun = nil
        undoManager.registerUndo(withTarget: self) { $0.restore(current) }
        undoRevision += 1
        mapChanged()
    }

    var canUndo: Bool {
        _ = undoRevision
        return undoManager.canUndo && !isFilling
    }

    var canRedo: Bool {
        _ = undoRevision
        return undoManager.canRedo && !isFilling
    }

    /// Undoes the last change to the draft; not while a fill is running,
    /// whose result would land on the undone map.
    func undo() {
        guard canUndo else { return }
        undoManager.undo()
        undoRevision += 1
    }

    func redo() {
        guard canRedo else { return }
        undoManager.redo()
        undoRevision += 1
    }

    /// Keeps the selection and ticks in step with the draft.
    private func mapChanged() {
        if let id = selectedSectionID, map.section(id: id) == nil { selectedSectionID = map.sections.first?.id }
        // A lone section needs no choosing, except while drawing, where
        // picking a kind would then change it.
        if selectedSectionID == nil, map.sections.count == 1, !isDrawing { selectedSectionID = map.sections[0].id }
        if let beat = selectedBeat, map.beat(at: beat) == nil { selectedBeat = nil }
        if map.isEmpty && !map.usesSections { isDrawing = false }
        refreshTicks()
        refreshProvisionalTempo()
        refreshLoop()
    }

    /// Changes the draft at once, as one undo step, and gives what the
    /// change returned. Being in place, a nudge or drop never shows the
    /// old map for a frame. `joiningLastStep` folds the change into the
    /// undo step before it instead, for a run of nudges.
    @discardableResult
    private func edit<Result>(joiningLastStep: Bool = false, _ change: (inout BeatMap) -> Result) -> Result {
        nudgeRun = nil
        message = nil
        fillHints = []
        if let filling {
            filling.cancel()
            self.filling = nil
            isFilling = false
        }
        let before = map
        let result = change(&map)
        if map != before {
            if !joiningLastStep {
                undoManager.registerUndo(withTarget: self) { $0.restore(before) }
                undoRevision += 1
            }
            mapChanged()
        }
        return result
    }

    /// The song's own level in the panel, apart from the timeline's mix.
    nonisolated static let songVolumeKey = "beatMatchSongVolume"

    var songVolume = UserDefaults.standard.object(forKey: BeatMatchSession.songVolumeKey) as? Double ?? 1 {
        didSet {
            player.volume = Float(songVolume)
            UserDefaults.standard.set(songVolume, forKey: Self.songVolumeKey)
        }
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
        selectSection(map.sections.first { $0.kind == .consistent && !$0.isConfirmed }?.id ?? map.sections.first?.id)
    }

    /// Switches to a section from the panel rather than the waveform, and
    /// scrolls it into view.
    func selectSection(_ id: UUID?) {
        selectedSectionID = id
        if let id { reveal(section: id) }
    }

    func startOver() {
        edit { map in map = BeatMap() }
        isDrawing = false
        selectedSectionID = nil
        selectedBeat = nil
    }

    /// The next thing to do, for the panel's prompt.
    /// What the panel asks for next: one line on the step, and the ways
    /// to do it, shown as a list under it so the line stays readable.
    struct Guidance: Equatable {
        var lead: String
        var tips: [String] = []
    }

    var guidance: Guidance {
        switch step {
        case .chooseMode:
            return Guidance(lead: "Does the song keep one tempo all the way through?", tips: [
                "Pick Sections if it changes tempo, speeds up or slows down.",
            ])
        case .drawSections:
            return Guidance(lead: "Mark the song's sections.", tips: [
                "Pick a kind, then drag across the waveform. Double-click a gap to fill it.",
                "Or play the song and press M where each section ends: it marks back to the section before.",
                "Click a section to select it; picking a kind then changes it. Drag an edge to move it.",
                "Edges snap to the next section, to beats and to the playhead. Get the edges between sections close; the song's start and end needn't be exact.",
                "Continue when the sections are marked.",
            ])
        case .mark:
            break
        }
        guard let section = selectedSection else { return Guidance(lead: "Select a section to mark.") }
        switch section.kind {
        case .none:
            return Guidance(lead: "This section isn't analyzed.")
        case .ramp:
            if section.isConfirmed { return reviewGuidance }
            return Guidance(lead: "Fill the sections either side first, then Fill Ramp.", tips: [
                "At the start or end of the song, or beside an unmarked stretch, mark every beat of one measure at that end (M).",
            ])
        case .consistent:
            if section.isConfirmed { return reviewGuidance }
            switch section.pinnedBeats.count {
            case 0:
                var tips = [
                    "Play the song and press M on a downbeat, or double-click the waveform.",
                    "While it plays, taps of M in a row count on through the measure.",
                ]
                if copiedDetails != nil {
                    tips.append("If it keeps the tempo you copied, paste it (⌘V): the section's start is taken as beat 1.")
                }
                return Guidance(lead: "Find a downbeat, beat 1 of a measure, near the middle of this section.", tips: tips)
            case 1:
                var tips = [
                    "← → move the anchor 1 ms, with ⌥ one sample, with ⇧ 10 ms.",
                    "Put the second anchor near the far end of the section.",
                ]
                if let tempo = provisionalTempo {
                    tips.insert("The music around it sounds like about \(Int(tempo.rounded())) BPM.", at: 0)
                }
                return Guidance(lead: "Line the tick up with the beat, then place a second anchor well away from it.", tips: tips)
            default:
                return Guidance(lead: "Check both anchors by ear, then Fill Beats (Return).")
            }
        }
    }

    private var reviewGuidance: Guidance {
        Guidance(lead: "Listen through and correct any beat.", tips: [
            "Drag a beat to move it, which pins it. Double-click to add one; Delete removes the selected beat.",
            "Reanalyze keeps pinned beats and fits the rest to them.",
        ])
    }

    // MARK: Filling

    /// Doubles the selected section's tempo by putting a beat between each
    /// two; see `BeatFitting.doubled`.
    func doubleTempo() {
        guard let audio, let id = selectedSectionID else { return }
        edit { map in
            map.updateSection(id) { $0 = BeatFitting.doubled($0, curve: audio.curve, sampleRate: audio.sampleRate) }
            map.recountPositions()
        }
    }

    /// Halves the selected section's tempo by keeping every other beat.
    func halveTempo() {
        guard let id = selectedSectionID else { return }
        edit { map in
            map.updateSection(id) { $0 = BeatFitting.halved($0) }
            map.recountPositions()
        }
    }

    var canHalveTempo: Bool { selectedSection.map { BeatFitting.halvingParity(of: $0) != nil } ?? false }
    var canDoubleTempo: Bool { (selectedTempo ?? .infinity) * 2 <= BeatFitting.fastestDoubled }

    /// The tempo of the selected section's beats, from their median gap.
    var selectedTempo: Double? {
        guard let section = selectedSection, section.isConfirmed,
              let gap = BeatFitting.medianGap(of: section.beats.map(\.time.seconds))
        else { return nil }
        return 60 / gap
    }

    /// Fills (or reanalyzes) the selected section, at `tempo` if given.
    func fillSelected(tempo: Double? = nil) {
        guard let id = selectedSectionID else { return }
        fill(map, section: id, tempo: tempo)
    }

    /// Fills section `id` of `map` off the main thread, then makes the
    /// draft the result, as one undo step. A fill already running is
    /// cancelled for this one.
    private func fill(_ map: BeatMap, section id: UUID, tempo: Double?) {
        guard let audio else { return }
        filling?.cancel()
        let duration = self.duration
        isFilling = true
        message = nil
        fillHints = []
        let work = Task.detached(priority: .userInitiated) {
            try BeatFitting.fillReporting(map, section: id, curve: audio.curve, sampleRate: audio.sampleRate, duration: duration, tempo: tempo)
        }
        filling = work
        Task {
            let result = await work.result
            // A later fill, or an edit to the draft, took over.
            guard filling == work else { return }
            filling = nil
            isFilling = false
            switch result {
            case .success(let filled):
                // In one assignment, so the waveform never shows half a fill.
                edit { map in map = filled.map }
                fillHints = Self.hints(for: filled.report)
                selectNextToMark(after: id)
            case .failure(is CancellationError):
                break
            case .failure(let error):
                message = Self.describe(error)
            }
        }
    }

    /// A failure as the panel shows it: what went wrong, then what to do.
    static func describe(_ error: Error) -> String {
        guard let error = error as? LocalizedError, let suggestion = error.recoverySuggestion else { return error.localizedDescription }
        return [error.errorDescription ?? error.localizedDescription, suggestion].joined(separator: " ")
    }

    /// What a fill did that the person might not expect, in their words.
    static func hints(for report: BeatFitting.FillReport) -> [String] {
        var hints: [String] = []
        if report.measureOverruledOnsets {
            hints.append("The anchors' places in the measure settled how many beats lie between them. If the beats drift off the music, check which beat each anchor is on.")
        }
        if report.beatCount > 0, report.quietBeats * 4 > report.beatCount {
            hints.append("\(report.quietBeats) of \(report.beatCount) beats looked quiet here, with no clear onset to snap to, so they keep the grid. Listen through them.")
        }
        if report.droppedSilentBeats > 0 {
            hints.append("The music stops before the section's edge, so the beats stop with it.")
        }
        switch report.edges {
        case .unchanged: break
        case .moved: hints.append("The section's edges snapped to its first beat and to the beat after its last.")
        case .tooShort: hints.append("The section's edges stayed put: its beats left no room to snap them to.")
        }
        return hints
    }

    /// Works out `provisionalTempo` for the selected section, a moment
    /// after its lone anchor stops moving.
    private func refreshProvisionalTempo() {
        guard let audio, let section = selectedSection, section.kind == .consistent, !section.isConfirmed else {
            return clearProvisionalTempo()
        }
        let pins = BeatFitting.distinctPins(of: section, sampleRate: audio.sampleRate)
        guard pins.count == 1, let pin = pins.first else { return clearProvisionalTempo() }
        let key = ProvisionalKey(sectionID: section.id, pin: pin.time, start: section.start, end: section.end)
        guard key != estimated else { return }
        estimated = key
        estimating?.cancel()
        provisionalTempo = nil
        estimating = Task { [weak self] in
            // Nudging an anchor moves it many times a second.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let tempo = await Task.detached(priority: .userInitiated) {
                (try? BeatFitting.provisionalTempo(around: pin.time.seconds, in: section, curve: audio.curve)) ?? nil
            }.value
            guard !Task.isCancelled else { return }
            self?.provisionalTempo = tempo
        }
    }

    private func clearProvisionalTempo() {
        estimating?.cancel()
        estimated = nil
        if provisionalTempo != nil { provisionalTempo = nil }
    }

    // MARK: Copy and paste

    /// What was copied from a filled consistent section, to paste on others.
    private(set) var copiedDetails: BeatSectionDetails?

    /// The selected section's details, when it is a filled consistent one.
    var selectedDetails: BeatSectionDetails? {
        guard let section = selectedSection, section.kind == .consistent, let tempo = selectedTempo else { return nil }
        return BeatSectionDetails(
            tempo: tempo, beatsPerMeasure: section.beatsPerMeasure,
            isMeasureSet: section.isMeasureSet, steadiness: section.steadiness
        )
    }

    func copyDetails() {
        guard let details = selectedDetails else { return }
        copiedDetails = details
    }

    var canPasteDetails: Bool {
        copiedDetails != nil && selectedSection?.kind == .consistent && audio != nil && !isFilling
    }

    /// Fills the selected consistent section at the copied tempo, its start
    /// taken as beat 1, with the copied beats per measure and steadiness.
    func pasteDetails() {
        guard canPasteDetails, let details = copiedDetails, let id = selectedSectionID else { return }
        var prepared = map
        guard prepared.paste(details, into: id) else { return }
        fill(prepared, section: id, tempo: details.tempo)
    }

    /// After a fill, the next consistent section to mark, then ramps. The
    /// view stays where it is, on the beats just filled.
    private func selectNextToMark(after id: UUID) {
        guard map.usesSections else { return }
        if let next = map.sections.first(where: { $0.kind == .consistent && !$0.isConfirmed })
            ?? map.sections.first(where: { $0.kind == .ramp && !$0.isConfirmed }) {
            selectedSectionID = next.id
        }
    }

    // MARK: Sections

    /// Draws a section of the chosen kind, selected; see
    /// `BeatMap.drawSection`. Picking a kind then changes it once.
    func drawSection(from: Double, to: Double, in gapAt: Double? = nil, snap: Double) {
        let id = edit { [duration, drawKind] map in
            map.drawSection(
                drawKind, from: Self.time(from), to: Self.time(to), in: gapAt.map(Self.time),
                duration: duration, snap: Self.time(snap)
            )
        }
        if let id { selectDrawn(id) }
    }

    /// M while drawing: marks the unmarked stretch up to the playhead with
    /// the chosen kind, back to the section before it, and selects it.
    func drawSectionToPlayhead() {
        let id = edit { [duration, drawKind, livePlayhead] map in
            map.drawSection(drawKind, upTo: Self.time(livePlayhead), duration: duration)
        }
        if let id {
            selectDrawn(id)
        } else {
            message = "The playhead is in a section already, or too close to the one before it."
        }
    }

    private func selectDrawn(_ id: UUID) {
        selectedSectionID = id
        selectedBeat = nil
    }

    /// The map as drawing a section would leave it, for the drag's preview,
    /// and the drawn section's ID; nil without room.
    func drawingPreview(from: Double, to: Double, in gapAt: Double) -> (map: BeatMap, id: UUID)? {
        var preview = map
        guard let id = preview.drawSection(
            drawKind, from: Self.time(from), to: Self.time(to), in: Self.time(gapAt), duration: duration, snap: .zero
        ) else { return nil }
        return (preview, id)
    }

    /// The map as Option-dragging section `id` to start at `seconds` would
    /// leave it, for the drag's preview, and the copy's ID; nil without
    /// room.
    func copyPreview(of id: UUID, toStart seconds: Double) -> (map: BeatMap, id: UUID)? {
        var preview = map
        guard let copied = preview.copySection(id, to: Self.time(seconds), duration: duration) else { return nil }
        return (preview, copied)
    }

    /// Option-dragging a section: a copy of it starting at `seconds`
    /// (`BeatMap.copySection`), selected. A filled consistent section's
    /// copy is filled at its tempo, as Paste fills one: from the beats
    /// pinned in it, or else from its start as beat 1.
    func copySection(_ id: UUID, toStart seconds: Double) {
        guard let source = map.section(id: id) else { return }
        var copied = map
        guard let copyID = copied.copySection(id, to: Self.time(seconds), duration: duration) else { return }
        let tempo = source.kind == .consistent && source.isConfirmed
            ? BeatFitting.medianGap(of: source.beats.map(\.time.seconds)).map { 60 / $0 }
            : nil
        selectedBeat = nil
        if let tempo, audio != nil, !isFilling {
            if copied.section(id: copyID)?.beats.isEmpty == true {
                copied.paste(BeatSectionDetails(
                    tempo: tempo, beatsPerMeasure: source.beatsPerMeasure,
                    isMeasureSet: source.isMeasureSet, steadiness: source.steadiness
                ), into: copyID)
            }
            selectSection(copyID)
            fill(copied, section: copyID, tempo: tempo)
        } else {
            edit { map in map = copied }
            selectSection(copyID)
        }
    }

    /// The map as moving an edge would leave it, for the drag's preview.
    func edgePreview(_ edge: BeatMap.Edge, of id: UUID, to seconds: Double) -> BeatMap {
        var preview = map
        preview.moveEdge(edge, of: id, to: Self.time(seconds), duration: duration, snap: .zero)
        return preview
    }

    /// Fills the gap at `seconds`, selecting the new section; inside a
    /// section, changes its kind as picking one does.
    func fillGap(at seconds: Double) {
        let time = Self.time(seconds)
        if let index = map.sectionIndex(containing: time) {
            selectedSectionID = map.sections[index].id
            return chooseKind(drawKind)
        }
        let id = edit { [duration, drawKind] map in map.fill(at: time, with: drawKind, duration: duration) }
        if let id { selectDrawn(id) }
    }

    /// The kind picker: sets what is drawn next and, with a section
    /// selected, changes that section to it and lets go of it, so the
    /// next pick only sets what is drawn next.
    func chooseKind(_ kind: BeatSection.Kind) {
        drawKind = kind
        guard let section = selectedSection else { return }
        if section.kind != kind { setKind(kind) }
        if step == .drawSections { selectedSectionID = nil }
    }

    func moveEdge(_ edge: BeatMap.Edge, of id: UUID, to seconds: Double, snap: Double) {
        edit { [duration] map in map.moveEdge(edge, of: id, to: Self.time(seconds), duration: duration, snap: Self.time(snap)) }
    }

    /// Moves the selected section's edge to the playhead: the keyboard way
    /// to set an edge.
    func moveSelectedEdgeToPlayhead(_ edge: BeatMap.Edge) {
        guard let id = selectedSectionID else { return }
        moveEdge(edge, of: id, to: livePlayhead, snap: 0)
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

    /// Drops a pinned beat (an anchor, before a section is filled) at a
    /// time, at `position` in the measure if given. Gives the beat as
    /// numbered in its section, and the section's ID.
    @discardableResult
    func addBeat(at seconds: Double, position: Int? = nil) -> (section: UUID, beat: MappedBeat)? {
        let time = sampleTime(seconds)
        let added = edit { map in map.addBeat(at: time, reach: CMTime(value: 1, timescale: 1), position: position) }
        selectedBeat = time
        guard let added else {
            if let index = map.sectionIndex(containing: time) { selectedSectionID = map.sections[index].id }
            return nil
        }
        let section = map.sections[added.section].id
        selectedSectionID = section
        return (section, added.beat)
    }

    /// The beats tapped in a row with M while the song plays: their
    /// section, the last one's place in the measure, and its time.
    private struct TapRun {
        var section: UUID
        var position: Int
        var seconds: Double
    }
    @ObservationIgnored private var tapRun: TapRun?
    /// Taps on MIDI pads and keys, while the session is open.
    @ObservationIgnored private var midi: MIDITaps?
    /// Taps further apart than this, in seconds, start a new run.
    static let longestTapGap = 4.0

    /// M: drops a beat where the song is. While it plays, each tap in a
    /// row counts on through the section's measure, 1, 2, 3, 4, 1…, so
    /// the beats can be tapped along with the music, in ramps as well.
    /// A run starts again after a pause, a seek, a gap or a new section;
    /// its first tap numbers as any added beat does.
    func addBeatAtPlayhead() {
        tap(at: livePlayhead)
    }

    /// A note played on a MIDI pad or key at `hostTime`: as M, but where
    /// the song was when it was played rather than when it was handled.
    func addBeat(atHostTime hostTime: UInt64) {
        guard isPlaying, let timebase = player.currentItem?.timebase else { return addBeatAtPlayhead() }
        let played = CMSyncConvertTime(CMClockMakeHostTimeFromSystemUnits(hostTime), from: CMClockGetHostTimeClock(), to: timebase)
        guard played.isNumeric else { return addBeatAtPlayhead() }
        tap(at: CMTimeSubtract(played, alignment).seconds)
    }

    private func tap(at seconds: Double) {
        guard isPlaying else {
            addBeat(at: seconds)
            return
        }
        let time = sampleTime(seconds)
        var position: Int?
        if let run = tapRun, let index = map.sectionIndex(containing: time), map.sections[index].id == run.section,
           seconds > run.seconds, seconds - run.seconds <= Self.longestTapGap {
            position = run.position.modulo(map.sections[index].beatsPerMeasure) + 1
        }
        if let added = addBeat(at: seconds, position: position) {
            tapRun = TapRun(section: added.section, position: added.beat.position, seconds: seconds)
        }
    }

    func moveBeat(at time: CMTime, to seconds: Double) {
        let target = sampleTime(seconds)
        if let moved = edit({ map in map.moveBeat(at: time, to: target) }) { selectedBeat = moved }
    }

    /// Option-dragging a beat: a pinned copy at `seconds`, in the beat's
    /// place in the measure; the beat stays. The copy is selected.
    func copyBeat(at time: CMTime, to seconds: Double) {
        let target = sampleTime(seconds)
        if let copied = edit({ map in map.copyBeat(at: time, to: target) }) {
            selectedBeat = copied
        }
    }

    /// Moves the selected beat by `seconds`, landing on a sample.
    /// Nudges of one beat in a row, each soon after the last (an arrow
    /// key held, or pressed again and again), undo as one step.
    func nudgeSelected(by seconds: Double) {
        guard let beat = selectedBeat else { return }
        let now = ContinuousClock.now
        let continues = nudgeRun.map { $0.beat == beat && now - $0.at <= Self.nudgeRunGap } ?? false
        let target = sampleTime(beat.seconds + seconds)
        guard let moved = edit(joiningLastStep: continues, { map in map.moveBeat(at: beat, to: target) }) else { return }
        selectedBeat = moved
        nudgeRun = (moved, now)
    }

    /// The beat the last nudge left, and when, while nudges run on.
    @ObservationIgnored private var nudgeRun: (beat: CMTime, at: ContinuousClock.Instant)?
    /// Longer than the wait before a held key repeats, so holding one is
    /// one run: from 300 ms, up to a second for the longest waits.
    private static var nudgeRunGap: Duration { .seconds((NSEvent.keyRepeatDelay + 0.1).clamped(between: 0.3, and: 1)) }
    /// Steps of the draft's undo history kept; each holds a whole map.
    static let undoLevels = 100

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

    /// Puts the selected beat back where the person placed it, before a
    /// fill snapped it onto its onset.
    func undoSnap() {
        guard let beat = selectedBeat else { return }
        if let restored = edit({ map in map.undoSnap(at: beat) }) { selectedBeat = restored }
    }

    /// Lets the selected beat snap onto its onset again, after Undo Snap.
    func snapAgain() {
        guard let audio, let beat = selectedBeat else { return }
        let snapped = edit { map -> CMTime? in
            guard let result = BeatFitting.snapAgain(map, at: beat, curve: audio.curve, sampleRate: audio.sampleRate) else { return nil }
            map = result.map
            return result.time
        }
        if let snapped { selectedBeat = snapped }
    }

    func unpinSelected() {
        guard let beat = selectedBeat else { return }
        edit { map in map.unpin(at: beat) }
    }

    /// Selects the beat before or after the selected one (or the playhead),
    /// and moves the playhead a little before it, to hear it come.
    func selectBeat(step: Int) {
        let reference = selectedBeat?.seconds ?? livePlayhead
        // Sections and their beats are in time order, so only the section
        // the next beat is in needs looking through.
        let found: (section: UUID, time: CMTime)?
        if step > 0 {
            let section = map.sections.first { ($0.beats.last?.time.seconds ?? -.infinity) > reference + 1e-6 }
            found = section.flatMap { section in
                section.beats.first { $0.time.seconds > reference + 1e-6 }.map { (section.id, $0.time) }
            }
        } else {
            let section = map.sections.last { ($0.beats.first?.time.seconds ?? .infinity) < reference - 1e-6 }
            found = section.flatMap { section in
                section.beats.last { $0.time.seconds < reference - 1e-6 }.map { (section.id, $0.time) }
            }
        }
        guard let (section, target) = found else { return }
        selectedBeat = target
        selectedSectionID = section
        reveal(target.seconds)
    }

    var selectedMappedBeat: MappedBeat? { selectedBeat.flatMap(map.beat(at:)) }

    // MARK: Transport

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            // Not before the song's audio is read: with nothing to play
            // the player would wait, and seem to play.
            guard player.currentItem != nil else { return }
            playhead = playerSeconds()
            if playhead >= duration.seconds - 0.01 { seek(to: 0) }
            player.play()
        }
    }

    func seek(to seconds: Double) {
        var clamped = seconds.clamped(between: 0, and: duration.seconds)
        // Past the end of a playing loop is back at its start, as it would
        // be a moment later.
        if isPlaying, let loop = activeLoop, clamped >= loop.upperBound { clamped = loop.lowerBound }
        playhead = clamped
        tapRun = nil
        let fileTime = CMTimeAdd(CMTime(seconds: clamped, preferredTimescale: 48_000), alignment)
        player.seek(to: fileTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Watches for the end of the loop while one plays, and for nothing
    /// otherwise, so no time observer runs on the main thread the rest of
    /// the time. The loop is worked out here, when what it depends on
    /// changes, rather than as the song plays. The view doesn't follow the
    /// playhead: the person browses the song and clicks where to hear.
    private func refreshLoop() {
        let loop = isPlaying ? loopRange : nil
        guard loop != activeLoop else { return }
        if let loopObserver { player.removeTimeObserver(loopObserver) }
        loopObserver = nil
        activeLoop = loop
        guard let loop else { return }
        let end = CMTimeAdd(CMTime(seconds: loop.upperBound, preferredTimescale: 48_000), alignment)
        loopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: end)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let loop = self.activeLoop else { return }
                self.seek(to: loop.lowerBound)
            }
        }
        // Already past its end, which the boundary would never see.
        if playerSeconds() >= loop.upperBound { seek(to: loop.lowerBound) }
    }

    private func playingChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        tapRun = nil
        if !playing { playhead = playerSeconds() }
        refreshLoop()
    }

    /// Where the song is now, playing or not.
    var livePlayhead: Double { isPlaying ? playerSeconds() : playhead }

    /// Where the song will be at `date`, for drawing a frame that is shown
    /// then: the player's time now, carried on to the frame's time.
    func playhead(at date: Date) -> Double {
        guard isPlaying else { return playhead }
        let ahead = date.timeIntervalSinceNow.clamped(between: 0, and: 0.05)
        return min(playerSeconds() + ahead * Double(player.rate), duration.seconds)
    }

    private func playerSeconds() -> Double {
        let time = player.currentTime()
        return time.isNumeric ? CMTimeSubtract(time, alignment).seconds : playhead
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

    /// The waveform shows the song: nothing past either end.
    var viewBounds: (start: Double, end: Double) { (0, duration.seconds) }
    /// Zooming in zooms about the selected beat, or the playhead, far
    /// enough to place a beat by eye.
    var zoomFocus: Double { selectedBeat?.seconds ?? livePlayhead }

    private func reveal(_ seconds: Double) {
        let span = Double(viewWidth) * secondsPerPoint
        if seconds < visibleStart || seconds > visibleStart + span {
            visibleStart = seconds - span / 2
            clampView()
        }
    }

    /// Scrolls a section into view, centred if it fits and from its start
    /// if not; one already in view stays where it is.
    private func reveal(section id: UUID) {
        guard let section = map.section(id: id) else { return }
        let span = Double(viewWidth) * secondsPerPoint
        let start = section.start.seconds, length = section.end.seconds - start
        guard start < visibleStart || start + length > visibleStart + span else { return }
        visibleStart = length <= span * 0.9 ? start - (span - length) / 2 : start - span * 0.05
        clampView()
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
