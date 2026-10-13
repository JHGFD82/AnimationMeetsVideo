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
    let onMoveClip: (UUID, UUID, CMTime) -> Void
    let onTrimClipStart: (UUID, UUID, CMTime) -> Void
    let onTrimClipEnd: (UUID, UUID, CMTime) -> Void
    let onEditTransform: (UUID, (inout LayerTransform) -> Void) -> Void
    /// Detaches the sound of the given clips on a layer, or of all its
    /// linked clips when nil.
    let onDetachAudio: (UUID, Set<UUID>?) -> Void

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
    @AppStorage("clickOnBeats") private var clickOnBeats = false
    @AppStorage("beatClickFrequency") private var beatClickFrequency = 1000.0

    private let rulerHeight: CGFloat = 28
    private let propertyRowHeight: CGFloat = 22

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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            GeometryReader { geometry in
                let viewport = viewport(width: geometry.size.width - labelColumnWidth)
                let trackHeight = max(0, geometry.size.height - TimelineScrollbar.height)
                let frameTime = timeline.snappedToFrame(playheadTime)
                let playheadX = viewport.x(atSeconds: playheadTime.seconds)
                let playheadVisible = (-1...(viewport.width + 1)).contains(playheadX)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        TimelineColumnHeaderRow(height: rulerHeight)
                            .frame(width: labelColumnWidth, alignment: .leading)
                        TimelineRuler(duration: timeline.duration, frameRate: timeline.frameRate, viewport: viewport)
                            .frame(width: viewport.width, height: rulerHeight)
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
                        .frame(minHeight: max(0, trackHeight - rulerHeight - 1), alignment: .top)
                        .background(alignment: .topTrailing) {
                            // Empty space under the layers scrubs too.
                            Color.clear
                                .frame(width: viewport.width)
                                .contentShape(Rectangle())
                                .gesture(scrubGesture(in: viewport))
                        }
                    }

                    HStack(spacing: 0) {
                        Color.clear.frame(width: labelColumnWidth)
                        TimelineScrollbar(viewport: viewport) { scrollX = $0 }
                    }
                }
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
        .padding(.vertical, 12)
        .background(KeyPressMonitor(handler: handleKey))
        .onChange(of: beatMarkerInputs, initial: true) { _, inputs in
            beatMarkers = inputs.layer.map { project.beatMarkers(in: $0, tracks: inputs.tracks) } ?? []
        }
        .onChange(of: beatMarkers, initial: true) { _, markers in beatClicks.beats = markers }
        .onChange(of: clickOnBeats, initial: true) { _, on in beatClicks.isEnabled = on }
        .onChange(of: beatClickFrequency, initial: true) { _, hertz in beatClicks.frequency = hertz }
        .onChange(of: timelineID) { _, _ in
            zoomedPixelsPerSecond = nil
            scrollX = 0
        }
    }

    private func layerHeaders(frameTime: CMTime) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(timeline.layers.enumerated()), id: \.element.id) { index, layer in
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
                    onMove: { offset in onMoveLayer(layer.id, offset) }
                )
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
                Divider()
            }
        }
        .background(.background)
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
                        onMoveClip: { clipID, newStart in onMoveClip(layer.id, clipID, newStart) },
                        onTrimClipStart: { clipID, newStart in onTrimClipStart(layer.id, clipID, newStart) },
                        onTrimClipEnd: { clipID, newEnd in onTrimClipEnd(layer.id, clipID, newEnd) },
                        onDetachAudio: { clipID in onDetachAudio(layer.id, [clipID]) }
                    )
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
                    Divider()
                }
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
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
