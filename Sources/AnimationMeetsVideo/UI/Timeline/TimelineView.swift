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
    /// stops.
    @Binding var playheadTime: CMTime
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
    let onMoveClipToNewLayer: (UUID, UUID, LayerKind) -> Void
    /// Scenes dropped on a layer at a time, or with no layer, onto a new
    /// layer of the given kind (the asset's default kind when nil).
    let onDropScenes: ([SceneDragPayload], UUID?, CMTime, LayerKind?) -> Bool
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
    @Binding var showsBrowser: Bool
    @Binding var showsSidePanel: Bool
    @Binding var showsEffects: Bool
    @Binding var showsMeter: Bool
    /// What is selected in the effects panel, which gets the Delete key
    /// while it has something selected.
    let effectsState: EffectsPanelState

    /// The chosen zoom, or nil while the whole timeline is fitted to the
    /// window. Kept in points per second, not relative to the fit, so
    /// moving a clip past the end doesn't rescale everything.
    @State private var zoomedPixelsPerSecond: CGFloat?
    @State private var scrollX: CGFloat = 0
    @State private var trackAreaWidth: CGFloat = 800
    /// Layers showing their volume under their clips.
    @State private var volumeRevealed: Set<UUID> = []
    /// Layers showing their video clips' linked audio.
    @State private var audioRevealed: Set<UUID> = []
    /// Layers whose sound shows each channel apart: the clips of sound
    /// layers, or the linked audio lane of video layers.
    @State private var channelsRevealed: Set<UUID> = []
    /// Which areas show, how they share the height, and each one's layer
    /// height (its vertical zoom).
    @AppStorage("timelineAreaLayout") private var areaLayout = TimelineAreaLayout()
    /// Area heights when a drag of the boundary between two areas began.
    @State private var boundaryDragStart: [LayerKind: CGFloat]?
    @State private var geometryStore = TimelineGeometryStore()
    @State private var autoScroll = TimelineAutoScroll()
    /// What the layer names column offers while a clip or media is dragged
    /// over it; nil otherwise.
    @State private var newLayerHover: NewLayerHover?
    @State private var showingViewOptions = false
    /// The layer whose beats are shown. Only layers that still have beats are
    /// offered, so a deleted layer simply stops matching and markers vanish.
    @State private var chosenBeatLayerID: UUID?
    /// The chosen layer's markers, worked out again only when what they
    /// depend on changes. The view's body runs on every playback tick and
    /// scroll, and a long song has thousands of beats to collect and sort.
    @State private var beatMarkers: [CMTime] = []
    /// The layer whose header is being dragged, and how far.
    @State private var layerDrag: (id: UUID, dy: CGFloat)?
    /// The layer of a clip being dragged, drawn above the others so the
    /// clip stays visible over the layer it is moving to.
    @State private var draggingClipLayerID: UUID?
    /// Clips moving aside for the clip being dragged, by layer.
    @State private var pushedClips: (layerID: UUID, clips: [UUID: PushedClip])?
    /// The incoming clip of the joining transition whose footage is open.
    @State private var expandedJoint: UUID?
    @State private var headerBarHeight: CGFloat = 32
    /// The layer selected by its header, for Delete. Selecting a clip clears it.
    @State private var selectedLayerID: UUID?
    @State private var tool: TimelineTool = .arrow
    /// The section selected in the lane under the ruler, for Delete.
    @State private var selectedSectionID: UUID?
    @AppStorage("snapping") private var snapping = true
    /// Whether the view pages along with the playhead while playing.
    @AppStorage("followsPlayhead") private var followsPlayhead = true
    /// The surface's graph editor panels.
    @Environment(KeyframeGraphHUDs.self) private var graphs: KeyframeGraphHUDs?
    @Environment(RenderScheduler.self) private var renderer: RenderScheduler?
    /// Where a drag in progress snapped, drawn as a line across the layers.
    @State private var snapIndicator: CMTime?

    /// How close, on screen, an edge must come to a target to snap to it.
    private let snapDistance: CGFloat = 8
    @AppStorage("clickOnBeats") private var clickOnBeats = false
    @AppStorage("beatClickFrequency") private var beatClickFrequency = 1000.0

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
    private func blockHeight(of layer: TimelineLayer) -> CGFloat {
        clipRowHeight(of: layer)
            + (shownJoint(in: layer) != nil ? TransitionFootageLane.height : 0)
            + (showsLinkedAudio(of: layer) ? audioLaneHeight(of: layer) : 0)
            + (showsVolume(of: layer) ? VolumeLane.height : 0)
            + separatorHeight
    }

    /// The layers an area shows, top to bottom.
    private func areaLayers(_ kind: LayerKind) -> [TimelineLayer] {
        timeline.layers.filter { $0.kind == kind }
    }

    /// Where each of `layers` starts, from the top of its area.
    private func tops(of layers: [TimelineLayer]) -> [CGFloat] {
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
        let lane = max(22, (areaLayout.layerHeight(.video) * 0.6).rounded())
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

    /// The clips' row: the area's layer height, doubled (with a floor) on
    /// sound layers showing their channels, so each gets a band.
    private func clipRowHeight(of layer: TimelineLayer) -> CGFloat {
        let height = areaLayout.layerHeight(layer.kind)
        guard layer.kind != .video, showsChannels(of: layer) else { return height }
        return max(height, Self.channelBandHeight) * 2
    }
    private let zoomStep: CGFloat = 1.5

    /// Wider while a volume row is showing, to fit its values.
    private var labelColumnWidth: CGFloat {
        timeline.layers.contains { showsVolume(of: $0) } ? 300 : 150
    }

    private func showsVolume(of layer: TimelineLayer) -> Bool {
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

    private var beatLayerChoices: [(id: UUID, name: String)] {
        timeline.layers
            .filter { project.layerHasBeats($0, tracks: beatTracks) }
            .map { (id: $0.id, name: project.displayName(of: $0, in: timeline)) }
    }

    /// Everything `EditingProject.beatMarkers` reads for the chosen layer.
    private struct BeatMarkerInputs: Equatable {
        var layer: TimelineLayer?
        var tracks: [UUID: BeatTrack] = [:]
        var offsets: [UUID: CMTime] = [:]
    }

    private var beatMarkerInputs: BeatMarkerInputs {
        guard let id = chosenBeatLayerID, let layer = timeline.layer(id: id) else { return BeatMarkerInputs() }
        var inputs = BeatMarkerInputs(layer: layer)
        for clip in layer.clips {
            guard case .media(let assetID) = clip.source else { continue }
            inputs.tracks[assetID] = beatTracks[assetID]
            inputs.offsets[assetID] = project.mediaClip(id: assetID)?.alignmentOffset
        }
        return inputs
    }

    private var beatLayerSelection: Binding<UUID?> {
        Binding(
            get: { beatLayerChoices.contains { $0.id == chosenBeatLayerID } ? chosenBeatLayerID : nil },
            set: { chosenBeatLayerID = $0 }
        )
    }
    private func viewport(width: CGFloat) -> TimelineViewport {
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
    private var currentViewport: TimelineViewport { viewport(width: trackAreaWidth) }

    /// Where the playhead is now: the player's time while it plays, which
    /// `playheadTime` doesn't follow, else the parked time.
    private var livePlayheadTime: CMTime {
        playback.isPlaying ? playback.player.currentTime() : playheadTime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.step) {
                Text("Timeline")
                    .font(Design.Typeface.panelTitle)
                    .foregroundStyle(Design.textPrimary)
                Picker("Tool", selection: $tool) {
                    ForEach(TimelineTool.allCases) { tool in
                        Image(systemName: tool.systemImage)
                            .help(tool.help)
                            .accessibilityLabel(tool.name)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(tool.help)
                Spacer()
                PlayheadTimecode(playback: playback, parked: playheadTime, frameRate: timeline.frameRate)
                TimelineZoomSliders(
                    horizontal: zoomFractionBinding,
                    vertical: Binding(
                        get: { areaLayout.shownLayerHeightFraction },
                        set: { areaLayout.setShownLayerHeightFraction($0) }
                    )
                )
                ControlGroup {
                    Button { zoomAroundPlayhead(by: 1 / zoomStep) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out (-)")
                        .accessibilityLabel("Zoom out")
                    Button { zoomAroundPlayhead(by: zoomStep) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in (=)")
                        .accessibilityLabel("Zoom in")
                }
                .fixedSize()
                Button {
                    showingViewOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("View options")
                .accessibilityLabel("View options")
                .popover(isPresented: $showingViewOptions) {
                    ViewOptionsPopover(
                        zoomFraction: zoomFractionBinding, onFit: fitToWindow, areaLayout: $areaLayout,
                        followsPlayhead: $followsPlayhead,
                        beatLayers: beatLayerChoices, beatLayerID: beatLayerSelection,
                        clickOnBeats: $clickOnBeats, clickFrequency: $beatClickFrequency,
                        onPreviewClick: beatClicks.preview
                    )
                }
                Toggle(isOn: $snapping) {
                    Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                }
                .toggleStyle(.button)
                .help(snapping ? "Snapping on: edges snap to clips, the playhead and beat markers (N)" : "Snapping off (N)")
                .accessibilityLabel("Snapping")
                Toggle(isOn: $areaLayout.showsSections) {
                    Image(systemName: "rectangle.split.3x1")
                }
                .toggleStyle(.button)
                .help(areaLayout.showsSections ? "Hide the sections row" : "Show the sections row")
                .accessibilityLabel("Sections row")
                Toggle(isOn: $showsBrowser) {
                    Image(systemName: "square.grid.2x2")
                }
                .toggleStyle(.button)
                .help(showsBrowser ? "Hide the effects and transitions browser" : "Show the effects and transitions browser")
                .accessibilityLabel("Effects and transitions browser")
                Button {
                    addAdjustmentLayer()
                } label: {
                    Image(systemName: "slider.horizontal.below.rectangle")
                }
                .help("New adjustment layer: effects applied to the layers below it")
                .accessibilityLabel("New adjustment layer")
                Toggle(isOn: $showsSidePanel) {
                    Image(systemName: "sidebar.right")
                }
                .toggleStyle(.button)
                .help(showsSidePanel ? "Hide the inspector and effects" : "Show the inspector and effects (⇧E for the selected clip's effects)")
                .accessibilityLabel("Inspector and effects")
                Toggle(isOn: $showsMeter) {
                    Image(systemName: "chart.bar.fill")
                }
                .toggleStyle(.button)
                .help(showsMeter ? "Hide the audio meter" : "Show the audio meter: every track together, left and right")
                .accessibilityLabel("Audio meter")
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
                let frameTime = timeline.snappedToFrame(playheadTime)
                // Built once per layout, not once per area: it walks every
                // clip and beat.
                let snapTargets = snapping ? project.snapTargets(in: timelineID, playhead: playheadTime, markers: drawnBeats(viewport)) : nil

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
                                .contentShape(Rectangle())
                                .gesture(scrubGesture(in: viewport))
                                // To VoiceOver the ruler is the playhead:
                                // adjusting it steps a frame.
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Playhead")
                                .accessibilityValue(playheadTime.timecode(frameRate: timeline.frameRate))
                                .accessibilityAdjustableAction { direction in
                                    switch direction {
                                    case .increment: stepPlayhead(byFrames: 1)
                                    case .decrement: stepPlayhead(byFrames: -1)
                                    @unknown default: break
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
                            area(kind, height: areaHeights[kind] ?? 0, viewport: viewport, frameTime: frameTime, snapTargets: snapTargets)
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
                        LivePlayheadRail(
                            playback: playback,
                            parked: playheadTime,
                            viewport: viewport,
                            onLeaveView: followsPlayhead && !viewport.isFitted ? { time in page(to: time) } : nil,
                            snapX: snapIndicator.map { viewport.x(atSeconds: $0.seconds) },
                            height: trackHeight
                        )
                    }
                    .frame(width: viewport.width, height: trackHeight, alignment: .topLeading)
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
                                zoom(viewport, by: factor, aboutX: x - labelColumnWidth)
                            case .vertical:
                                zoomLayerHeight(by: factor, at: pointer)
                            }
                        },
                        onScroll: { deltaX, deltaY, flags, x in
                            guard x >= labelColumnWidth else { return false }
                            if flags.contains(.option) {
                                zoom(viewport, by: exp(deltaY * 0.01), aboutX: x - labelColumnWidth)
                                return true
                            }
                            if deltaX != 0 { scrollX = self.viewport(width: viewport.width).scrollX + deltaX }
                            return false
                        }
                    )
                )
                .onChange(of: viewport.width, initial: true) { _, width in trackAreaWidth = width }
            }
        }
        .padding(.top, topPadding)
        .background(KeyPressMonitor(handler: handleKey))
        .focusedSceneValue(\.timelineActions, actions)
        .environment(autoScroll)
        // Again whenever the timeline changes: the closures read its
        // length, through this view's copy of it.
        .onChange(of: timeline, initial: true) { _, _ in configureAutoScroll() }
        .onChange(of: selection) { _, newValue in
            if newValue != nil {
                selectedLayerID = nil
                selectedSectionID = nil
            }
        }
        .onChange(of: beatMarkerInputs, initial: true) { _, inputs in
            beatMarkers = inputs.layer.map { project.beatMarkers(in: $0, tracks: inputs.tracks) } ?? []
        }
        .onChange(of: beatMarkers, initial: true) { _, markers in beatClicks.beats = markers }
        .onChange(of: clickOnBeats, initial: true) { _, on in beatClicks.isEnabled = on }
        .onChange(of: beatClickFrequency, initial: true) { _, hertz in beatClicks.frequency = hertz }
        .onChange(of: timelineID) { _, _ in
            zoomedPixelsPerSecond = nil
            scrollX = 0
            expandedJoint = nil
        }
    }

    // MARK: - Areas

    /// One area: its layers' names beside their tracks, scrolling up and
    /// down on its own.
    private func area(_ kind: LayerKind, height: CGFloat, viewport: TimelineViewport, frameTime: CMTime, snapTargets: SnapTargets?) -> some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                layerHeaders(kind, frameTime: frameTime)
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
                layerTracks(kind, viewport: viewport, frameTime: frameTime, snapTargets: snapTargets)
                    .offset(x: -viewport.scrollX)
                    .frame(width: viewport.width, alignment: .topLeading)
                    .clipped()
            }
            .overlay(alignment: .topLeading) { layerDropIndicator(kind) }
        }
        .frame(height: height)
        .sunken(.sunken)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            geometryStore.areas[kind] = frame
        }
    }

    // MARK: - Layer and clip dragging

    /// Where a layer dragged by `dy` would go among the layers of its
    /// area: the number of others whose middle is above its middle.
    private func dropPosition(forLayer id: UUID, dy: CGFloat) -> Int? {
        guard let kind = timeline.layer(id: id)?.kind else { return nil }
        let layers = areaLayers(kind)
        let tops = tops(of: layers)
        guard let from = layers.firstIndex(where: { $0.id == id }) else { return nil }
        let middle = tops[from] + blockHeight(of: layers[from]) / 2 + dy
        return layers.indices.filter { index in
            index != from && tops[index] + blockHeight(of: layers[index]) / 2 < middle
        }.count
    }

    /// A line where a layer dragged in this area will land.
    @ViewBuilder
    private func layerDropIndicator(_ kind: LayerKind) -> some View {
        if let drag = layerDrag, timeline.layer(id: drag.id)?.kind == kind,
           let position = dropPosition(forLayer: drag.id, dy: drag.dy) {
            let layers = areaLayers(kind)
            let tops = tops(of: layers)
            let others = layers.indices.filter { layers[$0].id != drag.id }
            let y = position < others.count
                ? tops[others[position]]
                : tops.last.map { $0 + blockHeight(of: layers[layers.count - 1]) } ?? 0
            Rectangle()
                .fill(Design.accent)
                .frame(height: 2)
                .shadow(color: Design.accent.opacity(0.7), radius: 4)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }

    private func endLayerDrag(_ id: UUID, dy: CGFloat) {
        if let kind = timeline.layer(id: id)?.kind,
           let position = dropPosition(forLayer: id, dy: dy),
           position != areaLayers(kind).firstIndex(where: { $0.id == id }) {
            onMoveLayerTo(id, position)
        }
        layerDrag = nil
    }

    /// Where a clip dragged with the pointer at `pointer` (window
    /// coordinates) and asked to start at `start` lands: on the layer
    /// under the pointer when that layer can take it, otherwise on its own
    /// layer. Layers are found by where they are on screen, since each
    /// area scrolls on its own.
    private func resolveMove(_ clip: TimelineClip, from layerID: UUID, pointer: CGPoint, to start: CMTime) -> ClipMovePreview? {
        let rows = geometryStore.layerRows
        guard let fromRow = rows[layerID], let fromLayer = timeline.layer(id: layerID) else { return nil }
        // Over the layer names: onto a new layer, keeping its time.
        let column = geometryStore.namesColumn
        if column.contains(pointer) {
            let hover = NewLayerHover(audio: project.isAudioOnly(clip), pointerY: pointer.y, in: column)
            return ClipMovePreview(start: clip.startOffset, layerID: nil, offsetY: 0, newLayer: hover.hovered)
        }
        let target = timeline.layers.first { layer in
            guard layer.id != layerID, let row = rows[layer.id],
                  // A row scrolled out of its area's view isn't under the pointer.
                  geometryStore.areas[layer.kind]?.contains(pointer) == true
            else {
                return false
            }
            return pointer.y >= row.minY && pointer.y < row.maxY
        }
        if let target, let landed = project.resolvedMove(ofMoving: clip.id, in: timelineID, layer: layerID, onto: target.id, to: start),
           let targetRow = rows[target.id] {
            return ClipMovePreview(
                start: landed.start, layerID: target.id, offsetY: targetRow.minY - fromRow.minY,
                pushed: pushed(on: target, by: landed, excluding: clip.id)
            )
        }
        return project.resolvedMove(ofMoving: clip.id, in: timelineID, layer: layerID, to: start).map {
            ClipMovePreview(start: $0.start, layerID: nil, offsetY: 0, pushed: pushed(on: fromLayer, by: $0, excluding: clip.id))
        }
    }

    /// Shows what a clip drag from `layerID` will do, or stops with nil.
    private func showMovePreview(_ preview: ClipMovePreview?, from layerID: UUID) {
        let hover = preview?.newLayer.map(NewLayerHover.init(hovering:))
        if hover != newLayerHover { newLayerHover = hover }
        let next = preview.flatMap { preview in
            preview.pushed.isEmpty ? nil : (layerID: preview.layerID ?? layerID, clips: preview.pushed)
        }
        if next?.layerID != pushedClips?.layerID || next?.clips != pushedClips?.clips {
            pushedClips = next
        }
    }

    /// The clips on `layer` that `move` pushes right, and where to.
    private func pushed(on layer: TimelineLayer, by move: ClipMove, excluding movingID: UUID) -> [UUID: PushedClip] {
        guard move.push > .zero else { return [:] }
        var pushed: [UUID: PushedClip] = [:]
        for clip in layer.clips where clip.id != movingID && clip.startOffset >= move.pushFrom {
            pushed[clip.id] = PushedClip(from: clip.startOffset, to: CMTimeAdd(clip.startOffset, move.push))
        }
        return pushed
    }

    private func layerHeaders(_ kind: LayerKind, frameTime: CMTime) -> some View {
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
                        onDragChanged: { dy in layerDrag = (layer.id, dy) },
                        onDragEnded: { dy in endLayerDrag(layer.id, dy: dy) },
                        isSelected: selectedLayerID == layer.id,
                        onSelect: {
                            selectedLayerID = layer.id
                            selectedSectionID = nil
                            onSelectLayer()
                        },
                        onDelete: { deleteLayer(layer.id) },
                        reach: reachMenu(for: layer)
                    )
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
                        VolumePropertyRow(
                            volume: layer.volume,
                            time: frameTime,
                            onEdit: { change in onEditVolume(layer.id, change) },
                            onSeek: onScrub,
                            onShowGraph: graphs.map { graphs in
                                { graphs.show(ParameterKey(timelineID: timelineID, parameter: .layerVolume(layerID: layer.id))) }
                            }
                        )
                        .padding(.leading, 30)
                        .padding(.trailing, 8)
                        .frame(height: VolumeLane.height)
                    }
                    separator
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
        .overlay(alignment: .topLeading) { reachBrackets(of: layers) }
    }

    /// The reach choices of an adjustment layer: every layer below it, or
    /// down to any one of them.
    private func reachMenu(for layer: TimelineLayer) -> ReachMenu? {
        guard layer.isAdjustment, let index = timeline.layers.firstIndex(where: { $0.id == layer.id }) else { return nil }
        return ReachMenu(
            current: layer.reach,
            options: timeline.layers[(index + 1)...].map { ($0.id, project.displayName(of: $0, in: timeline)) },
            summary: project.reachDescription(of: layer, in: timeline),
            onChoose: { bottom in onEditProject { $0.setReach(of: layer.id, in: timelineID, toLayer: bottom) } }
        )
    }

    /// A bracket at the left edge of each adjustment layer in the area,
    /// spanning the layers it reaches (in the same area), so what an
    /// adjustment affects can be read off the stack.
    private func reachBrackets(of layers: [TimelineLayer]) -> some View {
        let tops = tops(of: layers)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                if layer.isAdjustment {
                    let reached = project.reachedLayers(of: layer, in: timeline)
                    let last = reached.last.flatMap { target in layers.firstIndex { $0.id == target.id } }
                    let bottom = (last ?? index)
                    let y0 = tops[index]
                    let y1 = tops[bottom] + blockHeight(of: layers[bottom]) - separatorHeight
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Design.ClipTone.adjustment.color.opacity(reached.isEmpty ? 0.35 : 0.9))
                        .frame(width: 3, height: max(4, y1 - y0))
                        .offset(x: 1, y: y0)
                        .help(reached.isEmpty && layer.reach != nil
                            ? "Reaches nothing: the layer it reached down to is above it"
                            : "Reaches: \(project.reachDescription(of: layer, in: timeline))")
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// A fixed-height groove between layers, so the two columns line up and
    /// layer positions can be worked out for dragging.
    private var separator: some View {
        Groove(subtle: true)
            .frame(height: separatorHeight)
    }

    /// Every layer's clips and keyframe lanes, laid out across the whole
    /// span in unscrolled coordinates; the caller shifts them into view.
    private func layerTracks(_ kind: LayerKind, viewport: TimelineViewport, frameTime: CMTime, snapTargets: SnapTargets?) -> some View {
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
                        onMoveClipToNewLayer: { clipID, kind in
                            newLayerHover = nil
                            onMoveClipToNewLayer(layer.id, clipID, kind)
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
                        snapTargets: snapTargets,
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
                            EffectClipboard.shared.bundle = project.bundle(ofEffects: nil, fromClip: clipID, in: timelineID)
                        },
                        onPasteEffects: { clipID in
                            guard let bundle = EffectClipboard.shared.bundle else { return }
                            onEditProject { $0.paste(bundle, ontoClip: clipID, in: timelineID, replacingStack: true) }
                        },
                        onSetPassThrough: { clipID, value in
                            onEditProject { $0.editClip(clipID, in: timelineID) { $0.passThrough = value } }
                        },
                        showsVolumeLines: showsVolumeLines(of: layer),
                        onEditTime: { clipID, change in
                            onEditProject { $0.editTime(ofClip: clipID, in: timelineID, layer: layer.id, change) }
                        },
                        onEditClip: { clipID, change in
                            onEditProject { $0.editClip(clipID, in: timelineID, change) }
                        }
                    )
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
                        VolumeLane(
                            volume: layer.volume,
                            currentTime: frameTime,
                            pixelsPerSecond: pixelsPerSecond,
                            width: contentWidth,
                            visibleX: viewport.visibleContentX,
                            snap: { timeline.snappedToFrame($0) },
                            onSeek: onScrub,
                            onMove: { from, to in onEditVolume(layer.id) { $0.moveKeyframe(at: from, to: to) } },
                            onDelete: { time in onEditVolume(layer.id) { $0.removeKeyframe(at: time) } },
                            onEase: { time, preset in onEditVolume(layer.id) { $0.applyEase(preset, at: time) } }
                        )
                    }
                    separator
                }
                // The same banding as the header column, so a layer reads
                // as one band all the way across the window.
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.018))
                .zIndex(draggingClipLayerID == layer.id ? 1 : 0)
            }
            NewLayerDropRow(height: newLayerRowHeight, kind: kind) { payloads, x in
                onDropScenes(payloads, nil, CMTime(seconds: max(0, Double(x / pixelsPerSecond)), preferredTimescale: 600), kind)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
    }

    // MARK: - Zoom and scrub

    /// Pinch and Option-scroll zoom about the pointer.
    private func zoom(_ laidOut: TimelineViewport, by factor: CGFloat, aboutX x: CGFloat) {
        // Pinch events arrive faster than layout; build on the newest state.
        let viewport = viewport(width: laidOut.width)
        apply(viewport.zoomed(to: viewport.pixelsPerSecond * factor, keeping: viewport.seconds(atX: x), atX: x))
    }

    /// A vertical pinch: the layers of the area under the pointer grow or
    /// shrink, and no other area's do.
    private func zoomLayerHeight(by factor: CGFloat, at pointer: CGPoint) {
        guard let kind = areaLayout.shown.first(where: { geometryStore.areas[$0]?.contains(pointer) == true }) else { return }
        areaLayout.setLayerHeight(kind, areaLayout.layerHeight(kind) * factor)
    }

    /// The zoom buttons, keys and slider zoom about the playhead: it stays
    /// where it is on screen, or comes to the middle if it was out of view.
    private func zoomAroundPlayhead(to pixelsPerSecond: CGFloat) {
        let viewport = currentViewport
        let seconds = livePlayheadTime.seconds
        let x = viewport.x(atSeconds: seconds)
        let anchorX = (0...viewport.width).contains(x) ? x : viewport.width / 2
        apply(viewport.zoomed(to: pixelsPerSecond, keeping: seconds, atX: anchorX))
    }

    private func zoomAroundPlayhead(by factor: CGFloat) {
        zoomAroundPlayhead(to: currentViewport.pixelsPerSecond * factor)
    }

    private func apply(_ zoom: (pixelsPerSecond: CGFloat?, scrollX: CGFloat)) {
        zoomedPixelsPerSecond = zoom.pixelsPerSecond
        scrollX = zoom.pixelsPerSecond == nil ? 0 : zoom.scrollX
    }

    /// Scrolls so `time` sits just inside the left edge: a page turn, as
    /// when playback runs off the right of the view.
    private func page(to time: CMTime) {
        let viewport = currentViewport
        scrollX = CGFloat(time.seconds) * viewport.pixelsPerSecond - viewport.width * 0.05
    }

    /// Lets drags at the edges of the tracks scroll them (`TimelineAutoScroll`).
    private func configureAutoScroll() {
        autoScroll.scrollBy = { distance in
            let before = currentViewport.scrollX
            scrollX = before + distance
            return currentViewport.scrollX - before
        }
        // The tracks start where the names column ends.
        autoScroll.trackSpan = {
            let start = geometryStore.namesColumn.maxX
            return start...(start + trackAreaWidth)
        }
    }

    /// Scrolls `time` to the middle of the view if it is out of view.
    private func reveal(_ time: CMTime) {
        let viewport = currentViewport
        let x = viewport.x(atSeconds: time.seconds)
        guard x < 0 || x > viewport.width else { return }
        scrollX = CGFloat(time.seconds) * viewport.pixelsPerSecond - viewport.width / 2
    }

    private func fitToWindow() {
        zoomedPixelsPerSecond = nil
        scrollX = 0
    }

    private var zoomFractionBinding: Binding<Double> {
        Binding(
            get: { currentViewport.zoomFraction },
            set: { zoomAroundPlayhead(to: currentViewport.pixelsPerSecond(atZoomFraction: $0)) }
        )
    }

    /// Only moves the playhead — per-clip selection and repositioning are
    /// owned by each clip block's own gesture in `LayerClipRow`, which sits
    /// above this and so claims clicks on clips first. The playhead lands
    /// on frames.
    private func scrubGesture(in viewport: TimelineViewport) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in scrub(atX: value.location.x, in: viewport) }
            .onEnded { value in scrub(atX: value.location.x, in: viewport) }
    }

    /// The same for views laid out across the whole span, whose x is in
    /// unscrolled content coordinates.
    private func scrub(atX x: CGFloat, in viewport: TimelineViewport) {
        let seconds = max(0, min(timeline.duration.seconds, viewport.seconds(atX: x)))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // With snapping on, the playhead snaps to clip edges and beat markers.
        let snapped = snapping
            ? project.snapTargets(in: timelineID, playhead: nil, markers: drawnBeats(viewport)).nearest(to: time, within: snapTolerance(viewport))
            : nil
        onScrub(timeline.snappedToFrame(snapped ?? time))
    }

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
            onSetEdge: { id, edge, time in onEditProject { $0.setSectionEdge(id, edge: edge, in: timelineID, to: time) } },
            onRename: { id, name in onEditProject { $0.renameSection(id, in: timelineID, to: name) } },
            onDelete: { id in
                onEditProject { $0.deleteSection(id, in: timelineID) }
                if selectedSectionID == id { selectedSectionID = nil }
            },
            onSnapIndicator: { snapIndicator = $0 }
        )
    }

    private func drawnBeats(_ viewport: TimelineViewport) -> [CMTime] {
        BeatMarkerOverlay.drawnMarkers(beatMarkers, pixelsPerSecond: viewport.pixelsPerSecond)
    }

    private func snapTolerance(_ viewport: TimelineViewport) -> CMTime {
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

    private func deleteLayer(_ id: UUID) {
        if selectedLayerID == id { selectedLayerID = nil }
        onDeleteLayer(id)
    }

    /// Delete removes the selected layer, else the selected transition,
    /// else the selected clip.
    private func deleteSelection() -> Bool {
        // The effects panel has the key while something in it is selected.
        if showsEffects, effectsState.hasSelection { return false }
        if let selectedSectionID, timeline.sections.contains(where: { $0.id == selectedSectionID }) {
            onEditProject { $0.deleteSection(selectedSectionID, in: timelineID) }
            self.selectedSectionID = nil
            return true
        }
        if let selectedLayerID, timeline.layer(id: selectedLayerID) != nil {
            deleteLayer(selectedLayerID)
            return true
        }
        guard let selection, selection.timelineID == timelineID else { return false }
        if let edge = selection.transitionEdge {
            onRemoveTransition(selection.layerID, selection.timelineClipID, edge)
        } else {
            onDeleteClip(selection.layerID, selection.timelineClipID)
        }
        return true
    }

    /// P, S, R and T show only position, scale, rotation or opacity (pressing
    /// the key again hides it); with Shift they add or remove that property
    /// and keep the others. They act on the selected clip's layer, or on
    /// every visual layer when nothing is selected.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let handled = handleNavigationKey(event, flags: flags) { return handled }
        // Delete and Forward Delete, without modifiers.
        if [51, 117].contains(event.keyCode), flags.isDisjoint(with: [.command, .control, .option, .shift]) {
            return deleteSelection()
        }
        // F9 eases, as in After Effects: Easy Ease, Shift for Ease In,
        // Command-Shift for Ease Out.
        if event.keyCode == 101, flags.isDisjoint(with: [.control, .option]) {
            let preset: KeyframeEase.Preset = flags.contains(.shift)
                ? (flags.contains(.command) ? .easeOut : .easeIn)
                : .easyEase
            return easeKeyframesAtPlayhead(preset)
        }
        guard flags.isDisjoint(with: [.command, .control, .option]),
              let key = event.charactersIgnoringModifiers?.lowercased().first
        else {
            return false
        }
        switch key {
        // Shift turns , and . into < and >: ten frames.
        case ",": return nudgeSelection(byFrames: -1)
        case ".": return nudgeSelection(byFrames: 1)
        case "<": return nudgeSelection(byFrames: -10)
        case ">": return nudgeSelection(byFrames: 10)
        case "=", "+": zoomAroundPlayhead(by: zoomStep); return true
        case "-": zoomAroundPlayhead(by: 1 / zoomStep); return true
        case "\\": fitToWindow(); return true
        default: break
        }
        if key == "e", flags == .shift {
            showsEffects.toggle()
            return true
        }
        if key == "n", !flags.contains(.shift) {
            snapping.toggle()
            return true
        }
        if let chosen = TimelineTool(shortcutKey: key), !flags.contains(.shift) {
            tool = chosen
            return true
        }
        if key == "l" { return toggleVolumeRows() }
        return false
    }

    // MARK: - Playhead keys and the Timeline menu

    /// What the Timeline menu does in this timeline. See `TimelineCommands`.
    private var actions: TimelineActions {
        TimelineActions(
            togglePlayback: { playback.togglePlayback() },
            step: { stepPlayhead(byFrames: $0) },
            goToStart: { parkPlayhead(at: .zero) },
            goToEnd: { parkPlayhead(at: timeline.duration) },
            previousEdit: { _ = jumpToEdit(forward: false) },
            nextEdit: { _ = jumpToEdit(forward: true) },
            splitAtPlayhead: { _ = splitAtPlayhead() },
            nudge: { _ = nudgeSelection(byFrames: $0) },
            deleteSelection: { _ = deleteSelection() },
            isSnapping: snapping,
            toggleSnapping: { snapping.toggle() },
            tool: tool,
            setTool: { tool = $0 },
            zoomIn: { zoomAroundPlayhead(by: zoomStep) },
            zoomOut: { zoomAroundPlayhead(by: 1 / zoomStep) },
            zoomToFit: { fitToWindow() },
            renderNow: renderer.flatMap { renderer in renderer.canRenderNow ? { renderer.renderNow() } : nil }
        )
    }

    /// ← and → step a frame (ten with Shift), ↑ and ↓ go to the previous or
    /// next edit, Home and End to the start and end. Nil for other keys.
    /// False, leaving the key alone, while a list or other control has the
    /// keyboard, since it uses these keys itself.
    private func handleNavigationKey(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool? {
        let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        let home: UInt16 = 115, end: UInt16 = 119
        guard [left, right, down, up, home, end].contains(event.keyCode),
              flags.isDisjoint(with: [.command, .control, .option])
        else {
            return nil
        }
        guard !(event.window?.firstResponder is NSControl) else { return false }
        let frames = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case left: stepPlayhead(byFrames: -frames)
        case right: stepPlayhead(byFrames: frames)
        case up: return jumpToEdit(forward: false)
        case down: return jumpToEdit(forward: true)
        case home: parkPlayhead(at: .zero)
        default: parkPlayhead(at: timeline.duration)
        }
        return true
    }

    /// Pauses and puts the playhead at `time`, on a frame within the
    /// timeline.
    private func parkPlayhead(at time: CMTime) {
        playback.player.pause()
        let parked = timeline.snappedToFrame(CMTimeMinimum(CMTimeMaximum(.zero, time), timeline.duration))
        onScrub(parked)
        reveal(parked)
    }

    /// Pauses and moves the playhead `frames` frames, back when negative.
    private func stepPlayhead(byFrames frames: Int) {
        let from = timeline.snappedToFrame(livePlayheadTime)
        parkPlayhead(at: CMTimeAdd(from, CMTimeMultiply(timeline.frameDuration, multiplier: Int32(clamping: frames))))
    }

    /// Moves the playhead to the nearest clip edge (or the timeline's end)
    /// after it, or before it. False when there is none that way.
    @discardableResult
    private func jumpToEdit(forward: Bool) -> Bool {
        let now = timeline.snappedToFrame(livePlayheadTime)
        let edges = timeline.layers.flatMap { $0.clips.flatMap { [$0.startOffset, $0.endOffset] } } + [timeline.duration]
        let frames = edges.map { timeline.snappedToFrame($0) }
        guard let target = forward ? frames.filter({ $0 > now }).min() : frames.filter({ $0 < now }).max() else {
            return false
        }
        parkPlayhead(at: target)
        return true
    }

    /// Moves the selected clip `frames` frames, later when positive, by the
    /// same rules as dragging it. False with no clip selected.
    @discardableResult
    private func nudgeSelection(byFrames frames: Int) -> Bool {
        guard let selection, selection.timelineID == timelineID,
              let clip = timeline.layer(id: selection.layerID)?.clips.first(where: { $0.id == selection.timelineClipID })
        else {
            return false
        }
        let distance = CMTimeMultiply(timeline.frameDuration, multiplier: Int32(clamping: frames))
        onMoveClip(selection.layerID, clip.id, nil, CMTimeMaximum(.zero, CMTimeAdd(clip.startOffset, distance)))
        return true
    }

    /// Splits at the playhead: the selected clip when the playhead is in
    /// it, otherwise every clip the playhead is in, on every layer. False
    /// when it is in none.
    @discardableResult
    private func splitAtPlayhead() -> Bool {
        let time = timeline.snappedToFrame(livePlayheadTime)
        func contains(_ clip: TimelineClip) -> Bool { time > clip.startOffset && time < clip.endOffset }
        var targets: [(layerID: UUID, clipID: UUID)] = []
        if let selection, selection.timelineID == timelineID,
           let clip = timeline.layer(id: selection.layerID)?.clips.first(where: { $0.id == selection.timelineClipID }),
           contains(clip) {
            targets = [(selection.layerID, clip.id)]
        } else {
            for layer in timeline.layers {
                for clip in layer.clips where contains(clip) { targets.append((layer.id, clip.id)) }
            }
        }
        for target in targets { onBladeClip(target.layerID, target.clipID, time) }
        return !targets.isEmpty
    }

    /// Eases the keyframes at the playhead in the property rows that are
    /// showing, under the selected clip's layer or under every layer when
    /// nothing is selected. False when there are none.
    private func easeKeyframesAtPlayhead(_ preset: KeyframeEase.Preset) -> Bool {
        let time = timeline.snappedToFrame(playheadTime)
        let layers: [TimelineLayer]
        if let selection, selection.timelineID == timelineID, let layer = timeline.layer(id: selection.layerID) {
            layers = [layer]
        } else {
            layers = timeline.layers
        }
        var eased = false
        // With the effects panel open, the selected clip's controls count.
        if showsEffects, let selection, selection.timelineID == timelineID,
           let clip = project.clipAndLayer(selection.timelineClipID, in: timelineID)?.clip {
            var copy = clip
            if copy.easeKeyframes(atTimelineTime: time, preset) {
                onEditProject { $0.editClip(clip.id, in: timelineID) { $0 = copy } }
                eased = true
            }
        }
        for layer in layers {
            if showsVolume(of: layer), layer.volume.keyframe(at: time) != nil {
                onEditVolume(layer.id) { $0.applyEase(preset, at: time) }
                eased = true
            }
        }
        return eased
    }

    /// L shows volume, as levels in After Effects (pressing it again hides
    /// it): each clip's as a line across it, and a Sound or Music layer's as
    /// a row under it. Acts on the selected clip's layer, or on every layer
    /// with sound when nothing is selected.
    private func toggleVolumeRows() -> Bool {
        let targets: [TimelineLayer]
        if let selection, selection.timelineID == timelineID, let layer = timeline.layer(id: selection.layerID) {
            targets = project.layerPlaysAudio(layer) ? [layer] : []
        } else {
            targets = timeline.layers.filter { project.layerPlaysAudio($0) }
        }
        guard !targets.isEmpty else { return false }
        let hiding = targets.allSatisfy { volumeRevealed.contains($0.id) }
        for layer in targets {
            if hiding { volumeRevealed.remove(layer.id) } else { volumeRevealed.insert(layer.id) }
        }
        return true
    }

}

