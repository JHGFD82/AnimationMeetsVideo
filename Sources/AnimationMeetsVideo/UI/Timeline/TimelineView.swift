import AppKit
import CoreMedia
import SwiftUI

struct TimelineView: View {
    let project: EditingProject
    let timeline: Timeline
    let timelineID: UUID
    let selection: TimelineSelection?
    let beatTracks: [UUID: BeatTrack]
    let beatClicks: BeatClickPlayer
    /// Read only by the playhead and its timecode while playing; see
    /// `LivePlayheadRail`.
    let playback: PlaybackModel
    /// Where the playhead is parked. It doesn't follow playback, which
    /// would redraw every layer on every tick; it catches up when playback
    /// stops. Not read as this body is built, or every step of the playhead
    /// would build the whole timeline again: the views that show it read it
    /// through `PlayheadReader`, and actions through `playheadTime`.
    let playhead: PlayheadState
    /// Carries out what the timeline asks for: its edits, and what it
    /// changes beyond itself (see `TimelineAction`).
    let host: any TimelineHost
    @Binding var showsEffectsLibrary: Bool
    @Binding var showsSidePanel: Bool
    /// Whether the effects panel is shown (`TimelineAction.setShowsEffects`
    /// shows or hides it).
    /// A value, not a binding: the binding the surface makes for it at each
    /// redraw counts as changed every time, and redrew the timeline twice
    /// per edit.
    let showsEffects: Bool
    @Binding var showsMeter: Bool
    /// What is selected in the effects panel, which gets the Delete key
    /// while it has something selected.
    let effectsState: EffectsPanelState
    /// A clip to zoom to and light up, from Find All (`TimelineClipFocus`).
    var focus: TimelineClipFocus? = nil

    /// Records takes onto the timeline from the header's record button.
    @State var recorder = AudioRecorder()
    @State var showingRecord = false
    @State var recordError: String?

    /// The zoom, the scroll and their edges, which only the tracks follow
    /// (see `TimelineViewportModel`).
    @State var viewportModel = TimelineViewportModel()
    /// The last `focus` shown, so a redraw doesn't zoom to it again.
    @State var shownFocusID: UUID?
    /// The focus whose clip is lit, until its light has faded.
    @State var highlightedFocus: TimelineClipFocus?
    /// Layers showing their volume under their clips.
    @State var volumeRevealed: Set<UUID> = []
    /// Layers showing their video clips' linked audio.
    @State var audioRevealed: Set<UUID> = []
    /// Layers whose sound shows each channel apart: the clips of sound
    /// layers, or the linked audio lane of video layers.
    @State var channelsRevealed: Set<UUID> = []
    /// Which areas show, how they share the height, and each one's layer
    /// height (its vertical zoom).
    @AppStorage(Preferences.timelineAreaLayout) var areaLayout = TimelineAreaLayout()
    /// The layout while a boundary drag, the layer height slider or a
    /// vertical pinch is under way, written to `areaLayout` (and so to the
    /// defaults) once, when it ends; nil otherwise.
    @State var liveAreaLayout: TimelineAreaLayout?
    /// Whether the layer height slider is being dragged. A change without a
    /// drag (VoiceOver, the keyboard) has no end to wait for.
    @State private var isDraggingLayerHeight = false

    /// The layout as shown: the one a gesture is changing, if any.
    var shownAreaLayout: TimelineAreaLayout { liveAreaLayout ?? areaLayout }

