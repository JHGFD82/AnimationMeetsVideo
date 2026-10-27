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
    /// tell it from one chosen another way (the menu), which starts over.
    @State private var trailTarget: UUID?

    private var playheadTime: CMTime {
        get { playhead.time }
        nonmutating set { playhead.time = newValue }
    }
    @State private var trimPreview = TrimPreviewModel()
    @State private var buildTask: Task<Void, Never>?
    /// Where the player item rebuild is. Edits that arrive while one is
    /// building wait their turn (see `rebuildPlayerItem`).
    @State private var buildPhase: BuildPhase = .idle
    @State private var rebuildQueued = false
    @State private var buildID = UUID()
    @State private var buildError: String?
    /// Why a file dragged in from the Finder couldn't be imported.
    @State private var dropError: String?
    /// A render finished while playing; its rebuild waits for a pause,
    /// since swapping the item mid-play freezes the picture.
    @State private var renderRebuildPending = false
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

    /// A value is being dragged: a change of structure meanwhile is built
    /// when it ends (`rebuildDeferred`), and nothing renders until then.
    @State private var isGesturing = false
    @State private var rebuildDeferred = false
    /// Values were edited since the renderer's plan was made, so its pieces
    /// are named for the old ones (`refreshRenderPlan`).
    @State private var renderPlanStale = false
    @State private var renderPlanTask: Task<Void, Never>?
    /// The renderer waits from a gesture's start until what follows its
    /// end (a build swapped in, or the plan made again) is done.
    @State private var rendererHeld = false

    /// How many effects the selected clip has, to notice one being applied.
    private struct AppliedEffects: Equatable {
        var clipID: UUID
        var count: Int
    }

    private var appliedEffects: AppliedEffects? {
        selectedTimelineClip.map { AppliedEffects(clipID: $0.id, count: $0.effects.count + $0.audioEffects.count) }
    }

    private enum BuildPhase { case idle, building, settling }

    /// How long edits must pause before the player item is swapped. Until
    /// then the viewer shows frames drawn from each edit (`showValues`).
    private let settleDelay = Duration.milliseconds(300)

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

    private var compositionKey: CompositionKey { CompositionKey(project: viewedProject) }

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
                        buildError: buildError,
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
        // While a value is dragged the viewer follows it with the frames it
        // has (`showValues`), and a change of structure (speed) is built
        // when the mouse is released. A stretch playing from a render, which
        // can't take new values, gives way to its clips at the start, so no
        // step of the drag waits on anything. Nothing renders in the
        // background meanwhile, though the pointer may rest, nor until what
        // follows the drag is done: a render would compete with its frames.
        .onReceive(NotificationCenter.default.publisher(for: .valueGestureDidBegin)) { _ in
            isGesturing = true
            rendererHeld = true
            renderer?.setInteracting(true)
            playback.playWithoutRenders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .valueGestureDidEnd)) { _ in
            isGesturing = false
            renderer?.noteActivity()
            if rebuildDeferred {
                rebuildDeferred = false
                rebuildPlayerItem()
            } else if renderPlanStale {
                rebuildPlayerItem(swapsItem: false)
            } else {
                releaseRenderer()
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
            // Show Up to Here lets go of an effect that is gone.
            if effectsState.showUpTo != nil, partialView == nil { effectsState.showUpTo = nil }
        }
        .onAppear {
            playhead.liveTime = { [playback] in playback.isPlaying ? playback.player.currentTime() : nil }
            let project = $project
            graphs.onEdit = { change in change(&project.wrappedValue) }
            graphs.onSeek = { time in scrub(to: time) }
            graphs.onTogglePlayback = { playback.togglePlayback() }
            graphs.playback = playback
        }
        .onDisappear { graphs.closeAll() }
        .onChange(of: timelineID) { _, newValue in
            if newValue != trailTarget { trail = [] }
            trailTarget = nil
            if selection?.timelineID != newValue {
                selection = nil
            }
            playback.player.pause()
            playheadTime = .zero
            rebuildPlayerItem(resetPosition: true)
        }
        .onChange(of: compositionKey) { _, _ in
            renderer?.noteActivity()
            let viewed = viewedProject
            if StructureKey(project: viewed) == playback.playedKey {
                // Only values changed (a drag, typed, undone): the item
                // draws them as it is, paused or playing, with nothing
                // built (`LiveValues`). The renderer's plan is made again
                // once the edits pause, since its pieces are named for
                // what they show.
                playback.showValues(viewed.clipsByID)
                if buildPhase != .idle { rebuildPlayerItem() }
                renderPlanStale = true
                if !isGesturing { refreshRenderPlan() }
                return
            }
            playback.liveValues.clips = viewed.clipsByID
            if isGesturing {
                // Built when the mouse is released.
                rebuildDeferred = true
            } else {
                rebuildPlayerItem()
            }
        }
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
            renderer?.setPlaying(playing)
            if !playing, renderRebuildPending {
                renderRebuildPending = false
                rebuildPlayerItem()
            }
        }
        // A finished render plays once the item is rebuilt with it.
        // Renders only run while paused, but one can finish just as play
        // is pressed.
        .onChange(of: renderer?.finishedCount) { _, _ in
            if playback.isPlaying {
                renderRebuildPending = true
            } else {
                rebuildPlayerItem()
            }
        }
        .messageAlert("Import Failed", message: $dropError)
        .onChange(of: renderer?.packageURL) { _, _ in
            rebuildPlayerItem()
        }
        // Motion blur on or off in the viewer redraws what it shows.
        .onChange(of: playback.motionBlurInPreview) { _, _ in
            rebuildPlayerItem()
        }
        // The file check found media gone or back.
        .onChange(of: offlineMedia) { _, _ in
            rebuildPlayerItem()
        }
        .onAppear {
            rebuildPlayerItem(resetPosition: true)
        }
    }

    @ViewBuilder
    private var timelineView: some View {
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
                onScrub: { time in scrub(to: time) },
                onSelectClip: { layerID, clip in
                    selection = TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clip.id)
                },
                onRenameLayer: { layerID, name in project.renameLayer(layerID, in: timelineID, to: name) },
                onMoveLayer: { layerID, offset in project.moveLayer(layerID, in: timelineID, by: offset) },
                onMoveLayerTo: { layerID, position in project.moveLayer(layerID, in: timelineID, toPositionInKind: position) },
                onMoveClip: { layerID, clipID, targetLayerID, newStart in
                    project.moveClip(clipID, in: timelineID, layer: layerID, onto: targetLayerID, to: newStart)
                    if let targetLayerID, selection?.timelineClipID == clipID,
                       project.timeline(id: timelineID)?.layer(id: targetLayerID)?.clips.contains(where: { $0.id == clipID }) == true {
                        selection?.layerID = targetLayerID
                    }
                },
                onMoveClipToNewLayer: { layerID, clipID, kind, start in
                    if let newLayer = project.moveClipToNewLayer(clipID, in: timelineID, layer: layerID, kind: kind, at: start),
                       selection?.timelineClipID == clipID {
                        selection?.layerID = newLayer
                    }
                },
                onDropScenes: { payloads, layerID, time, kind in dropScenes(payloads, onLayer: layerID, at: time, kind: kind) },
                onDropFiles: { urls, layerID, time, kind in dropFiles(urls, onLayer: layerID, at: time, kind: kind) },
                onApplyJointEdit: { layerID, clipID, edit in
                    project.applyJointEdit(edit, at: clipID, in: timelineID, layer: layerID)
                },
                onTrimClipStart: { layerID, clipID, newTrimStart in
                    project.trimClipStart(clipID, in: timelineID, layer: layerID, to: newTrimStart, sceneTracks: analysis.tracks)
                },
                onTrimClipEnd: { layerID, clipID, newTrimEnd in
                    project.trimClipEnd(clipID, in: timelineID, layer: layerID, to: newTrimEnd, sceneTracks: analysis.tracks)
                },
                sceneTracks: { [analysis] in analysis.tracks },
                onEditVolume: { layerID, change in
                    project.editVolume(of: layerID, in: timelineID, change)
                },
                onSetTransition: { layerID, clipID, kind, edge in
                    project.setTransition(kind, at: edge, of: clipID, in: timelineID, layer: layerID)
                },
                onRemoveTransition: { layerID, clipID, edge in
                    project.removeTransition(at: edge, of: clipID, in: timelineID, layer: layerID)
                },
                onSelectTransition: { layerID, clip, edge in
                    selection = TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clip.id, transitionEdge: edge)
                },
                onSetTransitionCurve: { layerID, clipID, edge, curve in
                    project.setTransitionCurve(curve, at: edge, of: clipID, in: timelineID, layer: layerID)
                },
                onDetachAudio: { layerID, clipIDs in
                    project.detachAudio(of: clipIDs, in: timelineID, layer: layerID)
                },
                onSelectLayer: { selection = nil },
                onOpenTimeline: { enterTimeline($0) },
                onDeleteClip: { layerID, clipID in
                    project.deleteClip(clipID, in: timelineID, layer: layerID)
                    selection = nil
                },
                onDeleteLayer: { layerID in
                    project.deleteLayer(layerID, in: timelineID)
                    if selection?.layerID == layerID { selection = nil }
                },
                onBladeClip: { layerID, clipID, time in
                    project.split(clipID, in: timelineID, layer: layerID, atTimelineTime: time)
                },
                onSlipClip: { layerID, clipID, delta in
                    project.slipClip(clipID, in: timelineID, layer: layerID, by: delta)
                },
                onTrimPreview: { clip, frames in showTrimPreview(of: clip, frames: frames) },
                onSetTransitionDuration: { layerID, clipID, edge, duration in
                    project.setTransitionDuration(duration, at: edge, of: clipID, in: timelineID, layer: layerID)
                },
                onEditProject: { change in change(&project) },
                readProject: { project },
                showsEffectsLibrary: $showsEffectsLibrary,
                showsSidePanel: $showsSidePanel,
                showsEffects: showsSidePanel && sideTab == .effects,
                setShowsEffects: { on in
                    if on { showsSidePanel = true; sideTab = .effects } else { sideTab = .inspector }
                },
                showsMeter: $showsMeter,
                effectsState: effectsState,
                focus: clipFocus
            )
        } else {
            ContentUnavailableView("No Timeline Selected", systemImage: "timeline.selection")
        }
    }

    /// Media dragged from the browser becomes ordinary clips, back to back
    /// in the order it was dragged. Dropped on a layer it goes onto it at the
    /// drop time, if it all fits and the layer is the right kind; otherwise,
    /// or dropped elsewhere, onto new layers at the top, of `kind` or each
    /// asset's default kind.
    private func dropScenes(_ payloads: [MediaDragPayload], onLayer layerID: UUID?, at time: CMTime, kind: LayerKind? = nil) -> Bool {
        place(payloads.flatMap(\.pieces), onLayer: layerID, at: time, kind: kind)
    }

    /// Files dragged in from the Finder are imported into the library, then
    /// placed whole as media dropped there would be. A kind they don't all
    /// suit gives way to each file's own.
    private func dropFiles(_ urls: [URL], onLayer layerID: UUID?, at time: CMTime, kind: LayerKind?) {
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

    // MARK: -

    /// Shows a slipped clip's first and last frames over the viewer, or the
    /// frame at the edge being trimmed, or stops with nil. Only clips with
    /// pictures from a file have frames.
    private func showTrimPreview(of clip: TimelineClip?, frames: TrimPreviewFrames) {
        guard let clip, let timeline, case .media(let mediaID) = clip.source,
              let media = project.mediaClip(id: mediaID), media.kind == .video, let url = media.url
        else {
            trimPreview.clear()
            return
        }
        let finalFrame = CMTimeMaximum(clip.trimStart, CMTimeSubtract(clip.trimEnd, timeline.frameDuration))
        // Backwards, the clip starts on its trim's last frame.
        let (first, last) = clip.isReversed ? (finalFrame, clip.trimStart) : (clip.trimStart, finalFrame)
        trimPreview.show(
            url: url,
            first: media.fileTime(forSourceTime: first),
            last: media.fileTime(forSourceTime: last),
            labelFirst: first,
            labelLast: last,
            frames: frames
        )
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
        let viewed = viewed(held)
        let key = CompositionKey(project: viewed)
        let before = previous.map { CompositionKey(project: self.viewed($0)) } ?? compositionKey
        // Retiming waits for the mouse to be released (see
        // `onChange(of: compositionKey)`); volume and pan need no picture.
        guard key != before, !key.differsOnlyInSpeed(from: before) else { return false }
        renderer?.noteActivity()
        // What plays was built before the drag, with its values in it; the
        // compositor draws every frame with the drag's instead, paused or
        // playing, when only values changed. Letting the drag go would
        // write every step to the project.
        if StructureKey(project: viewed) == playback.playedKey {
            playback.showValues(viewed.clipsByID)
            return true
        }
        projectState?.letGo()
        return false
    }

    /// A held drag ended, with its last value in the project or, cancelled,
    /// none. The sound, the graphs and the picture go back to the project,
    /// whose values the item draws as it is.
    private func heldDragEnded(drew: Bool) {
        playback.mixCurves.replace(with: MixCurves.of(project))
        graphs.update(project: project)
        if drew { playback.showValues(viewedProject.clipsByID) }
    }

    /// Makes the renderer's plan again once value edits have paused for
    /// `settleDelay`: the item draws the edits as it is, but the pieces to
    /// render are named for what they show. Nothing is swapped.
    private func refreshRenderPlan() {
        renderPlanTask?.cancel()
        let delay = settleDelay
        renderPlanTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, renderPlanStale, !isGesturing else { return }
            rebuildPlayerItem(swapsItem: false)
        }
    }

    /// Lets the renderer go back to work after a gesture, once what
    /// followed it is done.
    private func releaseRenderer() {
        guard rendererHeld, !isGesturing else { return }
        rendererHeld = false
        renderer?.setInteracting(false)
    }

    /// Rebuilds the player item from the current project. Keeps the
    /// position and play state the player has when the build *finishes*,
    /// not when it started, so edits made during playback don't jump back.
    ///
    /// A rebuild is never cancelled by the next edit, or a fast drag would
    /// cancel every build before it finished and nothing would draw until
    /// the drag ended. An edit that arrives during a build is queued and
    /// built when the current one is done. Paused, a finished build is
    /// swapped in at once; the viewer keeps its picture until the new
    /// item's frame is there (`PlaybackModel.swap`). Playing, it is swapped
    /// once edits have paused for `settleDelay`.
    ///
    /// Without `swapsItem` it only makes the renderer's plan again, for
    /// values edited since (`refreshRenderPlan`); a build that swaps the
    /// item does that too.
    private func rebuildPlayerItem(resetPosition: Bool = false, swapsItem: Bool = true) {
        if resetPosition {
            buildTask?.cancel()
            buildTask = nil
            buildID = UUID()
            buildPhase = .idle
            rebuildQueued = false
        }
        guard let timeline, timeline.layers.contains(where: { !$0.clips.isEmpty }) else {
            buildTask?.cancel()
            buildTask = nil
            buildID = UUID()
            buildPhase = .idle
            rebuildQueued = false
            playback.clearItem()
            buildError = nil
            renderer?.update(project: project, timelineID: timelineID, segments: [])
            renderPlanStale = false
            releaseRenderer()
            return
        }
        switch buildPhase {
        case .building:
            rebuildQueued = true
            return
        case .settling:
            // Waiting out the delay with an item built: this edit replaces it.
            buildTask?.cancel()
        case .idle:
            break
        }
        let project = self.viewedProject
        let isPartial = partialView != nil
        let realProject = self.project
        let tID = timelineID
        let player = playback.player
        let playback = playback
        let frameRate = timeline.frameRate
        let renderer = renderer
        let id = UUID()
        buildID = id
        buildPhase = .building
        rebuildQueued = false
        renderPlanTask?.cancel()
        renderPlanTask = nil
        renderPlanStale = false
        /// Ends this build, starting the queued one if there is one. A
        /// build replaced since it began leaves things to its successor.
        func finish() {
            guard buildID == id else { return }
            buildTask = nil
            buildPhase = .idle
            if rebuildQueued {
                rebuildQueued = false
                rebuildPlayerItem()
            } else {
                releaseRenderer()
            }
        }
        buildTask = Task {
            do {
                let composed = try await CompositionExporter.buildComposedTimeline(
                    for: project, timelineID: tID, forPreview: true, meter: playback.meter, options: playback.drawingOptions,
                    cache: isPartial ? nil : renderer?.cache
                )
                guard buildID == id else { return }
                // A clip cut short isn't what renders are for.
                renderer?.update(project: realProject, timelineID: tID, segments: isPartial ? [] : composed.segments)
                guard swapsItem else {
                    buildError = nil
                    finish()
                    return
                }
                let wasPaused = player.timeControlStatus == .paused
                if wasPaused, isGesturing, !resetPosition {
                    // The item is swapped when the drag ends.
                    rebuildDeferred = true
                    finish()
                    return
                }
                if !wasPaused, !resetPosition {
                    // Playing: every swap stalls the player while the new
                    // item is readied, so a run of edits (a slider dragged
                    // across a clip's own-mix threshold) swaps once, when it
                    // has paused, and not after every step.
                    buildPhase = .settling
                    if rebuildQueued {
                        finish()
                        return
                    }
                    try await Task.sleep(for: settleDelay)
                    guard buildID == id else { return }
                    buildPhase = .building
                }
                let item = AVPlayerItem(asset: composed.composition)
                playback.prepare(item, with: composed, key: StructureKey(project: project), frameRate: frameRate)
                // The viewer keeps its picture until the new item's frame
                // is there (`PlaybackModel.swap`).
                let playing = !resetPosition && player.timeControlStatus != .paused
                let resumeTime = resetPosition ? playheadTime : player.currentTime()
                await playback.swap(to: item, at: resumeTime, playing: playing)
                guard buildID == id else { return }
                buildError = nil
                finish()
            } catch is CancellationError {
                finish()
            } catch {
                if buildID == id {
                    if let compositionError = error as? CompositionError, case .emptyTimeline = compositionError {
                        playback.clearItem()
                        buildError = nil
                    } else {
                        buildError = error.localizedDescription
                    }
                }
                finish()
            }
        }
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
