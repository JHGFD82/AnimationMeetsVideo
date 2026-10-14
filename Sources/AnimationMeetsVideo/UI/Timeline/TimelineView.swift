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
    @Binding var playheadTime: CMTime
    let onScrub: (CMTime) -> Void
    let onSelectClip: (UUID, TimelineClip) -> Void
    let onRenameLayer: (UUID, String?) -> Void
    let onMoveLayer: (UUID, Int) -> Void
    /// Moves a layer to an index in the stack, after dragging its header.
    let onMoveLayerTo: (UUID, Int) -> Void
    /// Layer, clip, the layer it moves to if another, and its new start.
    let onMoveClip: (UUID, UUID, UUID?, CMTime) -> Void
    /// Scenes dropped on a layer (or, with nil, below the layers) at a time.
    let onDropScenes: ([SceneDragPayload], UUID?, CMTime) -> Bool
    let onApplyJointEdit: (UUID, UUID, JointEdit) -> Void
    /// The height the timeline needs to show every layer without empty
    /// space under them, so the window can give the rest to the viewer.
    let onIdealHeightChange: (CGFloat) -> Void
    let onTrimClipStart: (UUID, UUID, CMTime) -> Void
    let onTrimClipEnd: (UUID, UUID, CMTime) -> Void
    let onEditTransform: (UUID, (inout LayerTransform) -> Void) -> Void
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
    let onRippleTrimStart: (UUID, UUID, CMTime) -> Void
    let onRippleTrimEnd: (UUID, UUID, CMTime) -> Void
    /// The clip as a ripple drag would leave it, for the viewer to show its
    /// first and last frames; nil when the drag ends.
    let onTrimPreview: (TimelineClip?) -> Void
    @Binding var showsTransitions: Bool

    /// The chosen zoom, or nil while the whole timeline is fitted to the
    /// window. Kept in points per second, not relative to the fit, so
    /// moving a clip past the end doesn't rescale everything.
    @State private var zoomedPixelsPerSecond: CGFloat?
    @State private var scrollX: CGFloat = 0
    @State private var trackAreaWidth: CGFloat = 800
    /// The transform properties shown under each layer, by layer ID.
    @State private var revealed: [UUID: Set<TransformProperty>] = [:]
    /// Layers showing their video clips' linked audio.
    @State private var audioRevealed: Set<UUID> = []
    @State private var layerHeight: CGFloat = 56
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
    /// The incoming clip of the joining transition whose footage is open.
    @State private var expandedJoint: UUID?
    @State private var headerBarHeight: CGFloat = 32
    /// The layer selected by its header, for Delete. Selecting a clip clears it.
    @State private var selectedLayerID: UUID?
    @State private var tool: TimelineTool = .arrow
    @AppStorage("clickOnBeats") private var clickOnBeats = false
    @AppStorage("beatClickFrequency") private var beatClickFrequency = 1000.0

    private let rulerHeight: CGFloat = 28
    private let propertyRowHeight: CGFloat = 22
    private let separatorHeight: CGFloat = 1
    /// A slim row under the layers that takes drops as a new layer.
    private let newLayerRowHeight: CGFloat = 22
    private let topPadding: CGFloat = 6

    /// The joining transition whose footage is open on this layer.
    private func shownJoint(in layer: TimelineLayer) -> TransitionJoint? {
        guard let id = expandedJoint, layer.clips.contains(where: { $0.id == id }) else { return nil }
        return project.joint(at: id, in: timelineID, layer: layer.id)
    }

    /// Everything one layer shows, top to bottom. The header column and the
    /// track area lay out the same rows, so this is each layer's height in
    /// both.
    private func blockHeight(of layer: TimelineLayer) -> CGFloat {
        layerHeight
            + (shownJoint(in: layer) != nil ? TransitionFootageLane.height : 0)
            + (showsLinkedAudio(of: layer) ? audioLaneHeight : 0)
            + CGFloat(shownProperties(of: layer).count) * propertyRowHeight
            + separatorHeight
    }

    private var layerTops: [CGFloat] {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for layer in timeline.layers {
            tops.append(y)
            y += blockHeight(of: layer)
        }
        return tops
    }

    private var contentHeight: CGFloat {
        timeline.layers.reduce(0) { $0 + blockHeight(of: $1) } + newLayerRowHeight
    }

    private var idealHeight: CGFloat {
        let scrollbar = currentViewport.maxScrollX > 0 ? TimelineScrollbar.height : 0
        return topPadding + headerBarHeight + rulerHeight + separatorHeight + contentHeight + scrollbar
    }

    private var audioLaneHeight: CGFloat { max(22, (layerHeight * 0.6).rounded()) }

    private func showsLinkedAudio(of layer: TimelineLayer) -> Bool {
        audioRevealed.contains(layer.id) && project.layerHasLinkedAudio(layer)
    }
    private let zoomStep: CGFloat = 1.5

    /// Wider while property rows are showing, to fit their values.
    private var labelColumnWidth: CGFloat {
        timeline.layers.contains { !shownProperties(of: $0).isEmpty } ? 300 : 150
    }

    /// The layer's shown properties, in standard order. Audio layers have none.
    private func shownProperties(of layer: TimelineLayer) -> [TransformProperty] {
        guard let set = revealed[layer.id], !set.isEmpty else { return [] }
        return TransformProperty.allCases.filter(set.contains)
    }

    private var beatLayerChoices: [(id: UUID, name: String)] {
        timeline.layers.enumerated()
            .filter { project.layerHasBeats($0.element, tracks: beatTracks) }
            .map { (id: $0.element.id, name: project.displayName(of: $0.element, number: $0.offset + 1)) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Timeline", systemImage: "timeline.selection")
                    .font(.headline)
                Picker("Tool", selection: $tool) {
                    ForEach(TimelineTool.allCases) { tool in
                        Image(systemName: tool.systemImage)
                            .help(tool.help)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(tool.help)
                Spacer()
                Text(playheadTime.timecode(frameRate: timeline.frameRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                ControlGroup {
                    Button { zoomAroundPlayhead(by: 1 / zoomStep) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out (-)")
                    Button { zoomAroundPlayhead(by: zoomStep) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in (=)")
                }
                .fixedSize()
                Button {
                    showingViewOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("View options")
                .popover(isPresented: $showingViewOptions) {
                    ViewOptionsPopover(
                        zoomFraction: zoomFractionBinding, onFit: fitToWindow, layerHeight: $layerHeight,
                        beatLayers: beatLayerChoices, beatLayerID: beatLayerSelection,
                        clickOnBeats: $clickOnBeats, clickFrequency: $beatClickFrequency,
                        onPreviewClick: beatClicks.preview
                    )
                }
                Toggle(isOn: $showsTransitions) {
                    Image(systemName: "square.on.square.dashed")
                }
                .toggleStyle(.button)
                .help(showsTransitions ? "Hide transitions" : "Show transitions")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerBarHeight = $0 }

            GeometryReader { geometry in
                let viewport = viewport(width: geometry.size.width - labelColumnWidth)
                let scrollbarHeight = viewport.maxScrollX > 0 ? TimelineScrollbar.height : 0
                let layersHeight = min(contentHeight, max(0, geometry.size.height - rulerHeight - separatorHeight - scrollbarHeight))
                let trackHeight = rulerHeight + separatorHeight + layersHeight
                let frameTime = timeline.snappedToFrame(playheadTime)
                let playheadX = viewport.x(atSeconds: playheadTime.seconds)
                let playheadVisible = (-1...(viewport.width + 1)).contains(playheadX)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        TimelineColumnHeaderRow(height: rulerHeight)
                            .frame(width: labelColumnWidth, alignment: .leading)
                        TimelineRuler(duration: timeline.duration, frameRate: timeline.frameRate, viewport: viewport)
                            .frame(width: viewport.width, height: rulerHeight)
                            .overlay(alignment: .bottom) { RenderStatusStrip(viewport: viewport) }
                            .contentShape(Rectangle())
                            .gesture(scrubGesture(in: viewport))
                    }
                    Divider()

                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            layerHeaders(frameTime: frameTime)
                                .frame(width: labelColumnWidth, alignment: .leading)
                            layerTracks(viewport: viewport, frameTime: frameTime)
                                .offset(x: -viewport.scrollX)
                                .frame(width: viewport.width, alignment: .topLeading)
                                .clipped()
                        }
                        .overlay(alignment: .topLeading) { layerDropIndicator }
                    }
                    .frame(height: layersHeight)

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
                        if playheadVisible {
                            PlayheadLine(x: playheadX, height: trackHeight)
                            PlayheadHead(x: playheadX)
                        }
                    }
                    .frame(width: viewport.width, height: trackHeight, alignment: .topLeading)
                    .clipped()
                    .offset(x: labelColumnWidth)
                    .allowsHitTesting(false)
                }
                .background(
                    TimelineInputMonitor(
                        onMagnify: { factor, x in
                            guard x >= labelColumnWidth else { return }
                            zoom(viewport, by: factor, aboutX: x - labelColumnWidth)
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
        .onChange(of: selection) { _, newValue in
            if newValue != nil { selectedLayerID = nil }
        }
        .onChange(of: idealHeight, initial: true) { _, height in onIdealHeightChange(height) }
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

    // MARK: - Layer and clip dragging

    /// Where a layer dragged by `dy` would go: the number of other layers
    /// whose middle is above its middle.
    private func dropIndex(forLayer id: UUID, dy: CGFloat) -> Int? {
        let tops = layerTops
        guard let from = timeline.layers.firstIndex(where: { $0.id == id }) else { return nil }
        let middle = tops[from] + blockHeight(of: timeline.layers[from]) / 2 + dy
        return timeline.layers.indices.filter { index in
            index != from && tops[index] + blockHeight(of: timeline.layers[index]) / 2 < middle
        }.count
    }

    /// A line where a dragged layer will land.
    @ViewBuilder
    private var layerDropIndicator: some View {
        if let drag = layerDrag, let index = dropIndex(forLayer: drag.id, dy: drag.dy) {
            let others = timeline.layers.indices.filter { timeline.layers[$0].id != drag.id }
            let tops = layerTops
            let y = index < others.count
                ? tops[others[index]]
                : tops.last.map { $0 + blockHeight(of: timeline.layers[timeline.layers.count - 1]) } ?? 0
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }

    private func endLayerDrag(_ id: UUID, dy: CGFloat) {
        if let index = dropIndex(forLayer: id, dy: dy),
           index != timeline.layers.firstIndex(where: { $0.id == id }) {
            onMoveLayerTo(id, index)
        }
        layerDrag = nil
    }

    /// Where a clip dragged by `dy` from its layer and asked to start at
    /// `start` lands: on the layer under the pointer when that layer has
    /// room for it, otherwise on its own layer.
    private func resolveMove(_ clip: TimelineClip, from layerID: UUID, dy: CGFloat, to start: CMTime) -> ClipMovePreview? {
        let tops = layerTops
        guard let from = timeline.layers.firstIndex(where: { $0.id == layerID }) else { return nil }
        let y = tops[from] + layerHeight / 2 + dy
        if let target = timeline.layers.indices.last(where: { tops[$0] <= y }),
           target != from, y < tops[target] + blockHeight(of: timeline.layers[target]),
           let landed = project.resolvedStart(ofMoving: clip.id, in: timelineID, layer: layerID, onto: timeline.layers[target].id, to: start) {
            return ClipMovePreview(start: landed, layerID: timeline.layers[target].id, offsetY: tops[target] - tops[from])
        }
        return project.resolvedStart(ofMoving: clip.id, in: timelineID, layer: layerID, to: start)
            .map { ClipMovePreview(start: $0, layerID: nil, offsetY: 0) }
    }

    private func layerHeaders(frameTime: CMTime) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(timeline.layers.enumerated()), id: \.element.id) { index, layer in
                let isDragged = layerDrag?.id == layer.id
                VStack(alignment: .leading, spacing: 0) {
                    LayerHeaderRow(
                        number: index + 1,
                        layer: layer,
                        project: project,
                        height: layerHeight,
                        canMoveUp: index > 0,
                        canMoveDown: index < timeline.layers.count - 1,
                        isExpanded: layer.isVisual(in: project) ? !shownProperties(of: layer).isEmpty : nil,
                        onToggleExpanded: { toggleExpanded(layer) },
                        isAudioExpanded: project.layerHasLinkedAudio(layer) ? showsLinkedAudio(of: layer) : nil,
                        onToggleAudio: { toggleLinkedAudio(layer) },
                        onDetachAudio: { onDetachAudio(layer.id, nil) },
                        onRename: { name in onRenameLayer(layer.id, name) },
                        onMove: { offset in onMoveLayer(layer.id, offset) },
                        onDragChanged: { dy in layerDrag = (layer.id, dy) },
                        onDragEnded: { dy in endLayerDrag(layer.id, dy: dy) },
                        isSelected: selectedLayerID == layer.id,
                        onSelect: {
                            selectedLayerID = layer.id
                            onSelectLayer()
                        },
                        onDelete: { deleteLayer(layer.id) }
                    )
                    if shownJoint(in: layer) != nil {
                        HStack {
                            Label("Transition Footage", systemImage: "square.on.square.dashed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Done") { expandedJoint = nil }
                                .controlSize(.small)
                        }
                        .padding(.leading, 30)
                        .padding(.trailing, 8)
                        .frame(height: TransitionFootageLane.height)
                    }
                    if showsLinkedAudio(of: layer) {
                        Label("Linked Audio", systemImage: "waveform")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 30)
                            .frame(height: audioLaneHeight, alignment: .leading)
                            .contextMenu {
                                Button("Detach Audio") { onDetachAudio(layer.id, nil) }
                            }
                    }
                    ForEach(shownProperties(of: layer)) { property in
                        TransformPropertyRow(
                            property: property,
                            transform: layer.transform,
                            time: frameTime,
                            frameSize: timeline.frameSize,
                            onEdit: { change in onEditTransform(layer.id, change) },
                            onSeek: onScrub
                        )
                        .padding(.leading, 30)
                        .padding(.trailing, 8)
                        .frame(height: propertyRowHeight)
                    }
                    separator
                }
                .background(.background)
                .background(isDragged ? Color.accentColor.opacity(0.15) : .clear)
                .shadow(color: .black.opacity(isDragged ? 0.3 : 0), radius: 4)
                .offset(y: isDragged ? layerDrag?.dy ?? 0 : 0)
                .zIndex(isDragged ? 1 : 0)
            }
            Color.clear.frame(height: newLayerRowHeight)
        }
        .background(.background)
    }

    /// A fixed-height line between layers, so the two columns line up and
    /// layer positions can be worked out for dragging.
    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: separatorHeight)
    }

    /// Every layer's clips and keyframe lanes, laid out across the whole
    /// span in unscrolled coordinates; the caller shifts them into view.
    private func layerTracks(viewport: TimelineViewport, frameTime: CMTime) -> some View {
        let pixelsPerSecond = viewport.pixelsPerSecond
        let contentWidth = viewport.contentWidth
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(timeline.layers) { layer in
                VStack(spacing: 0) {
                    LayerClipRow(
                        layer: layer,
                        project: project,
                        timelineID: timelineID,
                        selection: selection,
                        pixelsPerSecond: pixelsPerSecond,
                        width: contentWidth,
                        height: layerHeight,
                        visibleX: viewport.visibleContentX,
                        onSelectClip: { clip in onSelectClip(layer.id, clip) },
                        resolveMove: { clip, dy, start in resolveMove(clip, from: layer.id, dy: dy, to: start) },
                        onMoveClip: { clipID, target, newStart in onMoveClip(layer.id, clipID, target, newStart) },
                        onDraggingClip: { dragging in draggingClipLayerID = dragging ? layer.id : nil },
                        onDropScenes: { payloads, time in onDropScenes(payloads, layer.id, time) },
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
                        onRippleTrimStart: { clipID, trimStart in onRippleTrimStart(layer.id, clipID, trimStart) },
                        onRippleTrimEnd: { clipID, trimEnd in onRippleTrimEnd(layer.id, clipID, trimEnd) },
                        onTrimPreview: onTrimPreview
                    )
                    // Empty space on a layer scrubs; clips claim their own clicks.
                    .gesture(contentScrubGesture(in: viewport))
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
                            height: audioLaneHeight,
                            visibleX: viewport.visibleContentX,
                            onSelectClip: { clip in onSelectClip(layer.id, clip) },
                            onDetachAudio: { clipID in onDetachAudio(layer.id, [clipID]) }
                        )
                    }
                    ForEach(shownProperties(of: layer)) { property in
                        KeyframeLane(
                            times: layer.transform.keyframeTimes(property),
                            currentTime: frameTime,
                            pixelsPerSecond: pixelsPerSecond,
                            width: contentWidth,
                            height: propertyRowHeight,
                            snap: { timeline.snappedToFrame($0) },
                            onSeek: onScrub,
                            onMove: { from, to in
                                onEditTransform(layer.id) { $0.moveKeyframe(property, at: from, to: to) }
                            },
                            onDelete: { time in
                                onEditTransform(layer.id) { $0.removeKeyframe(property, at: time) }
                            }
                        )
                    }
                    separator
                }
                .zIndex(draggingClipLayerID == layer.id ? 1 : 0)
            }
            NewLayerDropRow(height: newLayerRowHeight) { payloads, x in
                onDropScenes(payloads, nil, CMTime(seconds: max(0, Double(x / pixelsPerSecond)), preferredTimescale: 600))
            }
            .gesture(contentScrubGesture(in: viewport))
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

    /// The zoom buttons, keys and slider zoom about the playhead: it stays
    /// where it is on screen, or comes to the middle if it was out of view.
    private func zoomAroundPlayhead(to pixelsPerSecond: CGFloat) {
        let viewport = currentViewport
        let seconds = playheadTime.seconds
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
    private func contentScrubGesture(in viewport: TimelineViewport) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in scrub(atX: value.location.x - viewport.scrollX, in: viewport) }
            .onEnded { value in scrub(atX: value.location.x - viewport.scrollX, in: viewport) }
    }

    private func scrub(atX x: CGFloat, in viewport: TimelineViewport) {
        let seconds = max(0, min(timeline.duration.seconds, viewport.seconds(atX: x)))
        onScrub(timeline.snappedToFrame(CMTime(seconds: seconds, preferredTimescale: 600)))
    }

    private func toggleLinkedAudio(_ layer: TimelineLayer) {
        if audioRevealed.contains(layer.id) { audioRevealed.remove(layer.id) } else { audioRevealed.insert(layer.id) }
    }

    /// The disclosure arrow shows all four properties, or hides them all.
    private func toggleExpanded(_ layer: TimelineLayer) {
        revealed[layer.id] = shownProperties(of: layer).isEmpty ? Set(TransformProperty.allCases) : []
    }

    /// P, S, R and T show only position, scale, rotation or opacity (pressing
    /// the key again hides it); with Shift they add or remove that property
    /// and keep the others. They act on the selected clip's layer, or on
    /// every visual layer when nothing is selected.
    private func deleteLayer(_ id: UUID) {
        if selectedLayerID == id { selectedLayerID = nil }
        onDeleteLayer(id)
    }

    /// Delete removes the selected layer, else the selected transition,
    /// else the selected clip.
    private func deleteSelection() -> Bool {
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

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Delete and Forward Delete, without modifiers.
        if [51, 117].contains(event.keyCode), flags.isDisjoint(with: [.command, .control, .option, .shift]) {
            return deleteSelection()
        }
        guard flags.isDisjoint(with: [.command, .control, .option]),
              let key = event.charactersIgnoringModifiers?.lowercased().first
        else {
            return false
        }
        switch key {
        case "=", "+": zoomAroundPlayhead(by: zoomStep); return true
        case "-": zoomAroundPlayhead(by: 1 / zoomStep); return true
        case "\\": fitToWindow(); return true
        default: break
        }
        if let chosen = TimelineTool(shortcutKey: key), !flags.contains(.shift) {
            tool = chosen
            return true
        }
        guard let property = TransformProperty(shortcutKey: key) else { return false }
        let targets: [TimelineLayer]
        if let selection, selection.timelineID == timelineID, let layer = timeline.layer(id: selection.layerID) {
            targets = layer.isVisual(in: project) ? [layer] : []
        } else {
            targets = timeline.layers.filter { $0.isVisual(in: project) }
        }
        guard !targets.isEmpty else { return false }
        for layer in targets {
            var shown = revealed[layer.id] ?? []
            if flags.contains(.shift) {
                if shown.contains(property) { shown.remove(property) } else { shown.insert(property) }
            } else {
                shown = shown == [property] ? [] : [property]
            }
            revealed[layer.id] = shown
        }
        return true
    }

}

/// Labels the per-layer columns, beside the ruler — currently just
/// number/name, but reserved as the home for upcoming per-layer option
/// controls (visibility, lock, etc.).
struct TimelineColumnHeaderRow: View {
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 12)
            Text("#")
                .frame(width: 18, alignment: .trailing)
            Text("Name")
            Spacer()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .frame(height: height, alignment: .bottomLeading)
    }
}

/// The slim row under the layers: scenes dropped here go on a new layer at
/// the drop time. It says so while something is dragged over it, and is
/// otherwise empty space that scrubs like the rest of the track area.
private struct NewLayerDropRow: View {
    let height: CGFloat
    let onDrop: ([SceneDragPayload], CGFloat) -> Bool

    @State private var isTargeted = false

    var body: some View {
        Text(isTargeted ? "Drop for a new layer" : "")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(isTargeted ? Color.accentColor.opacity(0.12) : .clear)
            .contentShape(Rectangle())
            .dropDestination(for: SceneDragPayload.self) { payloads, location in
                onDrop(payloads, location.x)
            } isTargeted: { isTargeted = $0 }
    }
}