    /// Keeps what a gesture did to the layout, now that it has ended.
    func commitLiveAreaLayout() {
        guard let liveAreaLayout else { return }
        areaLayout = liveAreaLayout
        self.liveAreaLayout = nil
    }
    /// Area heights when a drag of the boundary between two areas began.
    @State var boundaryDragStart: [LayerKind: CGFloat]?
    @State var geometryStore = TimelineGeometryStore()
    /// The editor's active panel; Delete goes to the effects panel only
    /// while it is the active one.
    @Environment(ActivePanel.self) var activePanel: ActivePanel?
    @State var autoScroll = TimelineAutoScroll()
    /// Each area's up-and-down scrolling while a drag holds the pointer at
    /// its top or bottom (`EdgeAutoScroll`).
    @State var areaScrollers = Dictionary(uniqueKeysWithValues: LayerKind.allCases.map { ($0, EdgeAutoScroll()) })
    /// What the layer names column offers while a clip or media is dragged
    /// over it; nil otherwise.
    @State var newLayerHover: NewLayerHover?
    @State private var showingViewOptions = false
    @State private var showingNewShape = false
    /// The layer whose beats each timeline shows, kept between launches.
    /// Only layers that still have beats are offered, so a deleted layer
    /// simply stops matching and markers vanish.
    @AppStorage(Preferences.beatMarkerLayers) private var beatMarkerChoices = BeatMarkerChoices()
    private var chosenBeatLayerID: UUID? { beatMarkerChoices.layer(for: timelineID) }
    /// The chosen layer's markers, worked out again only when what they
    /// depend on changes. The view's body runs on every playback tick and
    /// scroll, and a long song has thousands of beats to collect and sort.
    @State var beatMarkers: [BeatMarker] = []
    /// Counts each time `beatMarkers` is worked out, for what is built
    /// from them (the snap targets) to tell they changed without comparing
    /// every beat. Read by `TimelineTrackSurface`, so not private.
    @State var beatMarkersVersion: UInt64 = 0
    /// The layer whose header is being dragged, and how far.
    @State var layerDrag: (id: UUID, dy: CGFloat)?
    /// The height of the layer being resized when the drag began.
    @State var layerResize: (id: UUID, startHeight: CGFloat)?
    /// The layer of a clip being dragged, drawn above the others so the
    /// clip stays visible over the layer it is moving to.
    @State var draggingClipLayerID: UUID?
    /// Clips moving aside for the clip being dragged, by layer.
    @State var pushedClips: (layerID: UUID, clips: [UUID: PushedClip])?
    /// The incoming clip of the joining transition whose footage is open.
    @State var expandedJoint: UUID?
    @State private var headerBarHeight: CGFloat = 32
    /// The layer selected by its header, for Delete. Selecting a clip clears it.
    @State var selectedLayerID: UUID?
    /// Clips picked together with a lasso, two or more (one is selected as
    /// a clip). Selecting anything else lets go of them.
    @State var groupSelection: Set<UUID> = []
    /// The lasso being dragged across the tracks.
    @State var lasso: LassoDrag?
    /// A press in the tracks, in window coordinates, which moves the
    /// playhead there if it comes up as a click rather than a drag.
    @State var playheadClick: CGPoint?
    /// Whether the lasso, let go, is fading out.
    @State var lassoFading = false
    @State var tool: TimelineTool = .arrow
    /// The section selected in the lane under the ruler, for Delete.
    @State var selectedSectionID: UUID?
    @AppStorage(Preferences.snapping) var snapping = true
    /// Whether the view pages along with the playhead while playing.
    @AppStorage(Preferences.followsPlayhead) var followsPlayhead = true
    /// Whether the viewer shows the frame under the pointer as it moves
    /// over the timeline (`skim(atX:viewport:)`).
    @AppStorage(Preferences.timelineSkimming) private var skimming = true
    /// The surface's graph editor panels.
    @Environment(KeyframeGraphHUDs.self) var graphs: KeyframeGraphHUDs?
    @Environment(BeatMatchController.self) private var beatMatch: BeatMatchController?
    @Environment(MotionDesignController.self) var motionDesign: MotionDesignController?
    @Environment(RenderScheduler.self) var renderer: RenderScheduler?
    /// The playhead that drags snap to, brought up to date at each redraw
    /// (see `SnapTargets.playhead`).
    @State var snapPlayhead = LivePlayhead()
    /// Read for the layer volume row during a drag held to one side of the project.
    @Environment(ProjectState.self) var projectState: ProjectState?
    /// What edges snap to, read as a drag snaps: a row isn't redrawn when
    /// another layer's clips move, so it can't be handed them.
    @State var liveSnap = LiveSnapTargets()
    /// The project's structure and snap targets, kept until an edit.
    @State var derived = TimelineDerivedCache()

