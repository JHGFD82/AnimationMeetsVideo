import AppKit
import CoreMedia
import Observation
import SwiftUI

/// The scene splitter: a floating panel for splitting an asset's scenes
/// and merging them, by hand at a frame or by the cut sensitivity of a
/// stretch. It shows what is selected in the browser, as an inspector
/// does, and follows it. Every change is made at once as its own undo
/// step, and the timeline clips cut from those scenes are split and joined
/// with them (`EditingProject.followSceneCuts`); a change that would put
/// animated clips into timelines of their own asks first. See
/// docs/scene-cuts.md, "The scene splitter".
@MainActor
@Observable
final class SceneSplitter {
    /// What the splitter shows: a stretch of an asset's original time,
    /// filled out to the scenes that overlap it, so splitting or merging
    /// inside it never moves the view.
    struct Focus: Equatable {
        var assetID: UUID
        var start: CMTime
        var end: CMTime
    }

    /// A change that would put clips into timelines of their own, waiting
    /// for the person to agree to it.
    struct PendingEdit: Identifiable {
        let id = UUID()
        var clipCount: Int
        var change: (inout SceneEdits) -> Void
    }

    enum Side { case previous, next }

    private(set) var project = EditingProject.empty
    private(set) var focus: Focus?
    private(set) var isOpen = false
    /// Every scene of the focused asset, with the sensitivity being
    /// dragged applied when there is one.
    private(set) var allScenes: [SceneRange] = []
    /// The scenes that overlap the focus, in order.
    private(set) var scenes: [SceneRange] = []
    /// Each scene's index in `allScenes`, by ID, worked out once per
    /// refresh: a scene's ID is a string made each time it is asked for,
    /// so finding one by searching was a cost paid at every redraw.
    @ObservationIgnored private var indexByID: [String: Int] = [:]
    /// The scenes picked in the panel, by ID, which Merge joins. Seeded
    /// from the browser's picks.
    private(set) var selection = BrowserSelection<String>()
    /// The marker: the frame last clicked or stepped to, in the asset's
    /// original time. Skimming shows other frames without moving it; only
    /// a click, the arrow keys and playing do. Never saved.
    private(set) var marker: CMTime?
    /// Where the pointer is skimming, in seconds into the stretch shown;
    /// nil when it isn't over the strip.
    private(set) var skimming: Double?
    /// How far the strip is zoomed in: 1 fits the whole stretch.
    private(set) var zoom: Double = 1
    var pendingEdit: PendingEdit?
    /// The sensitivity under the pointer while its slider is dragged:
    /// shown, not applied until it is let go.
    private(set) var draftSensitivity: Double?
    /// Whether skimming and playing are heard. Kept between sessions.
    var isSoundOn: Bool {
        didSet {
            UserDefaults.standard.set(isSoundOn, forKey: Preferences.sceneSplitterSound)
            skim.soundOverride = isSoundOn
        }
    }

    /// Its own player and sound grains, so the viewer and the browser's
    /// skimming are left alone.
    let skim = BrowserSkim()
    /// The detected scores of each asset (`AssetAnalysis.tracks`).
    @ObservationIgnored var sceneTracks: () -> [UUID: ChangeScoreTrack] = { [:] }
    @ObservationIgnored var onEdit: ((inout EditingProject) -> Void) -> Void = { _ in }
    /// How wide the strip is on screen, which sets how far it can zoom.
    @ObservationIgnored var stripWidth: CGFloat = 560
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    private static let skimItem = AnyHashable("sceneSplitter")
    /// The most the strip zooms in to: this many points a frame.
    static let widestFrame: Double = 24

    init() {
        isSoundOn = UserDefaults.standard.object(forKey: Preferences.sceneSplitterSound) as? Bool ?? true
        skim.soundOverride = isSoundOn
    }

    // MARK: - What it shows

    var media: MediaClip? { focus.flatMap { project.mediaClip(id: $0.assetID) } }
    var track: ChangeScoreTrack? { focus.flatMap { sceneTracks()[$0.assetID] } }

    /// From the start of the first scene shown to the end of the last.
    var span: (start: CMTime, end: CMTime)? { scenes.span }

