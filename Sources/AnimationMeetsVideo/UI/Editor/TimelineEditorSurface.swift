import AVFoundation
import CoreMedia
import SwiftUI

/// The viewer + inspector + timeline for a single timeline within a project.
/// Reused by both the main window and the external display's independent mode.
/// The main window puts its library to the left of the viewer, so the
/// timeline below runs the full width of the window.
struct TimelineEditorSurface<Library: View>: View {
    @Binding var project: EditingProject
    /// The timeline shown, which the surface only reads. A value rather
    /// than a binding: a binding made for each redraw of the editor, as the
    /// active timeline's is, counts as changed every time and redrew the
    /// whole surface on every edit.
    let timelineID: UUID
    /// Shows another timeline, as the header's timeline menu does.
    var selectTimeline: (UUID) -> Void = { _ in }
    @Binding var selection: TimelineSelection?
    let playback: PlaybackModel
    let analysis: AssetAnalysis
    /// Assets whose file is missing. Their clips play as gaps, and the
    /// viewer rebuilds when one comes back.
    var offlineMedia: Set<UUID> = []
    /// A clip for the timeline to zoom to and light up, from Find All.
    var clipFocus: TimelineClipFocus? = nil
    @ViewBuilder let library: () -> Library
    /// Renders in the background; absent in windows that don't render.
    @Environment(RenderScheduler.self) private var renderer: RenderScheduler?
    @Environment(MediaImports.self) private var imports: MediaImports?
    /// Holds value drags to one side of the project, for the viewer to
    /// follow (see `HeldDragFollower`); absent in previews and tests.
    @Environment(ProjectState.self) private var projectState: ProjectState?

    /// Where the playhead is parked. Not read as the body is built (see
    /// `PlayheadState`), so `playheadTime` is for actions and closures.
    @State private var playhead = PlayheadState()
    /// The timelines gone into to reach this one, outermost first: what the
    /// header's breadcrumb offers to go back to.
    @State private var trail: [UUID] = []
    /// The timeline the last step into or out of a nested one chose, to
    /// tell it from one chosen another way (the browser, the menu), whose
    /// trail is the timelines it is inside.
    @State private var trailTarget: UUID?

    private var playheadTime: CMTime {
        get { playhead.time }
        nonmutating set { playhead.time = newValue }
    }
    @State private var trimPreview = TrimPreviewModel()
    /// The timelines nested clips play, as pictures along those clips and
    /// in the trim preview.
    @State private var nestedPreviews = NestedTimelinePreviews()
    /// Turns what the surface shows into the viewer's player items (see
    /// `ViewerPipeline`); made when the surface appears, with its player
    /// and renderer.
    @State private var pipeline: ViewerPipeline?
    /// Why a file dragged in from the Finder couldn't be imported.
    @State private var dropError: String?
    /// As tall as the person makes it, not as tall as its layers need: its
    /// areas share whatever height it has and scroll the rest.
    @AppStorage(Preferences.timelineHeight) private var timelineHeight: Double = 280
    @AppStorage(Preferences.browserMutesAddedSound) private var mutesAddedSound = false
    /// The Effects Library at the right end of the timeline, and which tab it is on.
    @AppStorage(Preferences.showsEffectsLibrary) private var showsEffectsLibrary = false
    @AppStorage(Preferences.effectsLibraryTab) private var effectsLibraryTab = EffectsLibraryTab.effects
    /// The area beside the viewer, and which tab it is on. The tab only
    /// changes when the person picks one or an effect is applied.
    @AppStorage(Preferences.showsSidePanel) private var showsSidePanel = true
    @AppStorage(Preferences.sidePanelTab) private var sideTab = SidePanelTab.inspector
    /// Each side panel tab keeps its own width, and so does the browser.
    @AppStorage(Preferences.effectsPanelWidth) private var effectsPanelWidth = 640.0
    @AppStorage(Preferences.inspectorPanelWidth) private var inspectorPanelWidth = 280.0
    @AppStorage(Preferences.browserWidth) private var browserWidth = 260.0
    @State private var effectsState = EffectsPanelState()
    /// The panel last clicked in, which wears a light border and gets the
    /// keys and the Edit menu first.
    @State private var activePanel = ActivePanel()
    @AppStorage(Preferences.showsAudioMeter) private var showsMeter = false
    /// The graph editors this surface has open, one HUD per parameter.
    @State private var graphs = KeyframeGraphHUDs()
    /// Carries out what the timeline asks for (`TimelineHost`).
    @State private var timelineHost = SurfaceTimelineHost<Library>()

