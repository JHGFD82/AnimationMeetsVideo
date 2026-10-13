import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

struct TimelineSelection: Equatable {
    var timelineID: UUID
    var layerID: UUID
    var timelineClipID: UUID
}

struct EditorView: View {
    @Binding var project: EditingProject
    @State private var activeTimelineID: UUID
    @State private var selection: TimelineSelection?
    @State private var playback = PlaybackModel()
    @State private var annotations = AnnotationModel()
    @State private var externalDisplay = ExternalDisplayController()

    init(project: Binding<EditingProject>) {
        self._project = project
        self._activeTimelineID = State(initialValue: project.wrappedValue.rootTimelineID)
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(project: $project, activeTimelineID: $activeTimelineID, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                EditorToolbar(
                    project: $project,
                    activeTimelineID: $activeTimelineID,
                    selection: $selection,
                    playback: playback,
                    annotations: annotations,
                    externalDisplay: externalDisplay
                )
                Divider()
                TimelineEditorSurface(project: $project, timelineID: $activeTimelineID, selection: $selection, playback: playback)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: project.id) { _, _ in
            activeTimelineID = project.rootTimelineID
            selection = nil
        }
    }
}

/// The viewer + inspector + timeline for a single timeline within a project.
/// Reused by both the main window and the external display's independent mode.
struct TimelineEditorSurface: View {
    @Binding var project: EditingProject
    @Binding var timelineID: UUID
    @Binding var selection: TimelineSelection?
    let playback: PlaybackModel

    @State private var playheadTime: CMTime = .zero
    @State private var buildTask: Task<Void, Never>?
    @State private var timelineHeight: CGFloat = 280

    private let minTimelineHeight: CGFloat = 140
    private let minTopAreaHeight: CGFloat = 220

    private var timeline: Timeline? {
        project.timeline(id: timelineID)
    }

    private var selectedTimelineClip: TimelineClip? {
        guard let selection, selection.timelineID == timelineID, let timeline,
              let layer = timeline.layer(id: selection.layerID)
        else {
            return nil
        }
        return layer.clips.first { $0.id == selection.timelineClipID }
    }

    private var selectedInfo: ResolvedClipInfo? {
        guard let selectedTimelineClip else { return nil }
        return project.resolvedInfo(for: selectedTimelineClip.source)
    }