    /// How close, on screen, an edge must come to a target to snap to it.
    private let snapDistance: CGFloat = 8
    @AppStorage(Preferences.clickOnBeats) private var clickOnBeats = false
    @AppStorage(ClickToneSettings.frequencyKey) private var beatClickFrequency = ClickToneSettings.defaultFrequency
    @AppStorage(ClickToneSettings.volumeKey) private var beatClickVolume = ClickToneSettings.defaultVolume

    let rulerHeight: CGFloat = 28
    /// Two points: the groove between layers is a dark cut with a lit edge
    /// under it, which needs a row of pixels each. The header column and
    /// the track area both lay this out, so layer positions stay aligned.
    let separatorHeight: CGFloat = 2
    /// A slim row under the layers that takes drops as a new layer.
    let newLayerRowHeight: CGFloat = 22
    /// None: the resize grip above sits directly on the timeline's own
    /// rail, so the two read as one edge rather than a seam with a gap.
    private let topPadding: CGFloat = 0
    let zoomStep: CGFloat = 1.5

    /// Only music is analyzed, so only Music layers are offered.
    private var beatLayerChoices: [(id: UUID, name: String)] {
        timeline.layers
            .filter { $0.kind == .music && project.layerHasBeats($0, tracks: beatTracks) }
            .map { (id: $0.id, name: project.displayName(of: $0, in: timeline)) }
    }

    /// Everything `EditingProject.beatMarkers` reads for the chosen layer,
    /// by version: the project's edit, and which beat track each asset has.
    private struct BeatMarkerKey: Equatable {
        var layerID: UUID?
        var editCount: UInt64
        var trackIDs: [UUID: UUID]
    }

    private var beatMarkerKey: BeatMarkerKey {
        BeatMarkerKey(layerID: chosenBeatLayerID, editCount: project.editCount, trackIDs: beatTracks.mapValues(\.id))
    }

    private var beatLayerSelection: Binding<UUID?> {
        Binding(
            get: { beatLayerChoices.contains { $0.id == chosenBeatLayerID } ? chosenBeatLayerID : nil },
            set: { beatMarkerChoices.choose($0, for: timelineID) }
        )
    }
    func viewport(width: CGFloat) -> TimelineViewport {
        viewportModel.viewport(durationSeconds: timeline.duration.seconds, frameRate: timeline.frameRate, width: width)
    }

    /// The viewport as last laid out, for actions that start outside the
    /// layout pass (buttons, keys, the slider).
    var currentViewport: TimelineViewport { viewport(width: viewportModel.trackAreaWidth) }

    var playheadTime: CMTime { playhead.time }

    /// Shows the frame under the pointer, at `x` in the timeline (the
    /// tracks start after the names column), without moving the playhead;
    /// ends the skim off the tracks, or with skimming off. See
    /// docs/audio.md, "Scrubbing".
    func skim(atX x: CGFloat?, viewport: TimelineViewport) {
        guard skimming, let x, x >= labelColumnWidth else {
            playback.endSkim()
            return
        }
        let seconds = viewport.seconds(atX: x - labelColumnWidth).clamped(between: 0, and: timeline.duration.seconds)
        playback.skim(to: timeline.snappedToFrame(CMTime(seconds: seconds, preferredTimescale: 600_000)))
    }