    /// How many effects the selected clip has, to notice one being applied.
    private struct AppliedEffects: Equatable {
        var clipID: UUID
        var count: Int
    }

    private var appliedEffects: AppliedEffects? {
        selectedTimelineClip.map { AppliedEffects(clipID: $0.id, count: $0.effects.count + $0.audioEffects.count) }
    }

    private let minTimelineHeight: CGFloat = 140
    private let minTopAreaHeight: CGFloat = 220

    private var timeline: Timeline? {
        project.timeline(id: timelineID)
    }

    /// The narrowest each panel gets: the effects panel needs room for its
    /// lanes beside its controls.
    private static var effectsMinWidth: CGFloat { 480 }
    private static var inspectorMinWidth: CGFloat { 240 }
    private static var browserMinWidth: CGFloat { 200 }

    /// The widest the side panel gets, so the viewer keeps room.
    private func sideMaxWidth(in available: CGFloat) -> CGFloat {
        available * 0.55
    }

    private func browserMaxWidth(in available: CGFloat) -> CGFloat {
        available * 0.4
    }

    private var sideWidth: Binding<Double> {
        sideTab == .effects ? $effectsPanelWidth : $inspectorPanelWidth
    }

    private var sideMinWidth: CGFloat {
        sideTab == .effects ? Self.effectsMinWidth : Self.inspectorMinWidth
    }

    /// The clip and effect Show Up to Here is showing, while the effect
    /// is still there.
    private var partialView: EffectsPanelState.ShowUpTo? {
        guard let showing = effectsState.showUpTo,
              project.hasEffect(showing.effectID, ofClip: showing.clipID, in: timelineID)
        else {
            return nil
        }
        return showing
    }

    /// The project as the viewer draws it: the real one, except while Show
    /// Up to Here is on, when one clip is cut short. Export and renders
    /// always use the real one.
    private var viewedProject: EditingProject { viewed(project) }

    private func viewed(_ project: EditingProject) -> EditingProject {
        guard let showing = partialView else { return project }
        return project.showing(upTo: showing.effectID, ofClip: showing.clipID, in: timelineID)
    }

    /// What the viewer shows besides the project.
    private struct ViewerInputs: Equatable {
        var showUpTo: EffectsPanelState.ShowUpTo?
        var offlineMedia: Set<UUID>
    }

    private func send(_ event: ViewerPipeline.Event) {
        pipeline?.send(event)
    }

    private func showProject() {
        pipeline?.show(source(of: project))
    }

    /// What the viewer is asked to show of `project` (the real one, or a
    /// held drag's).
    private func source(of project: EditingProject, held: Bool = false) -> ViewerSource {
        ViewerSource(
            project: viewed(project), renderProject: project, timelineID: timelineID,
            isPartial: partialView != nil, offlineMedia: offlineMedia, isHeld: held
        )
    }

    /// What the viewer's banner says while Show Up to Here is on.
    private var partialBanner: String? {
        guard let showing = partialView,
              let effect = project.clipAndLayer(showing.clipID, in: timelineID)?.clip.effects.first(id: showing.effectID)
        else {
            return nil
        }
        return "Showing up to \(effect.displayName)"
    }

    private var selectedTimelineClip: TimelineClip? {
        guard let selection, selection.timelineID == timelineID, let timeline,
              let layer = timeline.layer(id: selection.layerID)
        else {
            return nil
        }
        return layer.clips.first(id: selection.timelineClipID)
    }

    /// Says which of the files this timeline plays are offline, if any.
    private var offlineNotice: String? {
        guard let timeline, !offlineMedia.isEmpty else { return nil }
        let used = Set(timeline.layers.flatMap(\.clips).compactMap { clip -> UUID? in
            if case .media(let id) = clip.source { return id }
            return nil
        })
        let names = project.clips.filter { offlineMedia.contains($0.id) && used.contains($0.id) }.map(\.name)
        guard let first = names.first else { return nil }
        return names.count == 1
            ? "\u{201C}\(first)\u{201D} is offline: its clips play as gaps."
            : "\(names.count) media files are offline: their clips play as gaps."
    }

