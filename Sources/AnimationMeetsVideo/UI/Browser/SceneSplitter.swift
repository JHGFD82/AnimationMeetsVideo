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
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    private static let skimItem = AnyHashable("sceneSplitter")

    init() {
        isSoundOn = UserDefaults.standard.object(forKey: Preferences.sceneSplitterSound) as? Bool ?? true
        skim.soundOverride = isSoundOn
    }

    // MARK: - What it shows

    var media: MediaClip? { focus.flatMap { project.mediaClip(id: $0.assetID) } }
    var track: ChangeScoreTrack? { focus.flatMap { sceneTracks()[$0.assetID] } }

    /// From the start of the first scene shown to the end of the last.
    var span: (start: CMTime, end: CMTime)? { scenes.span }

    /// Where the picture is, in the asset's original time.
    var position: CMTime? {
        guard skim.target?.item == Self.skimItem else { return nil }
        return skim.sourceTime
    }

    /// The scene the picture is in.
    var currentScene: SceneRange? {
        guard let position else { return scenes.first }
        return scenes.last { CMTimeCompare($0.start, position) <= 0 } ?? scenes.first
    }

    /// A scene's number among all of its asset's, as the browser counts.
    func number(of scene: SceneRange) -> Int? {
        allScenes.firstIndex { $0.id == scene.id }.map { $0 + 1 }
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

    /// Opens the panel on `focus`, or brings it to the front.
    func show(_ focus: Focus?) {
        if let focus { self.focus = focus }
        if let panel {
            refresh()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scene Splitter"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentMinSize = NSSize(width: 480, height: 480)
        panel.contentView = NSHostingView(rootView: SceneSplitterView(splitter: self))
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        panel.center()
        panel.setFrameAutosaveName("SceneSplitter")
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
    /// (`UISnapshots`).
    func openWithoutPanel(_ focus: Focus) {
        self.focus = focus
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
        skim.end()
    }

    /// Shows what the browser has picked. Nil, or anything but video,
    /// leaves the splitter on what it showed.
    func follow(_ focus: Focus?) {
        guard let focus, focus != self.focus else { return }
        self.focus = focus
        draftSensitivity = nil
        pendingEdit = nil
        refresh()
    }

    /// Keeps it current with the project, after any edit, undo or redo.
    func update(project: EditingProject) {
        guard project != self.project else { return }
        self.project = project
        if let focus, project.mediaClip(id: focus.assetID) == nil {
            self.focus = nil
        }
        refresh()
    }

    /// Works out the scenes again, and keeps the picture on the stretch
    /// shown, at the same moment where it can. Called too when an asset's
    /// scenes are found while the panel is open. Nothing is worked out while
    /// it is closed: opening it does that.
    func refresh() {
        guard isOpen else { return }
        guard let focus, let media else {
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
        scenes = Self.overlapping(all, focus)
        guard let span else { return }
        let target = BrowserSkim.Target(item: Self.skimItem, clip: media, start: span.start, duration: CMTimeSubtract(span.end, span.start))
        guard skim.target != target else { return }
        let at = position.map { CMTimeSubtract($0, span.start).seconds } ?? 0
        skim.skim(target, at: at)
    }

    private static func overlapping(_ scenes: [SceneRange], _ focus: Focus) -> [SceneRange] {
        scenes.filter { CMTimeCompare($0.end, focus.start) > 0 && CMTimeCompare($0.start, focus.end) < 0 }
    }

    // MARK: - Moving

    /// Shows the frame `seconds` into the stretch, with a grain of sound.
    func skim(toSeconds seconds: Double) {
        guard let target = skim.target, target.item == Self.skimItem else { return }
        skim.skim(target, at: seconds)
    }

    func step(frames: Int) { skim.step(frames: frames) }

    func togglePlay() { skim.togglePlay() }

    /// Moves the picture to the previous or next cut in the stretch, or its
    /// start or end.
    func jumpToCut(_ side: Side) {
        guard let position, let span else { return }
        let edges = scenes.map(\.start) + [span.end]
        let target = side == .previous
            ? edges.last { CMTimeCompare($0, position) < 0 }
            : edges.first { CMTimeCompare($0, position) > 0 }
        guard let target else { return }
        skim(toSeconds: CMTimeSubtract(target, span.start).seconds)
    }

    // MARK: - Editing

    /// The cut Split would make: the frame shown, snapped to a real frame
    /// of the file, when that is inside the scene and not at its start.
    var splitTime: CMTime? {
        guard let position, let scene = currentScene, let media else { return nil }
        let inside = CMTimeRange(start: scene.start, end: scene.end)
        let time: CMTime
        if let track {
            time = track.nearestFrameTime(toOriginal: position, mapping: media.timeMapping, within: inside)
        } else {
            let rate = media.frameRate > 0 ? media.frameRate : 30
            time = CMTime(seconds: (position.seconds * rate).rounded() / rate, preferredTimescale: 600)
        }
        guard CMTimeCompare(time, scene.start) > 0, CMTimeCompare(time, scene.end) < 0 else { return nil }
        return time
    }

    func split() {
        guard let time = splitTime else { return }
        edit { $0.addCut(at: time) }
    }

    /// The cut between the current scene and the one before or after it,
    /// when the two meet (footage that stops between them has no cut).
    func cut(toMerge side: Side) -> SceneCut? {
        guard let scene = currentScene, let index = allScenes.firstIndex(where: { $0.id == scene.id }) else { return nil }
        switch side {
        case .previous:
            guard index > 0, CMTimeCompare(allScenes[index - 1].end, scene.start) == 0 else { return nil }
            return SceneCut(time: scene.start, origin: scene.origin)
        case .next:
            guard index + 1 < allScenes.count, CMTimeCompare(allScenes[index + 1].start, scene.end) == 0 else { return nil }
            let next = allScenes[index + 1]
            return SceneCut(time: next.start, origin: next.origin)
        }
    }

    func merge(_ side: Side) {
        guard let cut = cut(toMerge: side) else { return }
        edit { $0.removeCut(cut) }
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
    /// own: that waits in `pendingEdit` for the person to agree.
    private func edit(_ change: @escaping (inout SceneEdits) -> Void) {
        guard let focus else { return }
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

    private func commit(_ change: @escaping (inout SceneEdits) -> Void) {
        guard let focus else { return }
        let track = track
        draftSensitivity = nil
        onEdit { $0.editScenesFollowingClips(ofAsset: focus.assetID, track: track, change) }
        refresh()
    }

    // MARK: - Keys

    /// ← and → step a frame (ten with Shift), ↑ and ↓ go to the previous or
    /// next cut, Space plays, S splits and Escape closes, while the panel
    /// has the keyboard and no text field does.
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
        guard flags.isEmpty || shift else { return false }
        switch event.keyCode {
        case 123: step(frames: shift ? -10 : -1)
        case 124: step(frames: shift ? 10 : 1)
        case 126 where !shift: jumpToCut(.previous)
        case 125 where !shift: jumpToCut(.next)
        case 49 where !shift: togglePlay()
        case 53 where !shift: close()
        default:
            guard !shift, event.charactersIgnoringModifiers?.lowercased() == "s" else { return false }
            split()
        }
        return true
    }
}