    /// Where the playhead is now: the player's time while it plays, which
    /// `playheadTime` doesn't follow, else the parked time.
    var livePlayheadTime: CMTime {
        playback.isPlaying ? playback.player.currentTime() : playheadTime
    }

    /// Where the selected clips are tied to the music, by the song clip
    /// each holds on to, for the Music layers to mark on their songs.
    var selectedMusicMarks: [UUID: [CMTime]] {
        var ids = groupSelection
        if let selection, selection.timelineID == timelineID { ids.insert(selection.timelineClipID) }
        guard !ids.isEmpty else { return [:] }
        var marks: [UUID: [CMTime]] = [:]
        for layer in timeline.layers where layer.kind != .music {
            for clip in layer.clips where ids.contains(clip.id) {
                guard let music = clip.music, let song = timeline.song(following: music, near: clip.startOffset) else { continue }
                marks[song.id, default: []].append(song.timelineTime(forSourceTime: music.songTime))
            }
        }
        return marks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.step) {
                Text("Timeline")
                    .font(Design.Typeface.panelTitle)
                    .foregroundStyle(Design.textPrimary)
                TimelineToolPicker(current: tool, tool: $tool)
                    .equatable()
                Spacer()
                PlayheadReader(playhead: playhead) { parked in
                    PlayheadTimecode(playback: playback, parked: parked, frameRate: timeline.frameRate)
                }
                TimelineHeaderZoomSliders(
                    timeline: self,
                    vertical: Binding(
                        get: { shownAreaLayout.shownLayerHeightFraction },
                        set: {
                            var layout = liveAreaLayout ?? areaLayout
                            layout.setShownLayerHeightFraction($0)
                            if isDraggingLayerHeight { liveAreaLayout = layout } else { areaLayout = layout }
                        }
                    ),
                    onEditingChanged: { editing in
                        isDraggingLayerHeight = editing
                        if !editing { commitLiveAreaLayout() }
                    }
                )
                // Grouped by what they act on: the view, editing, then
                // which panels are open.
                HStack(spacing: 2) {
                    Button { zoomAroundPlayhead(by: 1 / zoomStep) } label: { Image(systemName: Design.Symbol.zoomOut) }
                        .help("Zoom out (-)")
                        .accessibilityLabel("Zoom out")
                    Button { zoomAroundPlayhead(by: zoomStep) } label: { Image(systemName: Design.Symbol.zoomIn) }
                        .help("Zoom in (=)")
                        .accessibilityLabel("Zoom in")
                    Button {
                        showingViewOptions = true
                    } label: {
                        Image(systemName: Design.Symbol.viewOptions)
                    }
                    .help("View options")
                    .accessibilityLabel("View options")
                    .popover(isPresented: $showingViewOptions) {
                        ViewOptionsPopover(
                            zoomFraction: zoomFractionBinding, onFit: fitToWindow, areaLayout: $areaLayout,
                            followsPlayhead: $followsPlayhead,
                            beatLayers: beatLayerChoices, beatLayerID: beatLayerSelection,
                            clickOnBeats: $clickOnBeats, clickFrequency: $beatClickFrequency,
                            clickVolume: $beatClickVolume, onPreviewClick: { beatClicks.preview() }
                        )
                    }
                    Toggle(isOn: $areaLayout.showsSections) {
                        Image(systemName: "rectangle.split.3x1")
                    }
                    .help(shownAreaLayout.showsSections ? "Hide the sections row" : "Show the sections row")
                    .accessibilityLabel("Sections row")
                }
                .buttonStyle(.icon)
                .toggleStyle(.icon)
                Groove(axis: .vertical).frame(height: 16)
                HStack(spacing: 2) {
                    Button {
                        showingRecord = true
                    } label: {
                        Image(systemName: recorder.isRecording ? "record.circle.fill" : Design.Symbol.record)
                            .foregroundStyle(recorder.isRecording ? Design.statusDanger : Design.textSecondary)
                    }
                    .help(recorder.isRecording ? "Recording: open to stop" : "Record a take from a microphone or an app onto a new Sound layer")
                    .accessibilityLabel(recorder.isRecording ? "Recording" : "Record")
                    .popover(isPresented: $showingRecord) {
                        RecordPopover(recorder: recorder, onRecord: startRecording, onStop: stopRecording, error: recordError)
                    }
                    Toggle(isOn: $snapping) {
                        Image(systemName: Design.Symbol.snap)
                    }
                    .help(snapping ? "Snapping on: edges snap to clips, the playhead and beat markers (N)" : "Snapping off (N)")
                    .accessibilityLabel("Snapping")
                    Button {
                        addAdjustmentLayer()
                    } label: {
                        Image(systemName: "slider.horizontal.below.rectangle")
                    }
                    .help("New adjustment layer: effects applied to the layers below it")
                    .accessibilityLabel("New adjustment layer")
                    Button {
                        showingNewShape = true
                    } label: {
                        Image(systemName: "square.on.circle")
                    }
                    .help("New shape layer at the playhead: a rectangle, ellipse, polygon or star, shaped in the effects panel")
                    .accessibilityLabel("New shape layer")
                    .popover(isPresented: $showingNewShape) {
                        NewShapePopover { kind in
                            showingNewShape = false
                            addShapeLayer(kind)
                        }
                    }
                }
                .buttonStyle(.icon)
                .toggleStyle(.icon)
                Groove(axis: .vertical).frame(height: 16)
                HStack(spacing: 2) {
                    Toggle(isOn: $showsEffectsLibrary) {
                        Image(systemName: "square.grid.2x2")
                    }
                    .help(showsEffectsLibrary ? "Hide the Effects Library" : "Show the Effects Library")
                    .accessibilityLabel("Effects Library")
                    Toggle(isOn: $showsMeter) {
                        Image(systemName: "chart.bar.fill")
                    }
                    .help(showsMeter ? "Hide the audio meter" : "Show the audio meter: every track together, left and right")
                    .accessibilityLabel("Audio meter")
                    Toggle(isOn: $showsSidePanel) {
                        Image(systemName: "sidebar.right")
                    }
                    .help(showsSidePanel ? "Hide the inspector and effects" : "Show the inspector and effects (⇧E for the selected clip's effects)")
                    .accessibilityLabel("Inspector and effects")
                }
                .toggleStyle(.icon)
            }
            .padding(.horizontal, Design.Space.rail)
            .padding(.vertical, Design.Space.close)
            .rail(.raised)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerBarHeight = $0 }

            GeometryReader { geometry in
                TimelineTrackSurface(parent: self, geometry: geometry)
            }
        }
        // Over the pointer while a clip, an edge, a keyframe or a section
        // is dragged.
        .dragTimecodeReadout(frameRate: timeline.frameRate)
        .rubberBandSettling(viewportModel, \.zoomBand)
        .rubberBandSettling(viewportModel, \.scrollBand)
        .rubberBandSettling(viewportModel, \.layerHeightBand)
        // Turned off from the menu, with the pointer still over the tracks.
        .onChange(of: skimming) { _, skimming in
            if !skimming { playback.endSkim() }
        }
        .padding(.top, topPadding)
        .background(KeyPressMonitor(handler: handleKey))
        // The Timeline menu rests while a song is beat matched.
        .focusedSceneValue(\.timelineActions, beatMatch?.isActive == true ? nil : actions)
        .focusedSceneValue(\.timelineEditActions, beatMatch?.isActive == true ? nil : editActions)
        .environment(autoScroll)
        // Again whenever the timeline changes: the closures read its
        // length, through this view's copy of it.
        .onChange(of: timeline.version, initial: true) { _, _ in
            configureAutoScroll()
        }
        // Set up again on coming back, and let go of on leaving: its
        // closures hold this view (`TimelineAutoScroll.detach`).
        .onAppear { configureAutoScroll() }
        .onDisappear { autoScroll.detach() }
        .onChange(of: TimingKey(timeline), initial: true) { old, new in
            keepZoomThroughRetiming(from: old, to: new)
        }
        // The drags' snapping reads where the playhead is now.
        .onChange(of: ObjectIdentifier(playhead), initial: true) { _, _ in
            snapPlayhead.source = { [playhead] in playhead.time }
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil {
                selectedLayerID = nil
                selectedSectionID = nil
                groupSelection = []
            }
        }
        // Clips gone from the timeline (deleted, moved to another timeline)
        // are no longer picked.
        .onChange(of: timeline.version) { _, _ in
            guard !groupSelection.isEmpty else { return }
            let present = Set(timeline.layers.flatMap(\.clips).map(\.id))
            if !groupSelection.isSubset(of: present) { groupSelection.formIntersection(present) }
        }
        // A song dragged in as the only thing on the timeline: show all of
        // it. Not when deleting the rest leaves a song alone.
        // A song just confirmed in Beat Match: show its beats.
        .onChange(of: beatMatch?.confirmation) { _, confirmation in
            guard let confirmation else { return }
            let layer = timeline.layers.first { layer in
                layer.kind == .music && layer.clips.contains { $0.source == .media(confirmation.assetID) }
            }
            if let layer { beatMarkerChoices.choose(layer.id, for: timelineID) }
        }
        .onChange(of: soleMusic) { old, new in
            if new.clipID != nil, new.clipID != old.clipID, new.clipCount >= old.clipCount { fitToWindow() }
        }
        .onChange(of: beatMarkerKey, initial: true) { _, key in
            let markers = key.layerID.flatMap { timeline.layer(id: $0) }.map { project.beatMarkers(in: $0, tracks: beatTracks) } ?? []
            // The key changes with every edit, which mostly leaves the
            // beats where they were; a new version would redraw the
            // timeline for nothing.
            guard markers != beatMarkers else { return }
            beatMarkers = markers
            beatMarkersVersion &+= 1
        }
        .onChange(of: beatMarkers, initial: true) { _, markers in
            beatClicks.beats = markers.map { BeatClickPlayer.Tick(time: $0.time, isDownbeat: $0.isDownbeat) }
        }
        .onChange(of: clickOnBeats, initial: true) { _, on in beatClicks.isEnabled = on }
        .onChange(of: beatClickFrequency, initial: true) { _, hertz in beatClicks.frequency = hertz }
        .onChange(of: beatClickVolume, initial: true) { _, volume in beatClicks.volume = Float(volume) }
        .onChange(of: timelineID) { _, _ in
            viewportModel.reset()
            expandedJoint = nil
            groupSelection = []
            highlightedFocus = nil
        }
        // After this update, so a focus that also switched the timeline
        // comes after the reset above.
        .onChange(of: focus, initial: true) { _, _ in
            Task { showFocusedClip() }
        }
    }

    // MARK: - Sections and layers

    func sectionLane(viewport: TimelineViewport) -> some View {
        let tolerance = snapTolerance(viewport)
        return SectionLane(
            sections: timeline.sections,
            viewport: viewport,
            selectedID: selectedSectionID,
            snap: { [liveSnap] time, owner in liveSnap.targets?.nearest(to: time, within: tolerance, excluding: owner) },
            resolveMove: { id, start in project.resolvedSectionMove(id, in: timelineID, to: start) },
            resolveEdge: { id, edge, time in project.resolvedSectionEdge(id, edge: edge, in: timelineID, to: time) },
            onSelect: { id in
                selectedSectionID = id
                selectedLayerID = nil
                groupSelection = []
                host.dispatch(.selectLayer)
            },
            onCreate: { start, end in
                var created: UUID?
                host.dispatch(.editProject { created = $0.addSection(in: timelineID, from: start, to: end) })
                return created
            },
            onMove: { id, start in host.dispatch(.editProject { $0.moveSection(id, in: timelineID, to: start) }) },
            resolveCopy: { id, start in project.resolvedSectionCopy(id, in: timelineID, to: start) },
            onCopy: { id, start in
                var copied: UUID?
                host.dispatch(.editProject { copied = $0.copySection(id, in: timelineID, to: start) })
                if let copied {
                    selectedSectionID = copied
                    selectedLayerID = nil
                }
            },
            onSetEdge: { id, edge, time in host.dispatch(.editProject { $0.setSectionEdge(id, edge: edge, in: timelineID, to: time) }) },
            onRename: { id, name in host.dispatch(.editProject { $0.renameSection(id, in: timelineID, to: name) }) },
            onDelete: { id in
                host.dispatch(.editProject { $0.deleteSection(id, in: timelineID) })
                if selectedSectionID == id { selectedSectionID = nil }
            },
            onSnapIndicator: { viewportModel.snapIndicator = $0 }
        )
    }

    func drawnBeats(_ viewport: TimelineViewport) -> [CMTime] {
        drawnBeats(pixelsPerSecond: viewport.pixelsPerSecond)
    }

    /// The beat markers drawn, and so snapped to, at a zoom.
    func drawnBeats(pixelsPerSecond: CGFloat) -> [CMTime] {
        BeatMarkerOverlay.drawnMarkers(beatMarkers, pixelsPerSecond: pixelsPerSecond).map(\.time)
    }

    func snapTolerance(_ viewport: TimelineViewport) -> CMTime {
        CMTime(seconds: Double(snapDistance / max(viewport.pixelsPerSecond, 0.0001)), preferredTimescale: 600_000)
    }

    func toggleLinkedAudio(_ layer: TimelineLayer) {
        if audioRevealed.contains(layer.id) { audioRevealed.remove(layer.id) } else { audioRevealed.insert(layer.id) }
    }

    func toggleChannels(_ layer: TimelineLayer) {
        if channelsRevealed.contains(layer.id) { channelsRevealed.remove(layer.id) } else { channelsRevealed.insert(layer.id) }
    }

    /// The disclosure arrow shows the layer's volume row, or hides it.
    func toggleExpanded(_ layer: TimelineLayer) {
        if showsVolume(of: layer) { volumeRevealed.remove(layer.id) } else { volumeRevealed.insert(layer.id) }
    }

    /// Puts an adjustment layer at the top of the stack and selects its clip.
    private func addAdjustmentLayer() {
        var created: (layerID: UUID, clipID: UUID)?
        host.dispatch(.editProject { created = $0.addAdjustmentLayer(to: timelineID, from: .zero) })
        // Selection goes by ID; the view hasn't seen the new clip yet.
        if let created {
            host.dispatch(.selectClip(layer: created.layerID, clip: TimelineClip(id: created.clipID, source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: .zero)))
        }
    }

    /// Puts a shape layer at the top of the stack, starting at the
    /// playhead, and selects its clip.
    func addShapeLayer(_ kind: EffectKind) {
        addGenerator(kind, onLayer: nil, at: playheadTime)
    }

    /// Makes a clip of a generator (text or a shape) at `start` and
    /// selects it: on `layerID` as a clip moved there would land, or on a
    /// new layer at the top for nil.
    func addGenerator(_ kind: EffectKind, onLayer layerID: UUID?, at start: CMTime) {
        var created: (layerID: UUID, clipID: UUID)?
        host.dispatch(.editProject { project in
            created = if let layerID {
                project.addGenerator(kind, to: timelineID, onLayer: layerID, at: start)
            } else {
                project.addShapeLayer(kind, to: timelineID, from: start)
            }
        })
        select(created, at: start)
    }

    /// Makes a clip of a generator at `start` on a new layer just above
    /// `layerID`, over the clip it was dropped on, and selects it.
    func addGenerator(_ kind: EffectKind, above layerID: UUID, at start: CMTime) {
        let index = timeline.layers.firstIndex(id: layerID) ?? 0
        var created: (layerID: UUID, clipID: UUID)?
        host.dispatch(.editProject { created = $0.addShapeLayer(kind, to: timelineID, at: index, from: start) })
        select(created, at: start)
    }

    /// Selects a generator's new clip. Selection goes by ID; the view
    /// hasn't seen the new clip yet.
    private func select(_ created: (layerID: UUID, clipID: UUID)?, at start: CMTime) {
        guard let created else { return }
        host.dispatch(.selectClip(layer: created.layerID, clip: TimelineClip(id: created.clipID, source: .graphic, startOffset: start, trimStart: .zero, trimEnd: .zero)))
    }

    func deleteLayer(_ id: UUID) {
        if selectedLayerID == id { selectedLayerID = nil }
        host.dispatch(.deleteLayer(id))
    }

    /// Conform Timeline to Clip: the timeline takes the clip's frame size,
    /// read from its file, its frame rate and its colour space, as one edit.
    func conformTimeline(to clip: TimelineClip) {
        guard case .media(let id) = clip.source, let media = project.mediaClip(id: id) else { return }
        let timelineID = timelineID
        Task { @MainActor in
            let size = await MediaFile.pictureSize(of: media)
            host.dispatch(.editProject { $0.conformTimeline(timelineID, to: media, frameSize: size) })
        }
    }
}