    private var selectedInfo: ResolvedClipInfo? {
        guard let selectedTimelineClip else { return nil }
        return project.resolvedInfo(for: selectedTimelineClip)
    }

    var body: some View {
        followingViewer(editor)
    }

    private var editor: some View {
        GeometryReader { geometry in
            let maxTimelineHeight = max(minTimelineHeight, geometry.size.height - minTopAreaHeight)
            let resolvedTimelineHeight = CGFloat(timelineHeight).clamped(between: minTimelineHeight, and: maxTimelineHeight)

            VStack(spacing: 0) {
                TimelineHeaderBar(
                    project: $project, timelineID: Binding(get: { timelineID }, set: { selectTimeline($0) }),
                    trail: trail, onLeaveTo: { leaveTimeline(to: $0) }
                )

                HStack(spacing: 0) {
                    library()
                        // For the Generators tab, which starts a clip at
                        // the playhead; read as it acts, not as it draws.
                        .environment(playhead)
                        .frame(width: CGFloat(PanelResizeHandle.clamped(
                            browserWidth, min: Self.browserMinWidth, max: browserMaxWidth(in: geometry.size.width)
                        )))
                        .editorPanel(.browser, activePanel)
                        .overlay(alignment: .trailing) {
                            PanelResizeHandle(
                                width: $browserWidth, minWidth: Self.browserMinWidth,
                                maxWidth: browserMaxWidth(in: geometry.size.width), edge: .trailing,
                                help: "Drag to resize the browser"
                            )
                        }
                    ViewerPanel(
                        playback: playback,
                        hasContent: timeline?.layers.contains { !$0.clips.isEmpty } ?? false,
                        frameSize: timeline?.frameSize ?? CGSize(width: 16, height: 9),
                        frameRate: timeline?.frameRate ?? 24,
                        buildError: pipeline?.buildError,
                        offlineNotice: offlineNotice,
                        trimPreview: trimPreview,
                        banner: partialBanner,
                        onClearBanner: { effectsState.showUpTo = nil }
                    )
                    .editorPanel(.viewer, activePanel)
                    if showsSidePanel {
                        VStack(spacing: 0) {
                            PanelTabBar(
                                tabs: SidePanelTab.allCases, selection: $sideTab, title: \.title,
                                onClose: { showsSidePanel = false }, closeHelp: "Hide the inspector and effects"
                            )
                            switch sideTab {
                            case .inspector:
                                InspectorPanel(
                                    project: $project,
                                    timelineID: timelineID,
                                    selection: selection,
                                    info: selectedInfo,
                                    timelineClip: selectedTimelineClip,
                                    playhead: playhead,
                                    onSeek: { time in scrub(to: time) },
                                    onDeleteSelection: { selection = nil },
                                    sceneTracks: { [analysis] in analysis.tracks }
                                )
                            case .effects:
                                EffectsPanel(
                                    project: $project,
                                    timelineID: timelineID,
                                    selection: selection,
                                    playhead: playhead,
                                    state: effectsState,
                                    onSeek: { time in scrub(to: time) },
                                    onSelectTransition: { edge in
                                        if let selection {
                                            self.selection = TimelineSelection(
                                                timelineID: selection.timelineID, layerID: selection.layerID,
                                                timelineClipID: selection.timelineClipID, transitionEdge: edge
                                            )
                                        }
                                    },
                                    playback: playback
                                )
                            }
                        }
                        .frame(width: CGFloat(PanelResizeHandle.clamped(
                            sideWidth.wrappedValue, min: sideMinWidth, max: sideMaxWidth(in: geometry.size.width)
                        )))
                        .editorPanel(.sidePanel, activePanel)
                        .overlay(alignment: .leading) {
                            PanelResizeHandle(
                                width: sideWidth, minWidth: sideMinWidth, maxWidth: sideMaxWidth(in: geometry.size.width),
                                edge: .leading, help: sideTab == .effects ? "Drag to resize the effects panel" : "Drag to resize the inspector"
                            )
                        }
                        .grooved(.leading)
                        .transition(.move(edge: .trailing))
                    }
                }
                .editorAnimation(Design.Motion.panel, value: showsSidePanel)
                .frame(maxHeight: .infinity)

                TimelineResizeHandle(
                    height: Binding(get: { resolvedTimelineHeight }, set: { timelineHeight = Double($0) }),
                    minHeight: minTimelineHeight,
                    maxHeight: maxTimelineHeight
                )

                HStack(spacing: 0) {
                    timelineView
                        .editorPanel(.timeline, activePanel)
                    if showsMeter {
                        AudioMeterView(playback: playback)
                            .frame(width: 52)
                            .grooved(.leading)
                            .transition(.move(edge: .trailing))
                    }
                    if showsEffectsLibrary {
                        EffectsLibrary(
                            project: $project, timelineID: timelineID, selection: selection,
                            state: effectsState, tab: $effectsLibraryTab, onClose: { showsEffectsLibrary = false }
                        )
                        .frame(width: 280)
                        .editorPanel(.effectsLibrary, activePanel)
                        .grooved(.leading)
                        .transition(.move(edge: .trailing))
                    }
                }
                .frame(height: resolvedTimelineHeight)
                .editorAnimation(Design.Motion.panel, value: showsEffectsLibrary)
                .editorAnimation(Design.Motion.panel, value: showsMeter)
            }
        }
        .environment(graphs)
        .environment(activePanel)
        .environment(nestedPreviews)
        .background(ActivePanelMonitor(active: activePanel))
        .background {
            if let projectState {
                HeldDragFollower(state: projectState, draw: drawHeld, end: heldDragEnded)
            }
        }
        .modifier(ActivePanelPublisher(active: activePanel))
        .onReceive(NotificationCenter.default.publisher(for: .revealEffect)) { note in
            if let id = note.object as? UUID { effectsState.select(effect: id) }
        }
        // Applying an effect shows the effects list; nothing else does.
        .onChange(of: appliedEffects) { old, new in
            if let old, let new, old.clipID == new.clipID, new.count > old.count {
                showsSidePanel = true
                sideTab = .effects
            }
        }
        .onChange(of: project, initial: true) { _, project in
            graphs.update(project: project)
            // Volumes aren't part of the composition: the player's audio
            // taps read them as they play, so an edit is heard without a
            // rebuild. Worked out here, once per edit, rather than in
            // `body`, which also runs for selection and playhead changes.
            playback.mixCurves.replace(with: MixCurves.of(project))
            playback.scrubAudio.forget()
            playback.tapeScrub.forget()
            // The browser's timeline filmstrips, values included, which the
            // browser itself isn't redrawn for.
            TimelinePreviews.shared.projectChanged(project)
            nestedPreviews.projectChanged(project)
            // Show Up to Here lets go of an effect that is gone.
            if effectsState.showUpTo != nil, partialView == nil { effectsState.showUpTo = nil }
            // The viewer works out what the edit changed (see
            // `ViewerPipeline.show`).
            showProject()
        }
        // A package changed in the Effects folder draws again, its content
        // hash in the composition's key.
        .onChange(of: EffectPackageStatus.shared.revision) { showProject() }
        .onAppear {
            trail = project.containingTimelines(of: timelineID)
            playhead.liveTime = { [playback] in playback.isPlaying ? playback.player.currentTime() : nil }
            let project = $project
            graphs.onEdit = { change in change(&project.wrappedValue) }
            graphs.onSeek = { time in scrub(to: time) }
            graphs.onTogglePlayback = { playback.togglePlayback() }
            graphs.playback = playback
        }
        .onDisappear {
            graphs.closeAll()
            // These hold this surface, whose state holds them: kept, they
            // would keep it, and the project, alive.
            timelineHost.surface = nil
            graphs.onEdit = { _ in }
            graphs.onSeek = { _ in }
            graphs.onTogglePlayback = {}
        }
        .onChange(of: timelineID) { _, newValue in
            if newValue != trailTarget { trail = project.containingTimelines(of: newValue) }
            trailTarget = nil
            if selection?.timelineID != newValue {
                selection = nil
            }
            playback.player.pause()
            playheadTime = .zero
            send(.timelineChanged(source(of: project), at: .zero))
        }
        .onChange(of: ViewerInputs(showUpTo: partialView, offlineMedia: offlineMedia)) { _, _ in
            showProject()
        }
    }

