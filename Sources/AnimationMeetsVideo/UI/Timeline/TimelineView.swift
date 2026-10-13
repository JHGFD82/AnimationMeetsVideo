import AppKit
import CoreMedia
import SwiftUI

struct TimelineView: View {
    let project: EditingProject
    let timeline: Timeline
    let timelineID: UUID
    let selection: TimelineSelection?
    let beatTracks: [UUID: BeatTrack]
    @Binding var playheadTime: CMTime
    let onScrub: (CMTime) -> Void
    let onSelectClip: (UUID, TimelineClip) -> Void
    let onRenameLayer: (UUID, String?) -> Void
    let onMoveLayer: (UUID, Int) -> Void
    let onMoveClip: (UUID, UUID, CMTime) -> Void
    let onTrimClipStart: (UUID, UUID, CMTime) -> Void
    let onTrimClipEnd: (UUID, UUID, CMTime) -> Void
    let onEditTransform: (UUID, (inout LayerTransform) -> Void) -> Void

    @State private var zoomScale: CGFloat = 1
    /// The transform properties shown under each layer, by layer ID.
    @State private var revealed: [UUID: Set<TransformProperty>] = [:]
    @State private var layerHeight: CGFloat = 56
    @State private var showingViewOptions = false
    /// The layer whose beats are shown. Only layers that still have beats are
    /// offered, so a deleted layer simply stops matching and markers vanish.
    @State private var chosenBeatLayerID: UUID?
    /// The chosen layer's markers, worked out again only when what they
    /// depend on changes. The view's body runs on every playback tick and
    /// scroll, and a long song has thousands of beats to collect and sort.
    @State private var beatMarkers: [CMTime] = []
    @GestureState private var magnifyBy: CGFloat = 1
    @State private var scrollMetrics = TimelineScrollMetrics()