    /// How long the stretch shown lasts, in seconds.
    var length: Double {
        guard let span else { return 0 }
        return max(CMTimeSubtract(span.end, span.start).seconds, 0)
    }

    var frameRate: Double {
        guard let rate = media?.frameRate, rate > 0 else { return 30 }
        return rate
    }

    private var isPlaying: Bool { skim.isPlaying && skim.target?.item == Self.skimItem }

    /// The marker in seconds into the stretch; while playing, where play
    /// has reached, since the marker rides along.
    var markerSeconds: Double? {
        if isPlaying { return skim.seconds }
        guard let span, let marker else { return nil }
        return CMTimeSubtract(marker, span.start).seconds
    }

    /// The frame the picture shows, in seconds into the stretch: the one
    /// skimmed to, else the marker's.
    var shownSeconds: Double? {
        isPlaying ? markerSeconds : (skimming ?? markerSeconds)
    }

    func time(atSeconds seconds: Double) -> CMTime {
        CMTimeAdd(span?.start ?? .zero, CMTime(seconds: seconds, preferredTimescale: 6000))
    }

    var markerTime: CMTime? { markerSeconds.map(time(atSeconds:)) }

    /// The scene a moment is in; the last one for the very end.
    func scene(at time: CMTime) -> SceneRange? {
        scenes.last { CMTimeCompare($0.start, time) <= 0 } ?? scenes.first
    }

    /// A scene's number among all of its asset's, as the browser counts.
    func number(of scene: SceneRange) -> Int? {
        indexByID[scene.id].map { $0 + 1 }
    }

    /// The sensitivity the slider shows: the one being dragged, or the one
    /// in force at the middle of the stretch.
    var sensitivity: Double {
        if let draftSensitivity { return draftSensitivity }
        guard let span, let edits = media?.sceneEdits else { return project.defaultSensitivity }
        let middle = CMTimeMultiplyByRatio(CMTimeAdd(span.start, span.end), multiplier: 1, divisor: 2)
        return SceneDetector.sensitivity(at: middle, defaultSensitivity: project.defaultSensitivity, edits: edits)
    }

    // MARK: - Opening