    /// The playhead, which the graphs and the renderer start from, and
    /// where playing stopped. What else the viewer follows (renders, the
    /// package, motion blur, play and pause, value gestures) its pipeline
    /// follows on its own.
    private func followingViewer(_ content: some View) -> some View {
        content
        // Wherever it stops, playing or scrubbing, is where rendering starts.
        // The tape scrubber moves the player while paused; the parked
        // playhead goes with it.
        .background {
            PlayheadFollower(
                playhead: playhead, playback: playback,
                onMove: { time in
                    graphs.playhead = time
                    renderer?.playhead = time
                },
                onTapeScrub: { time in
                    renderer?.noteActivity()
                    playheadTime = time
                }
            )
        }
        .onChange(of: playback.isPlaying) { _, playing in
            // The parked playhead doesn't follow playback (see
            // `TimelineView.playheadTime`); it catches up where it stopped.
            // Its time, not the player's: a seek just asked for (stepping a
            // frame pauses, then seeks) is there at once.
            if !playing { playheadTime = playback.currentTime }
        }
        .messageAlert("Import Failed", message: $dropError)
        .onAppear {
            if pipeline == nil { pipeline = ViewerPipeline(playback: playback, renderer: renderer) }
            send(.appeared(source(of: project), at: playheadTime))
        }
    }