    var body: some View {
        GeometryReader { geometry in
            let maxTimelineHeight = max(minTimelineHeight, geometry.size.height - minTopAreaHeight)
            let resolvedTimelineHeight = min(max(timelineHeight, minTimelineHeight), maxTimelineHeight)

            VStack(spacing: 0) {
                TimelineHeaderBar(project: $project, timelineID: $timelineID)
                Divider()

                HStack(spacing: 0) {
                    ViewerPanel(playback: playback, hasContent: !(timeline?.layers.isEmpty ?? true))
                    InspectorPanel(
                        project: $project,
                        timelineID: timelineID,
                        selection: selection,
                        info: selectedInfo,
                        timelineClip: selectedTimelineClip
                    )
                    .frame(width: 280)
                }
                .frame(maxHeight: .infinity)

                TimelineResizeHandle(height: $timelineHeight, minHeight: minTimelineHeight, maxHeight: maxTimelineHeight)

                if let timeline {
                    TimelineView(
                        project: project,
                        timeline: timeline,
                        timelineID: timelineID,
                        selection: selection,
                        playheadTime: $playheadTime,
                        onScrub: { time in scrub(to: time) },
                        onSelectClip: { layerID, clip in
                            selection = TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clip.id)
                        },
                        onRenameLayer: { layerID, name in project.renameLayer(layerID, in: timelineID, to: name) },
                        onMoveClip: { layerID, clipID, newStart in
                            project.moveClip(clipID, in: timelineID, layer: layerID, to: newStart)
                        },
                        onTrimClipStart: { layerID, clipID, newTrimStart in
                            project.trimClipStart(clipID, in: timelineID, layer: layerID, to: newTrimStart)
                        },
                        onTrimClipEnd: { layerID, clipID, newTrimEnd in
                            project.trimClipEnd(clipID, in: timelineID, layer: layerID, to: newTrimEnd)
                        }
                    )
                    .frame(height: resolvedTimelineHeight)
                } else {
                    ContentUnavailableView("No Timeline Selected", systemImage: "timeline.selection")
                        .frame(height: resolvedTimelineHeight)
                }
            }
        }
        .onChange(of: timelineID) { _, newValue in
            if selection?.timelineID != newValue {
                selection = nil
            }
            playheadTime = .zero
            rebuildPlayerItem()
        }
        .onChange(of: timeline) { _, _ in
            rebuildPlayerItem()
        }
        .onAppear {
            rebuildPlayerItem()
        }
    }

    // MARK: -

    /// Scrubbing moves the shared playhead and seeks the player directly —
    /// the player always shows the whole composited timeline (every layer
    /// stacked together), not just one selected clip, so no per-clip time
    /// translation is needed here.
    private func scrub(to time: CMTime) {
        playheadTime = time
        let player = playback.player
        Task { _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    private func rebuildPlayerItem() {
        buildTask?.cancel()
        guard let timeline, !timeline.layers.isEmpty else {
            playback.player.replaceCurrentItem(with: nil)
            return
        }
        let project = self.project
        let tID = timelineID
        let player = playback.player
        let time = playheadTime
        buildTask = Task {
            guard let composed = try? await CompositionExporter.buildComposedTimeline(for: project, timelineID: tID) else {
                return
            }
            guard !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: composed.composition)
            item.videoComposition = composed.videoComposition
            player.replaceCurrentItem(with: item)
            _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }
}

/// A draggable divider that lets the timeline's height be resized relative
/// to the viewer/inspector area above it — previously fixed, splitting the
/// window roughly in half regardless of how much space the timeline needed.
private struct TimelineResizeHandle: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        ZStack {
            Divider()
            Color.clear
        }
        .frame(height: 7)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
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

private struct TimelineHeaderBar: View {
    @Binding var project: EditingProject
    @Binding var timelineID: UUID
    @State private var showingSettings = false
    @State private var showingNew = false

    private var currentTimeline: Timeline? {
        project.timeline(id: timelineID)
    }

    var body: some View {
        HStack {
            Menu(currentTimeline?.name ?? "Timeline") {
                ForEach(project.timelines) { timeline in
                    Button(timeline.name) { timelineID = timeline.id }
                }
            }
            .frame(width: 160)
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Timeline settings")
            .disabled(currentTimeline == nil)
            Button {
                showingNew = true
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .help("New timeline")

            Spacer()
            if let currentTimeline {
                Text(currentTimeline.timebaseSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .sheet(isPresented: $showingSettings) {
            TimelineSettingsSheet(mode: .edit(timelineID), project: $project, isPresented: $showingSettings)
        }
        .sheet(isPresented: $showingNew) {
            TimelineSettingsSheet(mode: .create, project: $project, isPresented: $showingNew) { newID in
                timelineID = newID
            }
        }
    }
}

private struct TimelineSettingsSheet: View {
    enum Mode {
        case create
        case edit(UUID)
    }

    let mode: Mode
    @Binding var project: EditingProject
    @Binding var isPresented: Bool
    var onCreate: ((UUID) -> Void)?

    @State private var name: String = "New Timeline"
    @State private var widthText: String = "1920"
    @State private var heightText: String = "1080"
    @State private var frameRateText: String = "24"
    @State private var colorSpace: ProjectColorSpace = .rec709

    var body: some View {
        Form {
            TextField("Name", text: $name)
            HStack {
                TextField("Width", text: $widthText)
                Text("×")
                TextField("Height", text: $heightText)
            }
            TextField("Frame rate", text: $frameRateText)
            Picker("Color space", selection: $colorSpace) {
                ForEach(ProjectColorSpace.allCases) { space in
                    Text(space.rawValue).tag(space)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button(saveTitle) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { loadInitialValues() }
    }

    // TextField(value:format:) only commits on blur, not per keystroke, so a
    // user filling the form top-to-bottom and clicking Create without
    // tabbing out of the last field would lose that field's edit. Plain
    // string fields parsed at save time commit immediately like Name does.
    private var isValid: Bool {
        Double(widthText) != nil && Double(heightText) != nil && Double(frameRateText) != nil
    }

    private var saveTitle: String {
        switch mode {
        case .create: "Create"
        case .edit: "Save"
        }
    }

    private func loadInitialValues() {
        guard case .edit(let id) = mode, let timeline = project.timeline(id: id) else { return }
        name = timeline.name
        widthText = String(Int(timeline.frameSize.width))
        heightText = String(Int(timeline.frameSize.height))
        frameRateText = String(format: "%g", timeline.frameRate)
        colorSpace = timeline.colorSpace
    }

    private func save() {
        guard let width = Double(widthText), let height = Double(heightText), let frameRate = Double(frameRateText) else { return }
        switch mode {
        case .create:
            let newID = project.addTimeline(
                name: name,
                frameSize: CGSize(width: width, height: height),
                frameRate: frameRate,
                colorSpace: colorSpace
            )
            onCreate?(newID)
        case .edit(let id):
            project.updateTimelineSettings(
                id,
                name: name,
                frameSize: CGSize(width: width, height: height),
                frameRate: frameRate,
                colorSpace: colorSpace
            )
        }
        isPresented = false
    }
}

private struct LibrarySidebar: View {
    @Binding var project: EditingProject
    @Binding var activeTimelineID: UUID
    @Binding var selection: TimelineSelection?
    @State private var importError: String?

    var body: some View {
        List {
            Section("Clips") {
                ForEach(project.clips) { clip in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(clip.name)
                            Text(clip.kind.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: clip.kind.systemImage)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Section("Timelines") {
                ForEach(project.timelines) { timeline in
                    if timeline.id != activeTimelineID {
                        Button {
                            embed(timeline)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(timeline.name)
                                    Text(timeline.timebaseSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "rectangle.stack")
                                    .foregroundStyle(.purple)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!project.canEmbed(timeline.id, into: activeTimelineID))
                        .help("Embed into the active timeline")
                    }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button(action: importMedia) {
                    Image(systemName: "plus")
                }
                .help("Import media")
            }
        }
        .alert(
            "Import Failed",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func embed(_ timeline: Timeline) {
        if let result = project.embedTimeline(timeline.id, intoTimeline: activeTimelineID) {
            selection = TimelineSelection(timelineID: activeTimelineID, layerID: result.layerID, timelineClipID: result.clipID)
        }
    }

    private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls

        Task {
            for url in urls {
                do {
                    let clip = try await MediaImporter.importClip(at: url)
                    if let result = project.importClip(clip, intoTimeline: activeTimelineID) {
                        if selection == nil {
                            selection = TimelineSelection(timelineID: activeTimelineID, layerID: result.layerID, timelineClipID: result.clipID)
                        }
                    }
                } catch {
                    importError = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }
}

private struct EditorToolbar: View {
    @Binding var project: EditingProject
    @Binding var activeTimelineID: UUID
    @Binding var selection: TimelineSelection?
    let playback: PlaybackModel
    let annotations: AnnotationModel
    let externalDisplay: ExternalDisplayController
    @State private var selectedPreset: ProResPreset = .proRes422
    @State private var isExporting = false
    @State private var exportError: String?

    private var externalScreens: [NSScreen] {
        NSScreen.screens
    }

    var body: some View {
        HStack {
            Text(project.name)
                .font(.headline)
            Spacer()
            Menu(externalDisplay.isActive ? "On External Display" : "External Display") {
                ForEach(externalScreens.indices, id: \.self) { index in
                    let screen = externalScreens[index]
                    Button(screen.localizedName) {
                        externalDisplay.start(
                            on: screen,
                            project: $project,
                            primaryTimelineID: $activeTimelineID,
                            primarySelection: $selection,
                            sharedPlayback: playback,
                            annotations: annotations
                        )
                    }
                }
                if externalDisplay.isActive {
                    Divider()
                    Button("Stop External Display") {
                        externalDisplay.stop()
                    }
                }
            }
            .disabled(externalScreens.isEmpty && !externalDisplay.isActive)
            .frame(width: 170)
            Picker("ProRes preset", selection: $selectedPreset) {
                ForEach(ProResPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
            Button(isExporting ? "Exporting…" : "Export") {
                exportProject()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isExporting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .alert(
            "Export Failed",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func exportProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = project.name
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = project
        let timelineID = activeTimelineID
        let preset = selectedPreset
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                try await CompositionExporter.export(project: snapshot, timelineID: timelineID, preset: preset, to: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

private struct ViewerPanel: View {
    let playback: PlaybackModel
    let hasContent: Bool

    // Deliberately darker than the surrounding window chrome and distinct
    // from pure black, so the composition's actual frame boundary stays
    // visible even when the video content itself is black.
    private let backdropColor = Color(white: 0.06)

    var body: some View {
        ZStack {
            backdropColor
            if hasContent {
                PlayerLayerView(player: playback.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .padding(36)
            } else {
                MetalPreviewView()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .padding(36)
                ContentUnavailableView("No Clips", systemImage: "film")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorPanel: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    var selection: TimelineSelection?
    let info: ResolvedClipInfo?
    let timelineClip: TimelineClip?

    private var maxDurationSeconds: Double? {
        switch info {
        case .media(let clip): clip.duration.seconds
        case .timeline(let timeline): timeline.duration.seconds
        case nil: nil
        }
    }

    var body: some View {
        Form {
            Section("Inspector") {
                switch info {
                case .media(let clip):
                    LabeledContent("Name", value: clip.name)
                    LabeledContent("Source duration", value: clip.duration.formatted)
                    if clip.frameRate > 0 {
                        LabeledContent("Frame rate", value: String(format: "%.2f fps", clip.frameRate))
                    }
                    LabeledContent("Codec", value: clip.codecName)
                    LabeledContent("Color", value: clip.colorSpace.rawValue)
                case .timeline(let timeline):
                    LabeledContent("Name", value: timeline.name)
                    LabeledContent("Duration", value: timeline.duration.formatted)
                    LabeledContent("Frame size", value: "\(Int(timeline.frameSize.width))×\(Int(timeline.frameSize.height))")
                    LabeledContent("Frame rate", value: String(format: "%.2f fps", timeline.frameRate))
                    LabeledContent("Color", value: timeline.colorSpace.rawValue)
                case nil:
                    Text("Select a clip to inspect it.")
                        .foregroundStyle(.secondary)
                }
            }

            if let selection, let timelineClip, let maxDurationSeconds {
                Section("Trim") {
                    Stepper(
                        "In: \(timelineClip.trimStart.formatted)",
                        value: Binding(
                            get: { timelineClip.trimStart.seconds },
                            set: { setTrimStart($0, selection: selection) }
                        ),
                        in: 0...max(0, timelineClip.trimEnd.seconds - 0.1),
                        step: 0.5
                    )
                    Stepper(
                        "Out: \(timelineClip.trimEnd.formatted)",
                        value: Binding(
                            get: { timelineClip.trimEnd.seconds },
                            set: { setTrimEnd($0, selection: selection) }
                        ),
                        // Clamp below maxDurationSeconds: a very short (or
                        // zero-duration, e.g. an embedded empty timeline)
                        // clip would otherwise make trimStart + 0.1 exceed
                        // maxDurationSeconds, producing an invalid range and
                        // crashing ("lowerBound <= upperBound").
                        in: min(maxDurationSeconds, timelineClip.trimStart.seconds + 0.1)...maxDurationSeconds,
                        step: 0.5
                    )
                }

                Section("Arrange") {
                    Button("Split at Midpoint") {
                        let half = CMTimeMultiplyByRatio(timelineClip.trimmedDuration, multiplier: 1, divisor: 2)
                        let midpoint = CMTimeAdd(timelineClip.trimStart, half)
                        project.split(selection.timelineClipID, in: timelineID, layer: selection.layerID, at: midpoint)
                    }
                }
            }

            Section("Non-destructive controls") {
                // Auto-matte is temporarily disabled pending a working
                // live-preview capture pipeline — see AutoMattePreviewView.swift.
                Toggle("Auto matte (disabled)", isOn: .constant(false)).disabled(true)
                Toggle("Vector source", isOn: .constant(false))
                Button("Add text effect") {}
            }
        }
        .formStyle(.grouped)
        .disabled(info == nil)
    }

    private func setTrimStart(_ seconds: Double, selection: TimelineSelection) {
        update(selection: selection) { clip in
            clip.trimStart = CMTime(seconds: seconds, preferredTimescale: 600)
        }
    }

    private func setTrimEnd(_ seconds: Double, selection: TimelineSelection) {
        update(selection: selection) { clip in
            clip.trimEnd = CMTime(seconds: seconds, preferredTimescale: 600)
        }
    }

    private func update(selection: TimelineSelection, _ mutate: (inout TimelineClip) -> Void) {
        guard let timelineIndex = project.timelines.firstIndex(where: { $0.id == timelineID }),
              let layerIndex = project.timelines[timelineIndex].layers.firstIndex(where: { $0.id == selection.layerID }),
              let clipIndex = project.timelines[timelineIndex].layers[layerIndex].clips.firstIndex(where: { $0.id == selection.timelineClipID })
        else {
            return
        }
        mutate(&project.timelines[timelineIndex].layers[layerIndex].clips[clipIndex])
    }
}

// MARK: - Timeline

private struct TimelineView: View {
    let project: EditingProject
    let timeline: Timeline
    let timelineID: UUID
    let selection: TimelineSelection?
    @Binding var playheadTime: CMTime
    let onScrub: (CMTime) -> Void
    let onSelectClip: (UUID, TimelineClip) -> Void
    let onRenameLayer: (UUID, String?) -> Void
    let onMoveClip: (UUID, UUID, CMTime) -> Void
    let onTrimClipStart: (UUID, UUID, CMTime) -> Void
    let onTrimClipEnd: (UUID, UUID, CMTime) -> Void

    @State private var zoomScale: CGFloat = 1
    @State private var layerHeight: CGFloat = 56
    @State private var showingViewOptions = false
    @GestureState private var magnifyBy: CGFloat = 1

    private let rulerHeight: CGFloat = 26
    private let columnHeaderHeight: CGFloat = 20
    private let labelColumnWidth: CGFloat = 150

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
                    ViewOptionsPopover(zoomScale: $zoomScale, layerHeight: $layerHeight)
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
                let contentHeight = rulerHeight + columnHeaderHeight + CGFloat(timeline.layers.count) * layerHeight

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
                                    onRename: { name in onRenameLayer(layer.id, name) }
                                )
                                Divider()
                            }
                        }
                        .frame(width: labelColumnWidth, alignment: .leading)

                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 0) {
                                TimelineRuler(duration: timeline.duration, frameRate: timeline.frameRate, pixelsPerSecond: pixelsPerSecond)
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
                                        Divider()
                                    }
                                }
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
            }
        }
        .padding(.vertical, 12)
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

/// A sub-header beneath the ruler labeling the per-layer columns — currently
/// just number/name, but reserved as the home for upcoming per-layer option
/// controls (visibility, lock, etc.).
private struct TimelineColumnHeaderRow: View {
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
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

private struct ViewOptionsPopover: View {
    @Binding var zoomScale: CGFloat
    @Binding var layerHeight: CGFloat

    var body: some View {
        Form {
            Section("Horizontal Zoom") {
                Slider(value: $zoomScale, in: 1...30)
                Button("Fit to Window") { zoomScale = 1 }
            }
            Section("Layer Height") {
                Slider(value: $layerHeight, in: 32...120)
            }
        }
        .padding()
        .frame(width: 260)
    }
}

private struct TimelineRuler: View {
    let duration: CMTime
    let frameRate: Double
    let pixelsPerSecond: CGFloat

    // Needs real room for "NNf" text (~20pt), not just a tick mark —
    // 6pt was wide enough for a bare mark but produced an illegible smear
    // of overlapping frame-number labels once actually rendered.
    private var showsFrameTicks: Bool {
        pixelsPerSecond / max(frameRate, 1) >= 20
    }

    var body: some View {
        let totalSeconds = max(duration.seconds, 1.0 / max(frameRate, 1))
        Canvas { context, _ in
            if showsFrameTicks {
                drawFrameTicks(context: context, totalSeconds: totalSeconds)
            } else {
                drawSecondTicks(context: context, totalSeconds: totalSeconds)
            }
        }
        .frame(width: max(1, CGFloat(totalSeconds) * pixelsPerSecond), alignment: .leading)
    }

    private func drawFrameTicks(context: GraphicsContext, totalSeconds: Double) {
        let framesPerSecond = max(1, Int(frameRate.rounded()))
        let totalFrames = Int((totalSeconds * frameRate).rounded(.up))
        for frame in 0...max(totalFrames, 1) {
            let seconds = Double(frame) / frameRate
            let x = CGFloat(seconds) * pixelsPerSecond
            let isSecondBoundary = frame % framesPerSecond == 0
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: isSecondBoundary ? 11 : 5))
            context.stroke(path, with: .color(.secondary.opacity(isSecondBoundary ? 0.8 : 0.4)), lineWidth: 1)

            if isSecondBoundary {
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                context.draw(
                    Text(time.compactTimecode(frameRate: frameRate)).font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: x + 2, y: 19),
                    anchor: .leading
                )
            } else {
                context.draw(
                    Text("\(frame % framesPerSecond)f").font(.system(size: 8)).foregroundStyle(.secondary),
                    at: CGPoint(x: x + 1, y: 18),
                    anchor: .leading
                )
            }
        }
    }

    private func drawSecondTicks(context: GraphicsContext, totalSeconds: Double) {
        let interval = tickInterval(pixelsPerSecond: pixelsPerSecond)
        let tickCount = Int(totalSeconds / interval) + 1
        for index in 0...tickCount {
            let seconds = Double(index) * interval
            let x = CGFloat(seconds) * pixelsPerSecond
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: 8))
            context.stroke(path, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            context.draw(
                Text(time.compactTimecode(frameRate: frameRate)).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: x + 2, y: 19),
                anchor: .leading
            )
        }
    }

    // Picks the smallest "nice" interval wide enough to fit a full
    // hh:mm:ss:ff label without overlapping its neighbor — depends on the
    // current zoom (pixelsPerSecond), not just total duration, so ticks
    // stay legible at any zoom level rather than just for long timelines.
    private func tickInterval(pixelsPerSecond: CGFloat) -> Double {
        let minimumLabelWidth: CGFloat = 76
        let minimumIntervalSeconds = Double(minimumLabelWidth / max(pixelsPerSecond, 0.01))
        let niceIntervals: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        return niceIntervals.first(where: { $0 >= minimumIntervalSeconds }) ?? 3600
    }
}

private struct PlayheadLine: View {
    let time: CMTime
    let pixelsPerSecond: CGFloat
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.red)
            .frame(width: 1.5, height: height)
            .offset(x: CGFloat(time.seconds) * pixelsPerSecond)
            .allowsHitTesting(false)
    }
}

private struct LayerHeaderRow: View {
    let number: Int
    let layer: TimelineLayer
    let project: EditingProject
    let height: CGFloat
    let onRename: (String?) -> Void

    @State private var isEditingName = false
    @State private var draftName: String = ""
    @FocusState private var isNameFieldFocused: Bool

    private var displayName: String {
        if let customName = layer.customName, !customName.isEmpty { return customName }
        if let firstClip = layer.clips.first, let info = project.resolvedInfo(for: firstClip.source) { return info.name }
        return "Layer \(number)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            if isEditingName {
                TextField("Name", text: $draftName)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .focused($isNameFieldFocused)
                    .onSubmit { commitRename() }
                    .onAppear { isNameFieldFocused = true }
                    // onSubmit only fires on Return — clicking away to end
                    // editing without pressing Return previously left the
                    // field stuck open and never fell back to the footage
                    // name when left blank. Committing on focus-loss too
                    // fixes that.
                    .onChange(of: isNameFieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        draftName = layer.customName ?? ""
                        isEditingName = true
                    }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height, alignment: .leading)
    }

    private func commitRename() {
        guard isEditingName else { return }
        onRename(draftName.isEmpty ? nil : draftName)
        isEditingName = false
    }
}

private struct LayerClipRow: View {
    let layer: TimelineLayer
    let project: EditingProject
    let selection: TimelineSelection?
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    let onSelectClip: (TimelineClip) -> Void
    let onMoveClip: (UUID, CMTime) -> Void
    let onTrimClipStart: (UUID, CMTime) -> Void
    let onTrimClipEnd: (UUID, CMTime) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layer.clips) { clip in
                let isSelected = selection?.layerID == layer.id && selection?.timelineClipID == clip.id
                ClipBlockView(
                    clip: clip,
                    info: project.resolvedInfo(for: clip.source),
                    isSelected: isSelected,
                    pixelsPerSecond: pixelsPerSecond,
                    height: height,
                    onSelect: { onSelectClip(clip) },
                    onMove: { newStart in onMoveClip(clip.id, newStart) },
                    onTrimStart: { newTrimStart in onTrimClipStart(clip.id, newTrimStart) },
                    onTrimEnd: { newTrimEnd in onTrimClipEnd(clip.id, newTrimEnd) }
                )
            }
        }
        // offset() shifts rendering without changing the size a view reports
        // to its parent, so without an explicit width here the row would
        // size itself to its (un-offset) widest clip rather than spanning
        // the full timeline — leaving every clip's absolute x-position
        // anchored to the wrong origin instead of true timeline time 0.
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// Colors a clip by its layer type, After Effects/Premiere-style — video is
/// purple, audio gets its own color, nested timelines (compound clips) get
/// another. Image and text layers aren't modeled yet, but will slot into
/// this same switch (green/orange per the design) once they exist.
private func clipTypeColor(for info: ResolvedClipInfo?) -> Color {
    switch info {
    case .media(let mediaClip):
        switch mediaClip.kind {
        case .video: .purple
        case .audio: .teal
        }
    case .timeline:
        .indigo
    case nil:
        .gray
    }
}

/// A single clip block, positioned by absolute offset (not sequential flow)
/// so a clip's on-screen position always matches its `startOffset`.
/// Draggable in its middle to move it in time, and draggable at either edge
/// to non-destructively trim `trimStart`/`trimEnd` — while trimming, a
/// translucent, outlined ghost in the layer's type color shows the full
/// before/after extent so the trimmed-away sliver stays visible until
/// release.
private struct ClipBlockView: View {
    let clip: TimelineClip
    let info: ResolvedClipInfo?
    let isSelected: Bool
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let onSelect: () -> Void
    let onMove: (CMTime) -> Void
    let onTrimStart: (CMTime) -> Void
    let onTrimEnd: (CMTime) -> Void

    @GestureState private var moveTranslation: CGFloat = 0
    @GestureState private var leftTrimTranslation: CGFloat = 0
    @GestureState private var rightTrimTranslation: CGFloat = 0

    private let handleWidth: CGFloat = 8

    private var typeColor: Color { clipTypeColor(for: info) }

    var body: some View {
        let baseX = clip.startOffset.seconds * pixelsPerSecond
        let baseWidth = max(2, clip.trimmedDuration.seconds * pixelsPerSecond)
        let liveX = baseX + moveTranslation + leftTrimTranslation
        let liveWidth = max(4, baseWidth - leftTrimTranslation + rightTrimTranslation)
        let isTrimming = leftTrimTranslation != 0 || rightTrimTranslation != 0
        let unionMinX = min(baseX, liveX)
        let unionMaxX = max(baseX + baseWidth, liveX + liveWidth)

        ZStack(alignment: .topLeading) {
            if isTrimming {
                Rectangle()
                    .fill(typeColor.opacity(0.25))
                    .overlay(Rectangle().strokeBorder(typeColor, lineWidth: 1))
                    .frame(width: max(2, unionMaxX - unionMinX), height: height)
                    .offset(x: unionMinX)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if case .timeline = clip.source {
                        Image(systemName: "rectangle.stack")
                            .font(.caption2)
                    }
                    Text(info?.name ?? "Unknown")
                        .font(.caption)
                        .lineLimit(1)
                }
                Text(clip.trimmedDuration.formatted)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .frame(width: liveWidth, height: height, alignment: .leading)
            .background(typeColor.opacity(isSelected ? 0.6 : 0.35))
            .overlay(Rectangle().strokeBorder(isSelected ? Color.white.opacity(0.9) : typeColor.opacity(0.8), lineWidth: isSelected ? 1.5 : 0.75))
            .offset(x: liveX)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($moveTranslation) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        if distance < 3 {
                            onSelect()
                        } else {
                            let deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                            let newStart = CMTimeAdd(clip.startOffset, CMTime(seconds: deltaSeconds, preferredTimescale: 600))
                            onMove(newStart)
                        }
                    }
            )

            // Edge handles are layered on top so grabbing within a few
            // points of either side trims that edge instead of moving the
            // whole clip (SwiftUI resolves overlapping gestures to the
            // topmost hit-testable view at the touch point).
            trimHandle(edge: .leading, liveX: liveX, liveWidth: liveWidth)
            trimHandle(edge: .trailing, liveX: liveX, liveWidth: liveWidth)
        }
        .frame(height: height, alignment: .topLeading)
    }

    private enum Edge { case leading, trailing }

    private func trimHandle(edge: Edge, liveX: CGFloat, liveWidth: CGFloat) -> some View {
        let handleX = edge == .leading ? liveX - handleWidth / 2 : liveX + liveWidth - handleWidth / 2
        return Rectangle()
            .fill(Color.clear)
            .frame(width: handleWidth, height: height)
            .contentShape(Rectangle())
            .offset(x: handleX)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating(edge == .leading ? $leftTrimTranslation : $rightTrimTranslation) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        if distance < 3 {
                            onSelect()
                            return
                        }
                        let deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                        let delta = CMTime(seconds: deltaSeconds, preferredTimescale: 600)
                        switch edge {
                        case .leading:
                            onTrimStart(CMTimeAdd(clip.trimStart, delta))
                        case .trailing:
                            onTrimEnd(CMTimeAdd(clip.trimEnd, delta))
                        }
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
