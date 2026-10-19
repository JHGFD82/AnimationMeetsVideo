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
    let onScrub: (CMTime) -> Void
    let onSelectClip: (UUID, TimelineClip) -> Void
    let onRenameLayer: (UUID, String?) -> Void
    let onMoveLayer: (UUID, Int) -> Void
    /// Moves a layer to a place among the layers of its kind, after
    /// dragging its header.
    let onMoveLayerTo: (UUID, Int) -> Void
    /// Layer, clip, the layer it moves to if another, and its new start.
    let onMoveClip: (UUID, UUID, UUID?, CMTime) -> Void
    /// Layer, clip and the kind of new layer, at the top, to move it onto.
    let onMoveClipToNewLayer: (UUID, UUID, LayerKind, CMTime) -> Void
    /// Scenes dropped on a layer at a time, or with no layer, onto a new
    /// layer of the given kind (the asset's default kind when nil).
    let onDropScenes: ([MediaDragPayload], UUID?, CMTime, LayerKind?) -> Bool
    /// Files dragged in from the Finder: imported, then placed as media
    /// dropped there would be, onto the layer if given, else onto a new
    /// layer of the kind.
    let onDropFiles: ([URL], UUID?, CMTime, LayerKind?) -> Void
    let onApplyJointEdit: (UUID, UUID, JointEdit) -> Void
    let onTrimClipStart: (UUID, UUID, CMTime) -> Void
    let onTrimClipEnd: (UUID, UUID, CMTime) -> Void
    let onEditVolume: (UUID, (inout AnimatedValue<Double>) -> Void) -> Void
    let onSetTransition: (UUID, UUID, TransitionKind, TransitionEdge) -> Void
    let onRemoveTransition: (UUID, UUID, TransitionEdge) -> Void
    let onSelectTransition: (UUID, TimelineClip, TransitionEdge) -> Void
    let onSetTransitionCurve: (UUID, UUID, TransitionEdge, TransitionCurve) -> Void
    /// Detaches the sound of the given clips on a layer, or of all its
    /// linked clips when nil.
    let onDetachAudio: (UUID, Set<UUID>?) -> Void
    /// A layer was selected, which clears any clip selection.
    let onSelectLayer: () -> Void
    let onDeleteClip: (UUID, UUID) -> Void
    let onDeleteLayer: (UUID) -> Void
    /// Layer, clip and the timeline time to split it at, from the blade.
    let onBladeClip: (UUID, UUID, CMTime) -> Void
    /// Layer, clip and how far to slip its footage (positive plays later footage).
    let onSlipClip: (UUID, UUID, CMTime) -> Void
    /// The clip as a slip drag would leave it, for the viewer to show its
    /// first and last frames; nil when the drag ends.
    let onTrimPreview: (TimelineClip?) -> Void
    let onSetTransitionDuration: (UUID, UUID, TransitionEdge, CMTime) -> Void
    /// Applies a change to the project, for the section lane.
    let onEditProject: ((inout EditingProject) -> Void) -> Void
    /// The project as it is now, for what runs later than the redraw that
    /// made it: the Edit menu keeps its commands while what they act on
    /// is unchanged, and `project` in them would be as it was then.
    let readProject: () -> EditingProject
    @Binding var showsEffectsLibrary: Bool
    @Binding var showsSidePanel: Bool
    /// Whether the effects panel is shown, and the way to show or hide it.
    /// A value, not a binding: the binding the surface makes for it at each
    /// redraw counts as changed every time, and redrew the timeline twice
    /// per edit.
    let showsEffects: Bool
    let setShowsEffects: (Bool) -> Void
    @Binding var showsMeter: Bool
    /// What is selected in the effects panel, which gets the Delete key
    /// while it has something selected.
    let effectsState: EffectsPanelState

    /// The chosen zoom, or nil while the whole timeline is fitted to the
    /// window. Kept in points per second, not relative to the fit, so
    /// moving a clip past the end doesn't rescale everything.
    /// Records takes onto the timeline from the header's record button.
    @State var recorder = AudioRecorder()
    @State var showingRecord = false
    @State var recordError: String?

    @State var zoomedPixelsPerSecond: CGFloat?
    /// The time zoom's edge: a zoom past the fit or the closest stretches
    /// the tracks and springs back.
    @State var zoomBand = RubberBandZoom()
    /// The sideways scroll's edge: past the start or end of the timeline
    /// the tracks slide on and spring back. Time zooms, so it bounces;
    /// the areas scroll up and down in system scroll views, which do too.
    @State var scrollBand = RubberBandScroll()
    /// The same for a vertical pinch's layer height, in the area it pinched.
    @State var layerHeightBand = RubberBandZoom()
    @State var layerHeightBandKind: LayerKind?
    @State var scrollX: CGFloat = 0
    @State var trackAreaWidth: CGFloat = 800
    /// Layers showing their volume under their clips.
    @State var volumeRevealed: Set<UUID> = []
    /// Layers showing their video clips' linked audio.
    @State private var audioRevealed: Set<UUID> = []
    /// Layers whose sound shows each channel apart: the clips of sound
    /// layers, or the linked audio lane of video layers.
    @State private var channelsRevealed: Set<UUID> = []
    /// Which areas show, how they share the height, and each one's layer
    /// height (its vertical zoom).
    @AppStorage(Preferences.timelineAreaLayout) var areaLayout = TimelineAreaLayout()
    /// Area heights when a drag of the boundary between two areas began.
    @State private var boundaryDragStart: [LayerKind: CGFloat]?
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
    /// The layer whose beats are shown. Only layers that still have beats are
    /// offered, so a deleted layer simply stops matching and markers vanish.
    @State private var chosenBeatLayerID: UUID?
    /// The chosen layer's markers, worked out again only when what they
    /// depend on changes. The view's body runs on every playback tick and
    /// scroll, and a long song has thousands of beats to collect and sort.
    @State private var beatMarkers: [BeatMarker] = []
    /// The layer whose header is being dragged, and how far.
    @State var layerDrag: (id: UUID, dy: CGFloat)?
    /// The height of the layer being resized when the drag began.
    @State private var layerResize: (id: UUID, startHeight: CGFloat)?
    /// The layer of a clip being dragged, drawn above the others so the
    /// clip stays visible over the layer it is moving to.
    @State private var draggingClipLayerID: UUID?
    /// Clips moving aside for the clip being dragged, by layer.
    @State var pushedClips: (layerID: UUID, clips: [UUID: PushedClip])?
    /// The incoming clip of the joining transition whose footage is open.
    @State private var expandedJoint: UUID?
    @State private var headerBarHeight: CGFloat = 32
    /// The layer selected by its header, for Delete. Selecting a clip clears it.
    @State var selectedLayerID: UUID?
    @State var tool: TimelineTool = .arrow
    /// The section selected in the lane under the ruler, for Delete.
    @State var selectedSectionID: UUID?
    @AppStorage(Preferences.snapping) var snapping = true
    /// Whether the view pages along with the playhead while playing.
    @AppStorage(Preferences.followsPlayhead) private var followsPlayhead = true
    /// The surface's graph editor panels.
    @Environment(KeyframeGraphHUDs.self) private var graphs: KeyframeGraphHUDs?
    @Environment(BeatMatchController.self) private var beatMatch: BeatMatchController?
    @Environment(RenderScheduler.self) var renderer: RenderScheduler?
    /// Where a drag in progress snapped, drawn as a line across the layers.
    @State private var snapIndicator: CMTime?
    /// The playhead that drags snap to, brought up to date at each redraw
    /// (see `SnapTargets.playhead`).
    @State private var snapPlayhead = LivePlayhead()
    /// Read for the layer volume row during a drag held to one side of the project.
    @Environment(ProjectState.self) private var projectState: ProjectState?
    /// What edges snap to, read as a drag snaps: a row isn't redrawn when
    /// another layer's clips move, so it can't be handed them.
    @State private var liveSnap = LiveSnapTargets()

    /// How close, on screen, an edge must come to a target to snap to it.
    private let snapDistance: CGFloat = 8
    @AppStorage(Preferences.clickOnBeats) private var clickOnBeats = false
    @AppStorage(ClickToneSettings.frequencyKey) private var beatClickFrequency = ClickToneSettings.defaultFrequency
    @AppStorage(ClickToneSettings.volumeKey) private var beatClickVolume = ClickToneSettings.defaultVolume

    private let rulerHeight: CGFloat = 28
    /// Two points: the groove between layers is a dark cut with a lit edge
    /// under it, which needs a row of pixels each. The header column and
    /// the track area both lay this out, so layer positions stay aligned.
    private let separatorHeight: CGFloat = 2
    /// A slim row under the layers that takes drops as a new layer.
    private let newLayerRowHeight: CGFloat = 22
    /// None: the resize grip above sits directly on the timeline's own
    /// rail, so the two read as one edge rather than a seam with a gap.
    private let topPadding: CGFloat = 0

    /// The joining transition whose footage is open on this layer.
    private func shownJoint(in layer: TimelineLayer) -> TransitionJoint? {
        guard let id = expandedJoint, layer.clips.contains(where: { $0.id == id }) else { return nil }
        return project.joint(at: id, in: timelineID, layer: layer.id)
    }

    /// Everything one layer shows, top to bottom. The header column and the
    /// track area lay out the same rows, so this is each layer's height in
    /// both.
    func blockHeight(of layer: TimelineLayer) -> CGFloat {
        clipRowHeight(of: layer)
            + (shownJoint(in: layer) != nil ? TransitionFootageLane.height : 0)
            + (showsLinkedAudio(of: layer) ? audioLaneHeight(of: layer) : 0)
            + (showsVolume(of: layer) ? VolumeLane.height : 0)
            + separatorHeight
    }

    /// The layers an area shows, top to bottom.
    func areaLayers(_ kind: LayerKind) -> [TimelineLayer] {
        timeline.layers.filter { $0.kind == kind }
    }

    /// Where each of `layers` starts, from the top of its area.
    func tops(of layers: [TimelineLayer]) -> [CGFloat] {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for layer in layers {
            tops.append(y)
            y += blockHeight(of: layer)
        }
        return tops
    }

    /// Linked audio is shown under video, at a little over half its height,
    /// or tall enough for two channels when they're shown apart.
    private func audioLaneHeight(of layer: TimelineLayer) -> CGFloat {
        let lane = max(22, (areaLayout.height(of: layer.id, kind: layer.kind) * 0.6).rounded())
        return showsChannels(of: layer) ? max(lane, Self.channelBandHeight) * 2 : lane
    }

    private func showsLinkedAudio(of layer: TimelineLayer) -> Bool {
        audioRevealed.contains(layer.id) && project.layerHasLinkedAudio(layer)
    }

    /// The shortest band one channel gets when a layer shows them apart.
    private static let channelBandHeight: CGFloat = 32

    /// Whether the layer's sound has channels to show apart: sound layers
    /// always, video layers while their linked audio is shown.
    private func canShowChannels(of layer: TimelineLayer) -> Bool {
        layer.kind == .video ? showsLinkedAudio(of: layer) : true
    }

    private func showsChannels(of layer: TimelineLayer) -> Bool {
        channelsRevealed.contains(layer.id) && canShowChannels(of: layer)
    }

    /// Adjustment layers' one fixed height: their clips have no picture or
    /// sound to show, only a name, so they aren't resized.
    static let adjustmentRowHeight: CGFloat = 28

    /// The clips' row: the layer's height, doubled (with a floor) on sound
    /// layers showing their channels, so each gets a band. Adjustment
    /// layers are always `adjustmentRowHeight`.
    private func clipRowHeight(of layer: TimelineLayer) -> CGFloat {
        if layer.isAdjustment { return Self.adjustmentRowHeight }
        let height = areaLayout.height(of: layer.id, kind: layer.kind)
        guard layer.kind != .video, showsChannels(of: layer) else { return height }
        return max(height, Self.channelBandHeight) * 2
    }
    let zoomStep: CGFloat = 1.5

    /// Wider while a volume row is showing, to fit its values.
    private var labelColumnWidth: CGFloat {
        timeline.layers.contains { showsVolume(of: $0) } ? 300 : 150
    }

    func showsVolume(of layer: TimelineLayer) -> Bool {
        volumeRevealed.contains(layer.id) && hasProperties(layer)
    }

    /// Whether the layer's clips draw their volume across them: while L is
    /// on, for every layer with sound.
    private func showsVolumeLines(of layer: TimelineLayer) -> Bool {
        volumeRevealed.contains(layer.id) && project.layerPlaysAudio(layer)
    }

    /// Whether the layer has a volume row to show: Sound and Music layers
    /// have a layer volume, video layers only their clips'.
    private func hasProperties(_ layer: TimelineLayer) -> Bool {
        layer.kind.isAudio && project.layerPlaysAudio(layer)
    }

    /// Only music is analyzed, so only Music layers are offered.
    private var beatLayerChoices: [(id: UUID, name: String)] {
        timeline.layers
            .filter { $0.kind == .music && project.layerHasBeats($0, tracks: beatTracks) }
            .map { (id: $0.id, name: project.displayName(of: $0, in: timeline)) }
    }

    /// Everything `EditingProject.beatMarkers` reads for the chosen layer.
    private struct BeatMarkerInputs: Equatable {
        var layer: TimelineLayer?
        var tracks: [UUID: BeatTrack] = [:]
        var offsets: [UUID: CMTime] = [:]
        var maps: [UUID: BeatMap] = [:]
    }

    private var beatMarkerInputs: BeatMarkerInputs {
        guard let id = chosenBeatLayerID, let layer = timeline.layer(id: id) else { return BeatMarkerInputs() }
        var inputs = BeatMarkerInputs(layer: layer)
        for clip in layer.clips {
            guard case .media(let assetID) = clip.source else { continue }
            inputs.tracks[assetID] = beatTracks[assetID]
            inputs.offsets[assetID] = project.mediaClip(id: assetID)?.alignmentOffset
            inputs.maps[assetID] = project.mediaClip(id: assetID)?.beatMap
        }
        return inputs
    }

    private var beatLayerSelection: Binding<UUID?> {
        Binding(
            get: { beatLayerChoices.contains { $0.id == chosenBeatLayerID } ? chosenBeatLayerID : nil },
            set: { chosenBeatLayerID = $0 }
        )
    }
    func viewport(width: CGFloat) -> TimelineViewport {
        TimelineViewport(
            durationSeconds: timeline.duration.seconds,
            frameRate: timeline.frameRate,
            width: width,
            requestedPixelsPerSecond: zoomedPixelsPerSecond,
            requestedScrollX: scrollX
        )
    }

    /// The viewport as last laid out, for actions that start outside the
    /// layout pass (buttons, keys, the slider).
    var currentViewport: TimelineViewport { viewport(width: trackAreaWidth) }

    var playheadTime: CMTime { playhead.time }

    /// Where the playhead is now: the player's time while it plays, which
    /// `playheadTime` doesn't follow, else the parked time.
    var livePlayheadTime: CMTime {
        playback.isPlaying ? playback.player.currentTime() : playheadTime
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
                TimelineZoomSliders(
                    horizontal: zoomFractionBinding,
                    vertical: Binding(
                        get: { areaLayout.shownLayerHeightFraction },
                        set: { areaLayout.setShownLayerHeightFraction($0) }
                    )
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
                    .help(areaLayout.showsSections ? "Hide the sections row" : "Show the sections row")
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
                        Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
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
                let viewport = viewport(width: geometry.size.width - labelColumnWidth)
                let scrollbarHeight = viewport.maxScrollX > 0 ? TimelineScrollbar.height : 0
                let shownAreas = areaLayout.shown
                let railHeight = rulerHeight + (areaLayout.showsSections ? SectionLane.height : 0) + separatorHeight
                // Whatever height the timeline is given goes to the areas,
                // split by their shares: a taller timeline shows more
                // layers, it doesn't make them taller.
                let areasAvailable = max(0, geometry.size.height - railHeight - scrollbarHeight
                    - CGFloat(shownAreas.count) * AreaTitleBar.height)
                let areaHeights = areaLayout.heights(splitting: areasAvailable)
                let trackHeight = max(railHeight, geometry.size.height - scrollbarHeight)
                // Built once per layout, not once per area: it walks every
                // clip and beat. The playhead is read as a drag snaps, so
                // moving it doesn't change what the rows compare.
                let _ = snapPlayhead.source = { [playhead] in playhead.time }
                let snapTargets = snapping
                    ? project.snapTargets(in: timelineID, playhead: nil, live: snapPlayhead, markers: drawnBeats(viewport)) : nil
                let _ = liveSnap.targets = snapTargets
                // Once for every area's rows, which compare it to skip
                // redrawing; without where this timeline's clips are, which
                // a row's actions read as they act (`liveSnap`, `resolveMove`).
                let structure = project.structure(withoutClipsIn: timelineID)

                VStack(alignment: .leading, spacing: 0) {
                    // The time rail: the ruler and the sections under it
                    // are one raised assembly, lit along its top, and the
                    // only part of the timeline that stands proud of the
                    // track area below.
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            TimelineColumnHeaderRow(height: rulerHeight)
                                .frame(width: labelColumnWidth, alignment: .leading)
                            TimelineRuler(duration: timeline.duration, frameRate: timeline.frameRate, viewport: viewport)
                                .frame(width: viewport.width, height: rulerHeight)
                                .overlay(alignment: .bottom) { RenderStatusStrip(viewport: viewport) }
                                .rubberBandStretch(zoomBand)
                                .rubberBandScroll(scrollBand, length: trackAreaWidth)
                                .clipped()
                                .contentShape(Rectangle())
                                .gesture(scrubGesture(in: viewport))
                                // To VoiceOver the ruler is the playhead:
                                // adjusting it steps a frame.
                                .accessibilityHidden(true)
                                .overlay {
                                    PlayheadAccessibilityElement(playhead: playhead, frameRate: timeline.frameRate) {
                                        stepPlayhead(byFrames: $0)
                                    }
                                }
                        }
                        if areaLayout.showsSections {
                            HStack(spacing: 0) {
                                Text("Sections")
                                    .font(Design.Typeface.micro)
                                    .foregroundStyle(Design.textTertiary)
                                    .padding(.leading, Design.Space.step)
                                    .frame(width: labelColumnWidth, height: SectionLane.height, alignment: .leading)
                                sectionLane(viewport: viewport, targets: snapTargets)
                                    .rubberBandStretch(zoomBand)
                                    .rubberBandScroll(scrollBand, length: trackAreaWidth)
                                    .clipped()
                            }
                        }
                    }
                    .background(Design.Surface.raised.color)
                    .overlay(alignment: .top) { Design.bevelLight.frame(height: 1) }
                    Groove()

                    // Video, sound and music, top to bottom, each with its
                    // own title bar (which resizes it against the area
                    // above) and its own vertical scrolling.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shownAreas) { kind in
                            AreaTitleBar(
                                kind: kind,
                                layerCount: areaLayers(kind).count,
                                labelColumnWidth: labelColumnWidth,
                                isResizable: kind != shownAreas.first,
                                onResize: { dy in
                                    let start = boundaryDragStart ?? areaHeights
                                    boundaryDragStart = start
                                    areaLayout.moveBoundary(above: kind, by: dy, from: start, available: areasAvailable)
                                },
                                onResizeEnded: { boundaryDragStart = nil }
                            )
                            area(kind, height: areaHeights[kind] ?? 0, viewport: viewport, structure: structure)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay(alignment: .topLeading) {
                        if let newLayerHover {
                            NewLayerZone(hover: newLayerHover)
                                .frame(width: labelColumnWidth)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        var column = frame
                        column.size.width = labelColumnWidth
                        geometryStore.namesColumn = column
                    }
                    .overlay {
                        if shownAreas.isEmpty {
                            Text("Every area is hidden. Show one in View Options.")
                                .font(Design.Typeface.label)
                                .foregroundStyle(Design.textTertiary)
                        }
                    }

                    // Right under the layers, and only while there is
                    // something to scroll to.
                    if scrollbarHeight > 0 {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: labelColumnWidth)
                            TimelineScrollbar(viewport: viewport) { scrollX = $0 }
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        if !beatMarkers.isEmpty {
                            BeatMarkerOverlay(markers: beatMarkers, viewport: viewport, rulerHeight: rulerHeight, height: trackHeight)
                        }
                        // The playhead and the snap line move far more
                        // often than anything else here, so they are Core
                        // Animation layers rather than SwiftUI shapes.
                        PlayheadReader(playhead: playhead) { parked in
                            LivePlayheadRail(
                                playback: playback,
                                parked: parked,
                                viewport: viewport,
                                onLeaveView: followsPlayhead && !viewport.isFitted ? { time in page(to: time) } : nil,
                                snapX: snapIndicator.map { viewport.x(atSeconds: $0.seconds) },
                                height: trackHeight
                            )
                        }
                    }
                    .frame(width: viewport.width, height: trackHeight, alignment: .topLeading)
                    .rubberBandStretch(zoomBand)
                    .rubberBandScroll(scrollBand, length: trackAreaWidth)
                    .clipped()
                    .offset(x: labelColumnWidth)
                    .allowsHitTesting(false)
                }
                .background(
                    TimelineInputMonitor(
                        onMagnify: { factor, axis, x, pointer in
                            switch axis {
                            case .horizontal:
                                guard x >= labelColumnWidth else { return }
                                zoom(viewport, by: factor, aboutX: x - labelColumnWidth, pinching: true)
                            case .vertical:
                                zoomLayerHeight(by: factor, at: pointer)
                            }
                        },
                        onScroll: { deltaX, deltaY, flags, x, phase in
                            guard x >= labelColumnWidth else { return false }
                            if flags.contains(.option) {
                                zoom(viewport, by: exp(deltaY * 0.01), aboutX: x - labelColumnWidth)
                                return true
                            }
                            // Also without movement, so a lift lets go of the edge.
                            scrollTracks(by: deltaX, phase: phase, width: viewport.width)
                            return false
                        },
                        onMagnifyEnded: {
                            zoomBand.endPinch()
                            layerHeightBand.endPinch()
                        }
                    )
                )
                .onChange(of: viewport.width, initial: true) { _, width in trackAreaWidth = width }
            }
        }
        .rubberBandSettling($zoomBand)
        .rubberBandSettling($scrollBand)
        .rubberBandSettling($layerHeightBand)
        .padding(.top, topPadding)
        .background(KeyPressMonitor(handler: handleKey))
        // The Timeline menu rests while a song is beat matched.
        .focusedSceneValue(\.timelineActions, beatMatch?.isActive == true ? nil : actions)
        .focusedSceneValue(\.timelineEditActions, beatMatch?.isActive == true ? nil : editActions)
        .environment(autoScroll)
        // Again whenever the timeline changes: the closures read its
        // length, through this view's copy of it.
        .onChange(of: timeline, initial: true) { old, new in
            configureAutoScroll()
            keepZoomThroughRetiming(from: old, to: new)
        }
        .onChange(of: selection) { _, newValue in
            if newValue != nil {
                selectedLayerID = nil
                selectedSectionID = nil
            }
        }
        // A song dragged in as the only thing on the timeline: show all of
        // it. Not when deleting the rest leaves a song alone.
        // A song just confirmed in Beat Match: show its beats.
        .onChange(of: beatMatch?.confirmation) { _, confirmation in
            guard let confirmation else { return }
            let layer = timeline.layers.first { layer in
                layer.kind == .music && layer.clips.contains { $0.source == .media(confirmation.assetID) }
            }
            if let layer { chosenBeatLayerID = layer.id }
        }
        .onChange(of: soleMusic) { old, new in
            if new.clipID != nil, new.clipID != old.clipID, new.clipCount >= old.clipCount { fitToWindow() }
        }
        .onChange(of: beatMarkerInputs, initial: true) { _, inputs in
            beatMarkers = inputs.layer.map { project.beatMarkers(in: $0, tracks: inputs.tracks) } ?? []
        }
        .onChange(of: beatMarkers, initial: true) { _, markers in
            beatClicks.beats = markers.map { BeatClickPlayer.Tick(time: $0.time, isDownbeat: $0.isDownbeat) }
        }
        .onChange(of: clickOnBeats, initial: true) { _, on in beatClicks.isEnabled = on }
        .onChange(of: beatClickFrequency, initial: true) { _, hertz in beatClicks.frequency = hertz }
        .onChange(of: beatClickVolume, initial: true) { _, volume in beatClicks.volume = Float(volume) }
        .onChange(of: timelineID) { _, _ in
            zoomedPixelsPerSecond = nil
            scrollX = 0
            expandedJoint = nil
        }
    }

    // MARK: - Areas

    /// One area: its layers' names beside their tracks, scrolling up and
    /// down on its own.
    private func area(
        _ kind: LayerKind, height: CGFloat, viewport: TimelineViewport, structure: EditingProject
    ) -> some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                layerHeaders(kind)
                    .frame(width: labelColumnWidth, alignment: .topLeading)
                    .frame(minHeight: height, alignment: .top)
                    .grooved(.trailing)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        geometryStore.headerColumns[kind] = frame
                    }
                    // Media from the library dropped on the names goes on
                    // a new layer of the kind under the pointer.
                    .onDrop(of: [.text], delegate: NewLayerDropDelegate(
                        column: { geometryStore.namesColumn },
                        viewFrame: { geometryStore.headerColumns[kind] ?? .zero },
                        isAudio: { project.mediaClip(id: $0)?.kind == .audio },
                        onHover: { hover in if hover != newLayerHover { newLayerHover = hover } },
                        onDrop: { payloads, kind in _ = onDropScenes(payloads, nil, playheadTime, kind) }
                    ))
                layerTracks(kind, areaHeight: height, viewport: viewport, structure: structure)
                    .offset(x: -viewport.scrollX)
                    .frame(width: viewport.width, alignment: .topLeading)
                    .rubberBandStretch(zoomBand)
                    .rubberBandScroll(scrollBand, length: trackAreaWidth)
                    .clipped()
            }
            .overlay(alignment: .topLeading) { layerDropIndicator(kind) }
            .edgeAutoScroll(areaScroller(kind))
        }
        .frame(height: height)
        // A vertical pinch past the layer heights stretches this area.
        .rubberBandStretch(layerHeightBandKind == kind ? layerHeightBand : RubberBandZoom(), axis: .vertical)
        .clipped()
        .sunken(.sunken)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            geometryStore.areas[kind] = frame
        }
    }

    private func layerHeaders(_ kind: LayerKind) -> some View {
        let layers = areaLayers(kind)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                let isDragged = layerDrag?.id == layer.id
                VStack(alignment: .leading, spacing: 0) {
                    LayerHeaderRow(
                        number: index + 1,
                        layer: layer,
                        displayName: project.displayName(of: layer, in: timeline),
                        height: clipRowHeight(of: layer),
                        canMoveUp: index > 0,
                        canMoveDown: index < layers.count - 1,
                        isExpanded: hasProperties(layer) ? showsVolume(of: layer) : nil,
                        onToggleExpanded: { toggleExpanded(layer) },
                        isAudioExpanded: project.layerHasLinkedAudio(layer) ? showsLinkedAudio(of: layer) : nil,
                        onToggleAudio: { toggleLinkedAudio(layer) },
                        onDetachAudio: { onDetachAudio(layer.id, nil) },
                        isChannelsExpanded: canShowChannels(of: layer) ? showsChannels(of: layer) : nil,
                        onToggleChannels: { toggleChannels(layer) },
                        onRename: { name in onRenameLayer(layer.id, name) },
                        onMove: { offset in onMoveLayer(layer.id, offset) },
                        onDragChanged: { dy in dragLayer(layer, by: dy) },
                        onDragEnded: { dy in endLayerDrag(layer.id, dy: dy + areaScroller(layer.kind).scrolled) },
                        isSelected: selectedLayerID == layer.id,
                        onSelect: {
                            selectedLayerID = layer.id
                            selectedSectionID = nil
                            onSelectLayer()
                        },
                        onDelete: { deleteLayer(layer.id) }
                    )
                    .equatable()
                    if shownJoint(in: layer) != nil {
                        HStack {
                            Label("Transition footage", systemImage: "square.on.square.dashed")
                                .font(Design.Typeface.label)
                                .foregroundStyle(Design.textSecondary)
                            Spacer()
                            Button("Done") { expandedJoint = nil }
                                .controlSize(.small)
                        }
                        .padding(.leading, 30)
                        .padding(.trailing, 8)
                        .frame(height: TransitionFootageLane.height)
                    }
                    if showsLinkedAudio(of: layer) {
                        Label("Linked audio", systemImage: "waveform")
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.textSecondary)
                            .padding(.leading, 30)
                            .frame(height: audioLaneHeight(of: layer), alignment: .leading)
                            .contextMenu {
                                Button("Detach Audio") { onDetachAudio(layer.id, nil) }
                            }
                    }
                    if showsVolume(of: layer) {
                        AudioPropertyRow(
                            value: layer.volume,
                            playhead: PlayheadTime(playhead) { timeline.snappedToFrame($0) },
                            onEdit: { change in onEditVolume(layer.id, change) },
                            onSeek: onScrub,
                            onShowGraph: graphs.map { graphs in
                                { graphs.show(ParameterKey(timelineID: timelineID, parameter: .layerVolume(layerID: layer.id))) }
                            },
                            held: { projectState?.held?.timeline(id: timelineID)?.layer(id: layer.id)?.volume }
                        )
                        .padding(.leading, 30)
                        .padding(.trailing, 8)
                        .frame(height: VolumeLane.height)
                    }
                    separator
                }
                .overlay(alignment: .bottom) {
                    // Adjustment layers keep one height.
                    if !layer.isAdjustment {
                        LayerResizeDivider(
                            onChanged: { dy, flags in resizeLayer(layer, by: dy, flags: flags) },
                            onEnded: { layerResize = nil },
                            onStep: { step in
                                areaLayout.setHeight(areaLayout.height(of: layer.id, kind: layer.kind) + step, of: layer.id, kind: layer.kind)
                            }
                        )
                        .offset(y: LayerResizeDivider.hitHeight / 2)
                    }
                }
                // Alternating tone, faint enough to read as banding rather
                // than as two kinds of layer. With the grooves it is what
                // keeps a tall stack of layers legible at a glance.
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.018))
                .background(Design.Surface.base.color)
                .background(isDragged ? Design.accent.opacity(0.18) : .clear)
                .shadow(color: .black.opacity(isDragged ? 0.45 : 0), radius: 6, y: 2)
                .offset(y: isDragged ? layerDrag?.dy ?? 0 : 0)
                .zIndex(isDragged ? 1 : 0)
            }
            Color.clear.frame(height: newLayerRowHeight)
        }
    }

    /// Resizes a layer from its names-column divider, `dy` from where the
    /// drag began: the layer alone, with Option every layer of its area,
    /// with Option-Shift every shown layer, all to the same height.
    private func resizeLayer(_ layer: TimelineLayer, by dy: CGFloat, flags: NSEvent.ModifierFlags) {
        if layerResize?.id != layer.id {
            layerResize = (layer.id, areaLayout.height(of: layer.id, kind: layer.kind))
        }
        guard let start = layerResize?.startHeight else { return }
        // A layer showing its channels draws its row twice as tall.
        let height = start + dy / (layer.kind != .video && showsChannels(of: layer) ? 2 : 1)
        if flags.contains(.option), flags.contains(.shift) {
            areaLayout.setHeightOfAllShown(height, layers: timeline.layers.map(\.id))
        } else if flags.contains(.option) {
            areaLayout.setHeightOfAll(height, kind: layer.kind, layers: areaLayers(layer.kind).map(\.id))
        } else {
            areaLayout.setHeight(height, of: layer.id, kind: layer.kind)
        }
    }

    /// A box under each adjustment clip, spanning its time and reaching
    /// down over the layers it adjusts (those in the same area), so what an
    /// adjustment affects can be read off the timeline. Brighter while the
    /// clip is selected; dashed around the clip alone when the layer it
    /// reaches down to is above it.
    private func reachBoxes(of layers: [TimelineLayer], pixelsPerSecond: CGFloat) -> some View {
        let tops = tops(of: layers)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                if layer.isAdjustment {
                    ForEach(layer.clips) { clip in
                        let reached = project.reachedLayers(of: clip, on: layer, in: timeline)
                        let bottom = reached.compactMap { target in layers.firstIndex { $0.id == target.id } }.max() ?? index
                        let isSelected = selection?.timelineClipID == clip.id
                        let tone = Design.ClipTone.adjustment.color
                        let shape = RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        let y0 = tops[index]
                        let y1 = tops[bottom] + blockHeight(of: layers[bottom]) - separatorHeight
                        shape
                            .fill(tone.opacity(reached.isEmpty ? 0 : isSelected ? 0.12 : 0.06))
                            .overlay {
                                shape.strokeBorder(
                                    tone.opacity(reached.isEmpty ? 0.4 : isSelected ? 0.95 : 0.55),
                                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: reached.isEmpty ? [4, 3] : [])
                                )
                            }
                            .frame(
                                width: max(2, CGFloat(CMTimeSubtract(clip.endOffset, clip.startOffset).seconds) * pixelsPerSecond),
                                height: max(4, y1 - y0)
                            )
                            .offset(x: clip.startOffset.seconds * pixelsPerSecond, y: y0)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A fixed-height groove between layers, so the two columns line up and
    /// layer positions can be worked out for dragging.
    private var separator: some View {
        Groove(subtle: true)
            .frame(height: separatorHeight)
    }

    /// Every layer's clips and keyframe lanes, laid out across the whole
    /// span in unscrolled coordinates; the caller shifts them into view.
    private func layersHeight(_ kind: LayerKind) -> CGFloat {
        areaLayers(kind).reduce(0) { $0 + blockHeight(of: $1) }
    }

    /// `structure` is `project.structure`, which the rows compare.
    private func layerTracks(
        _ kind: LayerKind, areaHeight: CGFloat, viewport: TimelineViewport, structure: EditingProject
    ) -> some View {
        let pixelsPerSecond = viewport.pixelsPerSecond
        let contentWidth = viewport.contentWidth
        let snapTolerance = snapTolerance(viewport)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(areaLayers(kind).enumerated()), id: \.element.id) { index, layer in
                VStack(spacing: 0) {
                    LayerClipRow(
                        layer: layer,
                        name: project.displayName(of: layer, in: timeline),
                        frameRate: timeline.frameRate,
                        project: project,
                        structure: structure,
                        timelineID: timelineID,
                        selection: selection,
                        pixelsPerSecond: pixelsPerSecond,
                        width: contentWidth,
                        height: clipRowHeight(of: layer),
                        showsChannels: layer.kind != .video && showsChannels(of: layer),
                        visibleX: viewport.visibleContentX,
                        onSelectClip: { clip in onSelectClip(layer.id, clip) },
                        resolveMove: { clip, pointer, start in resolveMove(clip, from: layer.id, pointer: pointer, to: start) },
                        onMoveClip: { clipID, target, newStart in onMoveClip(layer.id, clipID, target, newStart) },
                        onMoveClipToNewLayer: { clipID, kind, start in
                            newLayerHover = nil
                            onMoveClipToNewLayer(layer.id, clipID, kind, start)
                        },
                        onDraggingClip: { dragging in draggingClipLayerID = dragging ? layer.id : nil },
                        pushed: pushedClips.flatMap { $0.layerID == layer.id ? $0.clips : nil } ?? [:],
                        onMovePreview: { preview in showMovePreview(preview, from: layer.id) },
                        onDropScenes: { payloads, time in onDropScenes(payloads, layer.id, time, nil) },
                        onEditJoint: { clipID in
                            expandedJoint = clipID
                            if let clip = layer.clips.first(where: { $0.id == clipID }) {
                                onSelectTransition(layer.id, clip, .leading)
                            }
                        },
                        onTrimClipStart: { clipID, newStart in onTrimClipStart(layer.id, clipID, newStart) },
                        onTrimClipEnd: { clipID, newEnd in onTrimClipEnd(layer.id, clipID, newEnd) },
                        onSetTransition: { clipID, kind, edge in onSetTransition(layer.id, clipID, kind, edge) },
                        onRemoveTransition: { clipID, edge in onRemoveTransition(layer.id, clipID, edge) },
                        onSelectTransition: { clip, edge in onSelectTransition(layer.id, clip, edge) },
                        onSetTransitionCurve: { clipID, edge, curve in onSetTransitionCurve(layer.id, clipID, edge, curve) },
                        onDetachAudio: { clipID in onDetachAudio(layer.id, [clipID]) },
                        tool: tool,
                        snap: { timeline.snappedToFrame($0) },
                        onBlade: { clipID, time in onBladeClip(layer.id, clipID, time) },
                        onSlip: { clipID, delta in onSlipClip(layer.id, clipID, delta) },
                        liveSnap: liveSnap,
                        snapTolerance: snapTolerance,
                        onSnapIndicator: { snapIndicator = $0 },
                        onTrimPreview: onTrimPreview,
                        onApplyJointEdit: { clipID, edit in onApplyJointEdit(layer.id, clipID, edit) },
                        onSetTransitionDuration: { clipID, edge, duration in onSetTransitionDuration(layer.id, clipID, edge, duration) },
                        onAddEffect: { clipID, kind in
                            onEditProject { $0.addEffect(kind, toClip: clipID, in: timelineID) }
                        },
                        onApplyPreset: { clipID, presetID in
                            guard let preset = try? PresetStore.read(PresetStore.fileURL(presetID)) else { return }
                            onEditProject { $0.paste(preset.bundle, ontoClip: clipID, in: timelineID) }
                        },
                        onCopyEffects: { clipID in
                            EditorClipboard.shared.copy(effects: project.bundle(ofEffects: nil, fromClip: clipID, in: timelineID))
                        },
                        onPasteEffects: { clipID in
                            guard let bundle = EditorClipboard.shared.effects else { return }
                            onEditProject { $0.paste(bundle, ontoClip: clipID, in: timelineID, replacingStack: true) }
                        },
                        onClipboard: { clipID, command in clipboard(command, layerID: layer.id, clipID: clipID) },
                        onCopyClip: { clipID, start, target, kind in copyClip(clipID, from: layer.id, to: start, onto: target, newLayer: kind) },
                        onDropFiles: { urls, time in onDropFiles(urls, layer.id, time, layer.kind) },
                        onSetPassThrough: { clipID, value in
                            onEditProject { $0.editClip(clipID, in: timelineID) { $0.passThrough = value } }
                        },
                        showsVolumeLines: showsVolumeLines(of: layer),
                        onEditTime: { clipID, change in
                            onEditProject { $0.editTime(ofClip: clipID, in: timelineID, layer: layer.id, change) }
                        },
                        onEditClip: { clipID, change in
                            onEditProject { $0.editClip(clipID, in: timelineID, change) }
                        },
                        onSetReach: { clipID, bottom in
                            onEditProject { $0.setReach(ofClip: clipID, in: timelineID, toLayer: bottom) }
                        }
                    )
                    // Rows that would draw the same aren't redrawn, so
                    // dragging one clip's value redraws only its layer.
                    .equatable()
                    // Recorded for drags that cross areas; see
                    // `TimelineGeometryStore`.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        geometryStore.layerRows[layer.id] = frame
                    }
                    if let joint = shownJoint(in: layer) {
                        TransitionFootageLane(
                            joint: joint,
                            frameRate: timeline.frameRate,
                            outgoingName: project.resolvedInfo(for: joint.outgoing.source)?.name ?? "Clip",
                            incomingName: project.resolvedInfo(for: joint.incoming.source)?.name ?? "Clip",
                            pixelsPerSecond: pixelsPerSecond,
                            width: contentWidth,
                            visibleX: viewport.visibleContentX,
                            preview: { edit in
                                var copy = project
                                copy.applyJointEdit(edit, at: joint.incoming.id, in: timelineID, layer: layer.id)
                                return copy.joint(at: joint.incoming.id, in: timelineID, layer: layer.id)
                            },
                            onCommit: { edit in onApplyJointEdit(layer.id, joint.incoming.id, edit) },
                            tool: tool,
                            onTrimPreview: onTrimPreview
                        )
                    }
                    if showsLinkedAudio(of: layer) {
                        LinkedAudioLane(
                            layer: layer,
                            project: project,
                            pixelsPerSecond: pixelsPerSecond,
                            width: contentWidth,
                            height: audioLaneHeight(of: layer),
                            showsChannels: showsChannels(of: layer),
                            visibleX: viewport.visibleContentX,
                            onSelectClip: { clip in onSelectClip(layer.id, clip) },
                            onDetachAudio: { clipID in onDetachAudio(layer.id, [clipID]) }
                        )
                    }
                    if showsVolume(of: layer) {
                        PlayheadReader(playhead: playhead) { parked in
                            VolumeLane(
                                volume: layer.volume,
                                currentTime: timeline.snappedToFrame(parked),
                                pixelsPerSecond: pixelsPerSecond,
                                width: contentWidth,
                                visibleX: viewport.visibleContentX,
                                snap: { timeline.snappedToFrame($0) },
                                onSeek: onScrub,
                                onMove: { from, to, copy in onEditVolume(layer.id) { $0.moveKeyframe(at: from, to: to, copying: copy) } },
                                onDelete: { time in onEditVolume(layer.id) { $0.removeKeyframe(at: time) } },
                                onEase: { time, preset in onEditVolume(layer.id) { $0.applyEase(preset, at: time) } }
                            )
                        }
                    }
                    separator
                }
                // The same banding as the header column, so a layer reads
                // as one band all the way across the window.
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.018))
                .zIndex(draggingClipLayerID == layer.id ? 1 : 0)
            }
            // Fills the rest of the area, so media dropped anywhere below the
            // layers (or in an empty area) gets a new layer of its kind.
            NewLayerDropRow(height: max(newLayerRowHeight, areaHeight - layersHeight(kind)), kind: kind) { payloads, x in
                onDropScenes(payloads, nil, CMTime(seconds: max(0, Double(x / pixelsPerSecond)), preferredTimescale: 600), kind)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .overlay(alignment: .topLeading) { reachBoxes(of: areaLayers(kind), pixelsPerSecond: pixelsPerSecond) }
        // A shape from the Effects Library dropped on the video area, but
        // not on a clip (which takes it into its stack), makes a shape layer
        // where it lands. Library drags travel as URLs, media as text, so
        // this doesn't catch media.
        .dropDestination(for: ClipDropPayload.self) { payloads, location in
            let time = CMTime(seconds: max(0, Double(location.x / pixelsPerSecond)), preferredTimescale: 600)
            let files = payloads.compactMap(\.file)
            if !files.isEmpty {
                onDropFiles(files, nil, time, kind)
                return true
            }
            guard kind == .video, let shape = payloads.first?.effect?.kind, shape.drawsShape else { return false }
            addShapeLayer(shape, at: CMTime(seconds: max(0, Double(location.x / pixelsPerSecond)), preferredTimescale: 600))
            return true
        }
    }

    // MARK: - Zoom and scrub

    private func sectionLane(viewport: TimelineViewport, targets: SnapTargets?) -> some View {
        let tolerance = snapTolerance(viewport)
        return SectionLane(
            sections: timeline.sections,
            viewport: viewport,
            selectedID: selectedSectionID,
            snap: { time, owner in targets?.nearest(to: time, within: tolerance, excluding: owner) },
            resolveMove: { id, start in project.resolvedSectionMove(id, in: timelineID, to: start) },
            resolveEdge: { id, edge, time in project.resolvedSectionEdge(id, edge: edge, in: timelineID, to: time) },
            onSelect: { id in
                selectedSectionID = id
                selectedLayerID = nil
                onSelectLayer()
            },
            onCreate: { start, end in
                var created: UUID?
                onEditProject { created = $0.addSection(in: timelineID, from: start, to: end) }
                return created
            },
            onMove: { id, start in onEditProject { $0.moveSection(id, in: timelineID, to: start) } },
            resolveCopy: { id, start in project.resolvedSectionCopy(id, in: timelineID, to: start) },
            onCopy: { id, start in
                var copied: UUID?
                onEditProject { copied = $0.copySection(id, in: timelineID, to: start) }
                if let copied {
                    selectedSectionID = copied
                    selectedLayerID = nil
                }
            },
            onSetEdge: { id, edge, time in onEditProject { $0.setSectionEdge(id, edge: edge, in: timelineID, to: time) } },
            onRename: { id, name in onEditProject { $0.renameSection(id, in: timelineID, to: name) } },
            onDelete: { id in
                onEditProject { $0.deleteSection(id, in: timelineID) }
                if selectedSectionID == id { selectedSectionID = nil }
            },
            onSnapIndicator: { snapIndicator = $0 }
        )
    }

    func drawnBeats(_ viewport: TimelineViewport) -> [CMTime] {
        BeatMarkerOverlay.drawnMarkers(beatMarkers, pixelsPerSecond: viewport.pixelsPerSecond).map(\.time)
    }

    func snapTolerance(_ viewport: TimelineViewport) -> CMTime {
        CMTime(seconds: Double(snapDistance / max(viewport.pixelsPerSecond, 0.0001)), preferredTimescale: 600_000)
    }

    private func toggleLinkedAudio(_ layer: TimelineLayer) {
        if audioRevealed.contains(layer.id) { audioRevealed.remove(layer.id) } else { audioRevealed.insert(layer.id) }
    }

    private func toggleChannels(_ layer: TimelineLayer) {
        if channelsRevealed.contains(layer.id) { channelsRevealed.remove(layer.id) } else { channelsRevealed.insert(layer.id) }
    }

    /// The disclosure arrow shows the layer's volume row, or hides it.
    private func toggleExpanded(_ layer: TimelineLayer) {
        if showsVolume(of: layer) { volumeRevealed.remove(layer.id) } else { volumeRevealed.insert(layer.id) }
    }

    /// Puts an adjustment layer at the top of the stack and selects its clip.
    private func addAdjustmentLayer() {
        var created: (layerID: UUID, clipID: UUID)?
        onEditProject { created = $0.addAdjustmentLayer(to: timelineID, from: .zero) }
        // Selection goes by ID; the view hasn't seen the new clip yet.
        if let created {
            onSelectClip(created.layerID, TimelineClip(id: created.clipID, source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: .zero))
        }
    }

    /// Puts a shape layer at the top of the stack, starting at `start`
    /// (the playhead unless given), and selects its clip.
    private func addShapeLayer(_ kind: EffectKind, at start: CMTime? = nil) {
        let start = start ?? playheadTime
        var created: (layerID: UUID, clipID: UUID)?
        onEditProject { created = $0.addShapeLayer(kind, to: timelineID, from: start) }
        // Selection goes by ID; the view hasn't seen the new clip yet.
        if let created {
            onSelectClip(created.layerID, TimelineClip(id: created.clipID, source: .graphic, startOffset: start, trimStart: .zero, trimEnd: .zero))
        }
    }

    func deleteLayer(_ id: UUID) {
        if selectedLayerID == id { selectedLayerID = nil }
        onDeleteLayer(id)
    }
}