    @ViewBuilder
    private var timelineView: some View {
        // The host acts through this surface as it is now: its bindings,
        // and what it was given at this redraw (the timeline, the analysis).
        let _ = timelineHost.surface = self
        if let timeline {
            TimelineView(
                project: project,
                timeline: timeline,
                timelineID: timelineID,
                selection: selection,
                beatTracks: analysis.beats,
                beatClicks: playback.beatClicks,
                playback: playback,
                playhead: playhead,
                host: timelineHost,
                showsEffectsLibrary: $showsEffectsLibrary,
                showsSidePanel: $showsSidePanel,
                showsEffects: showsSidePanel && sideTab == .effects,
                showsMeter: $showsMeter,
                effectsState: effectsState,
                focus: clipFocus
            )
            .equatable()
        } else {
            ContentUnavailableView("No Timeline Selected", systemImage: "timeline.selection")
        }
    }

    /// Media dragged from the browser becomes ordinary clips, back to back
    /// in the order it was dragged. Dropped on a layer it goes onto it at the
    /// drop time, if it all fits and the layer is the right kind; otherwise,
    /// or dropped elsewhere, onto new layers at the top, of `kind` or each
    /// asset's default kind.
    fileprivate func dropScenes(_ payloads: [MediaDragPayload], onLayer layerID: UUID?, at time: CMTime, kind: LayerKind? = nil) -> Bool {
        place(payloads.flatMap(\.pieces), onLayer: layerID, at: time, kind: kind)
    }

    /// Files dragged in from the Finder are imported into the library, then
    /// placed whole as media dropped there would be. A kind they don't all
    /// suit gives way to each file's own.
    fileprivate func dropFiles(_ urls: [URL], onLayer layerID: UUID?, at time: CMTime, kind: LayerKind?) {
        let timelineID = timelineID
        Task {
            guard let imported = await MediaImportFlow.importDropped(
                urls, packageURL: renderer?.packageURL, project: $project, imports: imports, onError: { dropError = $0 }
            ) else { return }
            let pieces = imported.map { MediaPiece(assetID: $0.id, start: .zero, end: $0.duration) }
            guard self.timelineID == timelineID else { return }
            if !place(pieces, onLayer: layerID, at: time, kind: kind), kind != nil {
                place(pieces, onLayer: nil, at: time, kind: nil)
            }
        }
    }

    @discardableResult
    private func place(_ pieces: [MediaPiece], onLayer layerID: UUID?, at time: CMTime, kind: LayerKind?) -> Bool {
        var firstClip: (layerID: UUID, clipID: UUID)?
        if let layerID, let added = project.addPieces(pieces, intoLayer: layerID, in: timelineID, at: time, mutingSound: mutesAddedSound),
           let clipID = added.first {
            firstClip = (layerID, clipID)
        } else if let result = project.addPieces(pieces, intoTimeline: timelineID, at: time, kind: kind, mutingSound: mutesAddedSound),
                  let clipID = result.clipIDs.first {
            firstClip = (result.layerID, clipID)
        }
        guard let firstClip else { return false }
        selection = TimelineSelection(timelineID: timelineID, layerID: firstClip.layerID, timelineClipID: firstClip.clipID)
        return true
    }