/// The playhead drawn over the tracks. While playing it follows the player
/// itself, so only this view redraws on each tick rather than the whole
/// timeline; parked, it shows `parked`.
private struct LivePlayheadRail: View {
    let playback: PlaybackModel
    let parked: CMTime
    let viewport: TimelineViewport
    /// Called with the playhead's time when it leaves the view while
    /// playing (including when playing starts with it out of view), so the
    /// timeline can page after it. Nil not to follow.
    let onLeaveView: ((CMTime) -> Void)?
    let snapX: CGFloat?
    let height: CGFloat

    var body: some View {
        let playing = playback.isPlaying
        let time = playing ? playback.currentTime : parked
        let x = viewport.x(atSeconds: time.seconds)
        // Checked here because this is the one view that sees every tick;
        // the page turn itself is a scroll of the whole timeline.
        let leftView = playing && onLeaveView != nil && (x < 0 || x > viewport.width)
        PlayheadRail(
            playheadX: x,
            isPlayheadVisible: (-1...(viewport.width + 1)).contains(x),
            snapX: snapX,
            height: height
        )
        .frame(width: viewport.width, height: height)
        .onChange(of: leftView) { _, left in
            if left { onLeaveView?(time) }
        }
    }
}

/// The playhead's timecode in the timeline's header, following the player
/// while it plays, like `LivePlayheadRail`.
private struct PlayheadTimecode: View {
    let playback: PlaybackModel
    let parked: CMTime
    let frameRate: Double