    /// Opens the panel on `focus` with `selecting` (scene IDs) picked, or
    /// brings it to the front.
    func show(_ focus: Focus?, selecting ids: [String] = []) {
        if let focus { setFocus(focus, selecting: ids) }
        if let panel {
            refresh()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scene Splitter"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        // Resized freely down to what its controls need; the picture takes
        // the room.
        let host = NSHostingView(rootView: SceneSplitterView(splitter: self))
        host.sizingOptions = [.minSize]
        panel.contentView = host
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        panel.setFrameAutosaveName("SceneSplitter")
        if panel.frame.origin == .zero { panel.center() }
        self.panel = panel
        isOpen = true
        watchKeys()
        refresh()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    /// Shows `focus` as if open, without a panel, for a picture of the view
    /// (`UISnapshots`) and tests.
    func openWithoutPanel(_ focus: Focus, selecting ids: [String] = []) {
        setFocus(focus, selecting: ids)
        isOpen = true
        refresh()
    }

    private func didClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        closeObserver = nil
        keyMonitor = nil
        panel = nil
        isOpen = false
        pendingEdit = nil
        draftSensitivity = nil
        skimming = nil
        skim.end()
    }

    /// Shows what the browser has picked: `focus`, with the scenes
    /// `selecting` picked here too. Nil, or anything but video, leaves the
    /// splitter on what it showed.
    func follow(_ focus: Focus?, selecting ids: [String] = []) {
        guard let focus else { return }
        setFocus(focus, selecting: ids)
        refresh()
    }

    private func setFocus(_ focus: Focus, selecting ids: [String]) {
        if focus != self.focus {
            self.focus = focus
            marker = focus.start
            zoom = 1
            draftSensitivity = nil
            pendingEdit = nil
            skimming = nil
        }
        var picked = BrowserSelection<String>()
        for id in ids { picked.commandClick(id) }
        selection = picked
    }

    /// Keeps it current with the project, after any edit, undo or redo.
    /// The scenes are worked out again only when what they come from
    /// changed: the asset (its edits) or the project's default sensitivity.
    func update(project: EditingProject) {
        let old = self.project
        self.project = project
        guard let focus else { return }
        let media = project.mediaClip(id: focus.assetID)
        if media == nil { self.focus = nil }
        if media != old.mediaClip(id: focus.assetID) || project.defaultSensitivity != old.defaultSensitivity {
            refresh()
        }
    }

    private var skimTarget: BrowserSkim.Target? {
        guard let media, let span else { return nil }
        return BrowserSkim.Target(item: Self.skimItem, clip: media, start: span.start, duration: CMTimeSubtract(span.end, span.start))
    }

    /// Works out the scenes again, and keeps the picture on the stretch
    /// shown, at the marker. Called too when an asset's scenes are found
    /// while the panel is open. Nothing is worked out while it is closed:
    /// opening it does that.
    func refresh() {
        guard isOpen else { return }
        guard let focus, media != nil else {
            allScenes = []
            scenes = []
            return
        }
        let track = sceneTracks()[focus.assetID]
        var all = project.scenes(ofAsset: focus.assetID, track: track)
        if let draftSensitivity, let committed = Self.overlapping(all, focus).span {
            all = project.scenesPreviewing(ofAsset: focus.assetID, track: track, applying: {
                $0.applySensitivity(draftSensitivity, from: committed.start, to: committed.end)
            })
        }
        allScenes = all
        indexByID = Dictionary(all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        scenes = Self.overlapping(all, focus)
        selection.keep(only: scenes.map(\.id))
        guard let span, let target = skimTarget else { return }
        if marker.map({ CMTimeCompare($0, span.start) < 0 || CMTimeCompare($0, span.end) > 0 }) ?? true {
            marker = span.start
        }
        zoom = min(zoom, maximumZoom)
        guard skim.target != target, let seconds = shownSeconds else { return }
        skim.skim(target, at: seconds, audible: false)
    }

    private static func overlapping(_ scenes: [SceneRange], _ focus: Focus) -> [SceneRange] {
        scenes.filter { CMTimeCompare($0.end, focus.start) > 0 && CMTimeCompare($0.start, focus.end) < 0 }
    }

    // MARK: - The marker and skimming

    /// The pointer over the strip at `seconds` into the stretch, or gone
    /// from it (nil): the picture follows it, and goes back to the marker
    /// when it leaves. Play isn't interrupted.
    func hover(atSeconds seconds: Double?) {
        guard !isPlaying, let target = skimTarget else { return }
        skimming = seconds.map { min(max($0, 0), length) }
        if let skimming {
            skim.skim(target, at: skimming)
        } else if let markerSeconds {
            skim.skim(target, at: markerSeconds, audible: false)
        }
    }

    /// A click on the strip: the marker goes to the frame clicked, and the
    /// scene there is picked as a click, Shift-click or Command-click picks.
    func click(atSeconds seconds: Double, modifiers: NSEvent.ModifierFlags = []) {
        placeMarker(atSeconds: seconds)
        guard let marker, let scene = scene(at: marker) else { return }
        pick(scene, modifiers: modifiers)
    }

    /// Moves the marker without changing what is picked: a click on the
    /// ruler, or a drag along the strip.
    func placeMarker(atSeconds seconds: Double) {
        stopPlaying()
        skimming = nil
        marker = snapped(time(atSeconds: min(max(seconds, 0), length)))
        showMarker(audible: true)
    }

    /// Picks the scene the marker is in, from the keyboard (Return).
    func pickAtMarker(modifiers: NSEvent.ModifierFlags = []) {
        guard let marker, let scene = scene(at: marker) else { return }
        pick(scene, modifiers: modifiers)
    }

    private func pick(_ scene: SceneRange, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            selection.commandClick(scene.id)
        } else if modifiers.contains(.shift) {
            selection.shiftClick(scene.id, in: scenes.map(\.id))
        } else {
            selection.click(scene.id)
        }
    }

    /// Steps the marker `frames` frames, a frame being the footage's.
    func step(frames: Int) {
        stopPlaying()
        guard let base = marker, let span else { return }
        let moved = CMTimeAdd(base, CMTime(seconds: Double(frames) / frameRate, preferredTimescale: 6000))
        let clamped = CMTimeMaximum(span.start, CMTimeMinimum(span.end, moved))
        marker = snapped(clamped)
        skimming = nil
        showMarker(audible: true)
    }

    /// Plays from the marker, which rides along; pausing leaves it where
    /// play reached.
    func togglePlay() {
        if isPlaying {
            stopPlaying()
            return
        }
        skimming = nil
        showMarker(audible: false)
        skim.togglePlay()
    }

    /// Leaves the marker where play reached, when play stops by itself at
    /// the stretch's end or is stopped.
    func playDidStop() {
        guard !skim.isPlaying, skim.target?.item == Self.skimItem, span != nil else { return }
        marker = time(atSeconds: skim.seconds)
    }

    private func stopPlaying() {
        guard isPlaying else { return }
        let reached = skim.seconds
        skim.togglePlay()
        marker = time(atSeconds: reached)
    }

    /// Moves the marker to the previous or next cut in the stretch, or its
    /// start or end.
    func jumpToCut(_ side: Side) {
        stopPlaying()
        guard let marker, let span else { return }
        let edges = scenes.map(\.start) + [span.end]
        let target = side == .previous
            ? edges.last { CMTimeCompare($0, marker) < 0 }
            : edges.first { CMTimeCompare($0, marker) > 0 }
        guard let target else { return }
        self.marker = target
        skimming = nil
        showMarker(audible: true)
    }

    private func showMarker(audible: Bool) {
        guard let target = skimTarget, let markerSeconds else { return }
        skim.skim(target, at: markerSeconds, audible: audible)
    }

    /// A time snapped to a real frame of the file, or to the footage's
    /// frame grid before its scores are in.
    private func snapped(_ time: CMTime) -> CMTime {
        guard let media else { return time }
        if let track { return track.nearestFrameTime(toOriginal: time, mapping: media.timeMapping) }
        return CMTime(seconds: (time.seconds * frameRate).rounded() / frameRate, preferredTimescale: 6000)
    }

    // MARK: - Zooming

    /// The furthest in the strip zooms: until a frame is `widestFrame`
    /// points wide.
    var maximumZoom: Double {
        max(1, length * frameRate * Self.widestFrame / Double(max(stripWidth, 1)))
    }

    func setZoom(_ value: Double) {
        zoom = min(max(value, 1), maximumZoom)
    }

    func zoom(by factor: Double) { setZoom(zoom * factor) }

    // MARK: - Editing

    /// The cut Split would make: the frame the picture shows (the marker's,
    /// unless the pointer is skimming), snapped to a real frame of the file,
    /// when that is inside its scene and not at its start.
    var splitTime: CMTime? {
        guard let shownSeconds, let media else { return nil }
        let position = time(atSeconds: shownSeconds)
        guard let scene = scene(at: position) else { return nil }
        let inside = CMTimeRange(start: scene.start, end: scene.end)
        let time: CMTime
        if let track {
            time = track.nearestFrameTime(toOriginal: position, mapping: media.timeMapping, within: inside)
        } else {
            time = CMTime(seconds: (position.seconds * frameRate).rounded() / frameRate, preferredTimescale: 6000)
        }
        guard CMTimeCompare(time, scene.start) > 0, CMTimeCompare(time, scene.end) < 0 else { return nil }
        return time
    }

    /// Starts a new scene, and so a new clip, at the frame shown.
    func split() {
        guard let time = splitTime else { return }
        edit { $0.addCut(at: time) }
    }

    /// The picked scenes, in order, when there are two or more side by
    /// side with nothing between them: what Merge joins. Nil otherwise.
    var mergeable: [SceneRange]? {
        let indices = selection.items.compactMap { indexByID[$0] }.sorted()
        guard indices.count > 1, indices.count == selection.items.count,
              let first = indices.first, indices.last == first + indices.count - 1
        else { return nil }
        let picked = indices.map { allScenes[$0] }
        for (a, b) in zip(picked, picked.dropFirst()) where CMTimeCompare(a.end, b.start) != 0 { return nil }
        return picked
    }

    /// Joins the picked scenes into one, taking away the cuts between them.
    func merge() {
        guard let picked = mergeable, let first = picked.first else { return }
        let cuts = picked.dropFirst().map { SceneCut(time: $0.start, origin: $0.origin) }
        // Taking cuts away adds none, so nothing can be embedded.
        edit(addsCuts: false) { edits in
            for cut in cuts { edits.removeCut(cut) }
        }
        var joined = BrowserSelection<String>()
        joined.click(first.id)
        selection = joined
    }

    /// Shows the scenes `value` would make while its slider is dragged.
    func drag(sensitivity value: Double) {
        draftSensitivity = value
        refresh()
    }

    /// Sets the cut sensitivity between the outer edges of the stretch
    /// (see `SceneEdits.applySensitivity`).
    func applySensitivity(_ value: Double) {
        guard let focus, let span = Self.overlapping(project.scenes(ofAsset: focus.assetID, track: track), focus).span else { return }
        edit { $0.applySensitivity(value, from: span.start, to: span.end) }
    }

    /// Makes a change, unless it would put clips into timelines of their
    /// own: that waits in `pendingEdit` for the person to agree. Finding
    /// out means working the scenes out twice, so it is skipped for a
    /// change that adds no cuts, and when no clip of the asset is animated.
    private func edit(addsCuts: Bool = true, _ change: @escaping (inout SceneEdits) -> Void) {
        guard let focus else { return }
        guard addsCuts, project.hasAnimatedClips(ofAsset: focus.assetID) else {
            commit(change)
            return
        }
        let cuts = project.sceneCutChange(ofAsset: focus.assetID, track: track, applying: change)
        let animated = project.clipsAnimated(across: cuts.added, ofAsset: focus.assetID)
        guard animated.isEmpty else {
            pendingEdit = PendingEdit(clipCount: animated.count, change: change)
            return
        }
        commit(change)
    }

    func confirmPendingEdit() {
        guard let pending = pendingEdit else { return }
        pendingEdit = nil
        commit(pending.change)
    }

    func cancelPendingEdit() {
        pendingEdit = nil
        draftSensitivity = nil
        refresh()
    }

    /// Makes the change; the project coming back through `update` shows
    /// it. A dragged sensitivity's preview is put away even if nothing
    /// changed.
    private func commit(_ change: @escaping (inout SceneEdits) -> Void) {
        guard let focus else { return }
        let track = track
        let wasDragging = draftSensitivity != nil
        draftSensitivity = nil
        onEdit { $0.editScenesFollowingClips(ofAsset: focus.assetID, track: track, change) }
        if wasDragging { refresh() }
    }

    // MARK: - Keys

    /// While the panel has the keyboard and no text field does: ← and →
    /// step the marker a frame (ten with Shift), ↑ and ↓ take it to the
    /// previous or next cut, Return picks the scene it is in (Shift and
    /// Command as clicks do), Space plays, S splits, M merges, = and - zoom,
    /// \ fits, as on the timeline, and Escape closes.
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, event.window === panel,
                      !(panel.firstResponder is NSText), self.pendingEdit == nil
                else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let shift = flags == .shift
        if event.keyCode == 36, flags.isDisjoint(with: [.control, .option]) {
            pickAtMarker(modifiers: flags)
            return true
        }
        guard flags.isEmpty || shift else { return false }
        switch event.keyCode {
        case 123: step(frames: shift ? -10 : -1)
        case 124: step(frames: shift ? 10 : 1)
        case 126 where !shift: jumpToCut(.previous)
        case 125 where !shift: jumpToCut(.next)
        case 49 where !shift: togglePlay()
        case 53 where !shift: close()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s" where !shift: split()
            case "m" where !shift: merge()
            case "=", "+": zoom(by: 1.5)
            case "-" where !shift: zoom(by: 1 / 1.5)
            case "\\" where !shift: setZoom(1)
            default: return false
            }
        }
        return true
    }
}