    /// What the timeline asks for, as its closures did one by one.
    fileprivate func handle(_ action: TimelineAction) {
        switch action {
        case .scrub(let time):
            scrub(to: time)
        case .selectClip(let layerID, let clip):
            selection = TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clip.id)
        case .renameLayer(let layerID, let name):
            project.renameLayer(layerID, in: timelineID, to: name)
        case .moveLayer(let layerID, let offset):
            project.moveLayer(layerID, in: timelineID, by: offset)
        case .moveLayerTo(let layerID, let position):
            project.moveLayer(layerID, in: timelineID, toPositionInKind: position)
        case .moveClip(let layerID, let clipID, let targetLayerID, let newStart):
            project.moveClip(clipID, in: timelineID, layer: layerID, onto: targetLayerID, to: newStart)
            if let targetLayerID, selection?.timelineClipID == clipID,
               project.timeline(id: timelineID)?.layer(id: targetLayerID)?.clips.contains(where: { $0.id == clipID }) == true {
                selection?.layerID = targetLayerID
            }
        case .moveClipToNewLayer(let layerID, let clipID, let kind, let start):
            if let newLayer = project.moveClipToNewLayer(clipID, in: timelineID, layer: layerID, kind: kind, at: start),
               selection?.timelineClipID == clipID {
                selection?.layerID = newLayer
            }
        case .applyJointEdit(let layerID, let clipID, let edit):
            project.applyJointEdit(edit, at: clipID, in: timelineID, layer: layerID)
        case .trimClipStart(let layerID, let clipID, let newTrimStart):
            project.trimClipStart(clipID, in: timelineID, layer: layerID, to: newTrimStart, sceneTracks: analysis.tracks)
        case .trimClipEnd(let layerID, let clipID, let newTrimEnd):
            project.trimClipEnd(clipID, in: timelineID, layer: layerID, to: newTrimEnd, sceneTracks: analysis.tracks)
        case .editVolume(let layerID, let change):
            project.editVolume(of: layerID, in: timelineID, change)
        case .setTransition(let layerID, let clipID, let kind, let edge):
            project.setTransition(kind, at: edge, of: clipID, in: timelineID, layer: layerID)
        case .removeTransition(let layerID, let clipID, let edge):
            project.removeTransition(at: edge, of: clipID, in: timelineID, layer: layerID)
        case .selectTransition(let layerID, let clip, let edge):
            selection = TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clip.id, transitionEdge: edge)
        case .setTransitionCurve(let layerID, let clipID, let edge, let curve):
            project.setTransitionCurve(curve, at: edge, of: clipID, in: timelineID, layer: layerID)
        case .setTransitionDuration(let layerID, let clipID, let edge, let duration):
            project.setTransitionDuration(duration, at: edge, of: clipID, in: timelineID, layer: layerID)
        case .detachAudio(let layerID, let clipIDs):
            project.detachAudio(of: clipIDs, in: timelineID, layer: layerID)
        case .selectLayer:
            selection = nil
        case .openTimeline(let id):
            enterTimeline(id)
        case .deleteClip(let layerID, let clipID):
            project.deleteClip(clipID, in: timelineID, layer: layerID)
            selection = nil
        case .deleteLayer(let layerID):
            project.deleteLayer(layerID, in: timelineID)
            if selection?.layerID == layerID { selection = nil }
        case .bladeClip(let layerID, let clipID, let time):
            project.split(clipID, in: timelineID, layer: layerID, atTimelineTime: time)
        case .slipClip(let layerID, let clipID, let delta):
            project.slipClip(clipID, in: timelineID, layer: layerID, by: delta)
        case .trimPreview(let clip, let frames):
            showTrimPreview(of: clip, frames: frames)
        case .editProject(let change):
            change(&project)
        case .setShowsEffects(let on):
            if on { showsSidePanel = true; sideTab = .effects } else { sideTab = .inspector }
        }
    }

    fileprivate var sceneTracks: [UUID: ChangeScoreTrack] { analysis.tracks }

    fileprivate var currentProject: EditingProject { project }

    // MARK: -

    /// Shows a slipped clip's first and last frames over the viewer, or the
    /// frame at the edge being trimmed, or stops with nil. Only clips with
    /// pictures from a file, and nested timelines, have frames; a nested
    /// timeline's are its own, timed in its frames.
    private func showTrimPreview(of clip: TimelineClip?, frames: TrimPreviewFrames) {
        guard let clip, let timeline else {
            trimPreview.clear()
            return
        }
        let finalFrame = CMTimeMaximum(clip.trimStart, CMTimeSubtract(clip.trimEnd, timeline.frameDuration))
        // Backwards, the clip starts on its trim's last frame.
        let (first, last) = clip.isReversed ? (finalFrame, clip.trimStart) : (clip.trimStart, finalFrame)
        switch clip.source {
        case .media(let mediaID):
            guard let media = project.mediaClip(id: mediaID), media.kind == .video, let url = media.url else { break }
            trimPreview.show(
                .file(url),
                first: media.fileTime(forSourceTime: first),
                last: media.fileTime(forSourceTime: last),
                labelFirst: first,
                labelLast: last,
                frames: frames
            )
            return
        case .timeline(let nestedID):
            guard let preview = nestedPreviews.preview(of: nestedID) else { break }
            trimPreview.show(
                .timeline(preview), first: first, last: last, labelFirst: first, labelLast: last,
                labelFrameRate: project.timeline(id: nestedID)?.frameRate, frames: frames
            )
            return
        default:
            break
        }
        trimPreview.clear()
    }

    /// Scrubbing moves the shared playhead and seeks the player directly —
    /// the player always shows the whole composited timeline (every layer
    /// stacked together), not just one selected clip, so no per-clip time
    /// translation is needed here.
    private func scrub(to time: CMTime) {
        renderer?.noteActivity()
        playheadTime = time
        playback.seek(to: time)
    }

    /// Goes into a nested timeline, from its clip, keeping where it came
    /// from for the breadcrumb.
    private func enterTimeline(_ nestedID: UUID) {
        guard nestedID != timelineID, project.timeline(id: nestedID) != nil else { return }
        trail.append(timelineID)
        trailTarget = nestedID
        selectTimeline(nestedID)
    }

    /// Goes back out to a timeline on the trail, and drops it and what is
    /// after it.
    private func leaveTimeline(to index: Int) {
        guard trail.indices.contains(index) else { return }
        let target = trail[index]
        trail = Array(trail[..<index])
        trailTarget = target
        selectTimeline(target)
    }

    /// Shows a step of a value drag held to one side of the project: heard
    /// at once, its graphs moved, and drawn with the item as it is
    /// (`showValues`). Returns whether the viewer drew it. A step that
    /// changes what the item is built from lets the drag go to the project,
    /// as edits other than drags do.
    private func drawHeld(_ held: EditingProject, after previous: EditingProject?) -> Bool {
        playback.mixCurves.replace(with: MixCurves.of(held))
        graphs.update(project: held)
        let key = CompositionKey(project: viewed(held))
        let before = CompositionKey(project: viewed(previous ?? project))
        // Retiming waits for the mouse to be released; volume and pan need
        // no picture.
        guard key != before, !key.differsOnlyInSpeed(from: before) else { return false }
        if pipeline?.showHeld(source(of: held, held: true)) == true { return true }
        projectState?.letGo()
        return false
    }

    /// A held drag ended, with its last value in the project or, cancelled,
    /// none. The sound, the graphs and the picture go back to the project,
    /// whose values the item draws as it is.
    private func heldDragEnded(drew: Bool) {
        playback.mixCurves.replace(with: MixCurves.of(project))
        graphs.update(project: project)
        if drew { pipeline?.endHeld(source(of: project)) }
    }
}