    private let rulerHeight: CGFloat = 26
    private let columnHeaderHeight: CGFloat = 20
    private let propertyRowHeight: CGFloat = 22

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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Timeline", systemImage: "timeline.selection")
                    .font(.headline)
                Spacer()
                Text(playheadTime.timecode(frameRate: timeline.frameRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    showingViewOptions = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("View options")
                .popover(isPresented: $showingViewOptions) {
                    ViewOptionsPopover(
                        zoomScale: $zoomScale, layerHeight: $layerHeight,
                        beatLayers: beatLayerChoices, beatLayerID: beatLayerSelection
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            GeometryReader { geometry in
                let availableWidth = max(1, geometry.size.width - labelColumnWidth)
                // Never leave blank trailing space: at zoom == 1 the whole
                // duration exactly fills the available width, even for a
                // single-frame timeline. Zooming in (>1) can scroll past
                // the visible width; zoom is clamped so you can't zoom out
                // past that fit-to-width baseline.
                let minimumSeconds = max(1.0 / max(timeline.frameRate, 1), 1.0 / 60)
                let fitPixelsPerSecond = availableWidth / CGFloat(max(timeline.duration.seconds, minimumSeconds))
                let effectiveZoom = max(1, zoomScale * magnifyBy)
                let pixelsPerSecond = fitPixelsPerSecond * effectiveZoom
                let contentWidth = max(availableWidth, CGFloat(timeline.duration.seconds) * pixelsPerSecond)
                let propertyRowCount = timeline.layers.reduce(0) { $0 + shownProperties(of: $1).count }
                let contentHeight = rulerHeight + columnHeaderHeight + CGFloat(timeline.layers.count) * layerHeight
                    + CGFloat(propertyRowCount) * propertyRowHeight
                let markers = beatMarkers
                let frameTime = timeline.snappedToFrame(playheadTime)

                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: rulerHeight)
                            TimelineColumnHeaderRow(height: columnHeaderHeight)
                            Divider()
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
                                    onRename: { name in onRenameLayer(layer.id, name) },
                                    onMove: { offset in onMoveLayer(layer.id, offset) }
                                )
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
                        .frame(width: labelColumnWidth, alignment: .leading)
                        .background(.background)
                        .offset(x: scrollMetrics.offsetX)
                        .zIndex(1)

                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 0) {
                                TimelineRuler(
                                    duration: timeline.duration,
                                    frameRate: timeline.frameRate,
                                    pixelsPerSecond: pixelsPerSecond,
                                    visibleX: (scrollMetrics.offsetX - labelColumnWidth)...(scrollMetrics.offsetX + scrollMetrics.viewportWidth - labelColumnWidth)
                                )
                                .frame(height: rulerHeight, alignment: .leading)
                                Color.clear.frame(height: columnHeaderHeight)
                                Divider()
                                ForEach(timeline.layers) { layer in
                                    VStack(spacing: 0) {
                                        LayerClipRow(
                                            layer: layer,
                                            project: project,
                                            selection: selection,
                                            pixelsPerSecond: pixelsPerSecond,
                                            width: contentWidth,
                                            height: layerHeight,
                                            onSelectClip: { clip in onSelectClip(layer.id, clip) },
                                            onMoveClip: { clipID, newStart in onMoveClip(layer.id, clipID, newStart) },
                                            onTrimClipStart: { clipID, newStart in onTrimClipStart(layer.id, clipID, newStart) },
                                            onTrimClipEnd: { clipID, newEnd in onTrimClipEnd(layer.id, clipID, newEnd) }
                                        )
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
                            if !markers.isEmpty {
                                BeatMarkerOverlay(
                                    markers: markers,
                                    pixelsPerSecond: pixelsPerSecond,
                                    rulerHeight: rulerHeight,
                                    height: contentHeight,
                                    visibleX: (scrollMetrics.offsetX - labelColumnWidth)...(scrollMetrics.offsetX + scrollMetrics.viewportWidth - labelColumnWidth)
                                )
                            }
                            PlayheadLine(time: playheadTime, pixelsPerSecond: pixelsPerSecond, height: contentHeight)
                        }
                        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in scrub(at: value.location, pixelsPerSecond: pixelsPerSecond) }
                                .onEnded { value in scrub(at: value.location, pixelsPerSecond: pixelsPerSecond) }
                        )
                        .simultaneousGesture(
                            MagnificationGesture()
                                .updating($magnifyBy) { value, state, _ in state = value }
                                .onEnded { value in
                                    zoomScale = max(1, zoomScale * value)
                                }
                        )
                    }
                }
                .onScrollGeometryChange(for: TimelineScrollMetrics.self) { geometry in
                    TimelineScrollMetrics(offsetX: max(0, geometry.contentOffset.x), viewportWidth: geometry.containerSize.width)
                } action: { _, metrics in
                    scrollMetrics = metrics
                }
            }
        }
        .padding(.vertical, 12)
        .background(KeyPressMonitor(handler: handleKey))
        .onChange(of: beatMarkerInputs, initial: true) { _, inputs in
            beatMarkers = inputs.layer.map { project.beatMarkers(in: $0, tracks: inputs.tracks) } ?? []
        }
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
              let key = event.charactersIgnoringModifiers?.lowercased().first,
              let property = TransformProperty(shortcutKey: key)
        else {
            return false
        }
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

    /// Only moves the playhead — per-clip selection and repositioning are
    /// owned by each clip block's own gesture in `LayerClipRow`, since this
    /// background gesture and a clip's gesture would otherwise both try to
    /// claim the same click.
    private func scrub(at location: CGPoint, pixelsPerSecond: CGFloat) {
        let seconds = max(0, min(timeline.duration.seconds, Double(location.x / pixelsPerSecond)))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        onScrub(time)
    }
}

struct TimelineScrollMetrics: Equatable {
    var offsetX: CGFloat = 0
    var viewportWidth: CGFloat = 1_200
}

/// A sub-header beneath the ruler labeling the per-layer columns — currently
/// just number/name, but reserved as the home for upcoming per-layer option
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
        .frame(height: height, alignment: .leading)
    }
}