extension TimelineView: Equatable {
    /// What the timeline draws from (the editor marks it `.equatable()`):
    /// its own timeline as it is, values included, for its lanes and volume
    /// lines; the rest of the project without values or this timeline's
    /// clips (`EditingProject.structure(withoutClipsIn:)`), for the media,
    /// nested timelines and layers' names it shows; the selection, the clip
    /// it is asked to focus on, and the panels it toggles. Not the
    /// playhead, which views of their own follow (`PlayheadState`), so a
    /// tick of it, or an edit of another timeline's values, doesn't redraw
    /// it. Its actions read the project as they act, not as it was drawn.
    ///
    /// The project and its timeline go by their edit stamps (`EditStamp`)
    /// rather than by what they hold; only an edit that left this timeline
    /// as it was is worth taking the rest of the project apart for.
    nonisolated static func == (lhs: TimelineView, rhs: TimelineView) -> Bool {
        MainActor.assumeIsolated {
            lhs.playback === rhs.playback
                && lhs.playhead === rhs.playhead
                && lhs.host === rhs.host
                && lhs.effectsState === rhs.effectsState
                && lhs.timelineID == rhs.timelineID
                && lhs.selection == rhs.selection
                && lhs.focus == rhs.focus
                && lhs.showsEffects == rhs.showsEffects
                && lhs.showsEffectsLibrary == rhs.showsEffectsLibrary
                && lhs.showsSidePanel == rhs.showsSidePanel
                && lhs.showsMeter == rhs.showsMeter
                && lhs.beatTracks.keys == rhs.beatTracks.keys
                && lhs.beatTracks.allSatisfy { rhs.beatTracks[$0.key]?.id == $0.value.id }
                && drawsSameProject(lhs, rhs)
        }
    }

    private static func drawsSameProject(_ lhs: TimelineView, _ rhs: TimelineView) -> Bool {
        let (left, right) = (lhs.project, rhs.project)
        if left.editCount != 0, left.editCount == right.editCount { return true }
        let stamped = lhs.timeline.version != 0 && rhs.timeline.version != 0
        if stamped, lhs.timeline.version != rhs.timeline.version { return false }
        if !stamped, lhs.timeline != rhs.timeline { return false }
        return left.structure(withoutClipsIn: lhs.timelineID) == right.structure(withoutClipsIn: rhs.timelineID)
    }
}