/// The surface's side of its timeline: what the timeline asks for, done
/// through the surface as it was last drawn (`TimelineEditorSurface.handle`).
/// One object for the surface's life, so the timeline, which compares it
/// by identity, isn't redrawn because the surface was.
///
/// Not observable: the surface sets `surface` as it draws, and a watched
/// write there would ask for another redraw each time.
@MainActor
private final class SurfaceTimelineHost<Library: View>: TimelineHost {
    /// The surface as last drawn; nil once it has disappeared, which lets
    /// go of it (its state holds this host, so holding it would keep both).
    var surface: TimelineEditorSurface<Library>?

    /// The surface to act through. A timeline whose surface has gone asks
    /// for nothing: it is gone too.
    private var current: TimelineEditorSurface<Library>? {
        assert(surface != nil, "The timeline acted after its editor surface disappeared")
        return surface
    }

    func dispatch(_ action: TimelineAction) {
        current?.handle(action)
    }

    func dropScenes(_ payloads: [MediaDragPayload], onLayer layerID: UUID?, at time: CMTime, kind: LayerKind?) -> Bool {
        current?.dropScenes(payloads, onLayer: layerID, at: time, kind: kind) ?? false
    }

    func dropFiles(_ urls: [URL], onLayer layerID: UUID?, at time: CMTime, kind: LayerKind?) {
        current?.dropFiles(urls, onLayer: layerID, at: time, kind: kind)
    }