    var body: some View {
        Text((playback.isPlaying ? playback.currentTime : parked).timecode(frameRate: frameRate))
            .font(Design.Typeface.numericSmall)
            .foregroundStyle(Design.textSecondary)
    }
}

/// Labels the per-layer columns, beside the ruler — currently just
/// number/name, but reserved as the home for upcoming per-layer option
/// controls (visibility, lock, etc.).
struct TimelineColumnHeaderRow: View {
    let height: CGFloat

    var body: some View {
        HStack(spacing: Design.Space.close) {
            Color.clear.frame(width: 12)
            Text("#")
                .frame(width: 18, alignment: .trailing)
            Text("Name")
            Spacer()
        }
        .font(Design.Typeface.micro)
        .foregroundStyle(Design.textTertiary)
        .padding(.horizontal, Design.Space.step)
        .padding(.bottom, Design.Space.tight)
        .frame(height: height, alignment: .bottomLeading)
    }
}

/// The slim row under an area's layers: scenes dropped here go on a new
/// layer of the area's kind at the drop time. It says so while something
/// is dragged over it, and is otherwise empty space.
private struct NewLayerDropRow: View {
    let height: CGFloat
    let kind: LayerKind
    let onDrop: ([SceneDragPayload], CGFloat) -> Bool

    @State private var isTargeted = false

    var body: some View {
        Text(isTargeted ? "Drop here for a new \(kind.name.lowercased()) layer" : "")
            .font(Design.Typeface.micro)
            .foregroundStyle(Design.accent)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(isTargeted ? Design.accent.opacity(0.14) : .clear)
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(Design.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            .editorAnimation(Design.Motion.select, value: isTargeted)
            .dropDestination(for: SceneDragPayload.self) { payloads, location in
                onDrop(payloads, location.x)
            } isTargeted: { isTargeted = $0 }
    }
}