    func sceneTracks() -> [UUID: ChangeScoreTrack] {
        current?.sceneTracks ?? [:]
    }

    func readProject() -> EditingProject {
        current?.currentProject ?? .empty
    }
}

/// What the area beside the viewer shows.
enum SidePanelTab: String, CaseIterable, Identifiable {
    case inspector, effects

    var id: Self { self }

    var title: String {
        switch self {
        case .inspector: "Inspector"
        case .effects: "Effects"
        }
    }
}

extension TimelineEditorSurface where Library == EmptyView {
    init(
        project: Binding<EditingProject>,
        timelineID: UUID,
        selectTimeline: @escaping (UUID) -> Void = { _ in },
        selection: Binding<TimelineSelection?>,
        playback: PlaybackModel,
        analysis: AssetAnalysis,
        offlineMedia: Set<UUID> = []
    ) {
        self.init(
            project: project, timelineID: timelineID, selectTimeline: selectTimeline, selection: selection,
            playback: playback, analysis: analysis, offlineMedia: offlineMedia
        ) {
            EmptyView()
        }
    }
}

/// A draggable divider that lets the timeline's height be resized relative
/// to the viewer/inspector area above it — previously fixed, splitting the
/// window roughly in half regardless of how much space the timeline needed.
struct TimelineResizeHandle: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var dragStartHeight: CGFloat?
    @State private var isHovering = false

    private var isActive: Bool { isHovering || dragStartHeight != nil }

    var body: some View {
        // A grip rather than a bare line: the seam between the viewer and
        // the timeline is the one divider in the window that moves, so it
        // says so.
        ZStack {
            Design.Surface.raised.color
            Capsule()
                .fill(isActive ? Design.textSecondary : Design.textTertiary.opacity(0.55))
                .frame(width: isActive ? 44 : 28, height: 3)
        }
        .frame(height: 9)
        .overlay(alignment: .top) { Design.hairline.frame(height: 1) }
        .overlay(alignment: .bottom) { Design.hairline.frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .editorAnimation(Design.Motion.select, value: isActive)
        .pointerStyle(.rowResize)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? height
                    if dragStartHeight == nil { dragStartHeight = height }
                    height = min(maxHeight, max(minHeight, start - value.translation.height))
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
    }
}

/// Follows a value drag held to one side of the project (see
/// `ProjectState`) for the surface. Only this reads `held`, so a step of
/// the drag runs this body rather than the surface's.
private struct HeldDragFollower: View {
    let state: ProjectState
    /// Shows a step; returns whether the viewer drew it.
    let draw: (_ held: EditingProject, _ previous: EditingProject?) -> Bool
    /// The drag is no longer held: it ended, or was let go.
    let end: (_ drew: Bool) -> Void
    /// Whether the viewer drew any step of this drag.
    @State private var drew = false

    var body: some View {
        Color.clear
            .onChange(of: state.held) { previous, held in
                if let held {
                    if draw(held, previous) { drew = true }
                } else {
                    end(drew)
                    drew = false
                }
            }
    }
}
