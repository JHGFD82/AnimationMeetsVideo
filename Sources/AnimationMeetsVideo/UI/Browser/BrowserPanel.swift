import AppKit
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

/// What the browser lists.
enum BrowserTab: String, CaseIterable, Identifiable {
    case clips, timelines, presets

    var id: Self { self }

    var title: String {
        switch self {
        case .clips: "Clips"
        case .timelines: "Timelines"
        case .presets: "Presets"
        }
    }
}

/// The browser left of the viewer: what can go into a timeline, in tabs.
/// See docs/browser.md.
struct BrowserPanel: View {
    /// The project, read and edited through an object SwiftUI doesn't
    /// watch, so only `==` decides when the browser redraws.
    let access: ProjectAccess
    let activeTimelineID: UUID
    @Binding var selection: TimelineSelection?
    let analysis: AssetAnalysis
    let replacement: MediaReplacementController
    let packageURL: URL?
    /// Opens a timeline in the editor, from the Timelines tab (not compared
    /// in `==`; it always sets the editor's active timeline).
    var onOpenTimeline: (UUID) -> Void = { _ in }
    /// Opens a timeline in a window of its own; nil where there is none.
    var onOpenTimelineInNewWindow: ((UUID) -> Void)?
    /// What the browser shows, as the editor had it when it drew, which the
    /// comparison uses (see `==`): the bindings always read the current
    /// values.
    let shown: Shown

    private var project: EditingProject {
        get { access.value }
        nonmutating set { access.binding.wrappedValue = newValue }
    }

    struct Shown: Equatable {
        /// The project without its values (`EditingProject.structure`):
        /// the media, the timelines and what of the media they use.
        var structure: EditingProject
        var activeTimelineID: UUID
        var selection: TimelineSelection?
    }
    @State private var importError: String?
    @Environment(MediaImports.self) private var imports: MediaImports?
    @State private var presets = PresetsModel()
    @State private var showingSettings = false
    /// Footage from Show in Clips Browser, for the Clips tab to pick.
    @State private var revealing: MediaPiece?
    @AppStorage(Preferences.browserTab) private var tab = BrowserTab.clips
    @AppStorage(Preferences.browserSort) private var sort = BrowserSort.added
    @AppStorage(Preferences.timelinesLayout) private var timelinesLayout = TimelinesLayout.filmstrips
    @AppStorage(Preferences.thumbnailInterval) private var interval = ThumbnailInterval.all
    @AppStorage(Preferences.thumbnailSize) private var thumbnailSize = ThumbnailSize.medium
    @AppStorage(Preferences.browserSkimming) private var skimming = true
    @AppStorage(Preferences.browserSkimAudio) private var skimAudio = true
    @AppStorage(Preferences.browserMutesAddedSound) private var mutesAddedSound = false

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar(tabs: BrowserTab.allCases, selection: $tab, title: \.title) {
                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: Design.Symbol.viewOptions)
                }
                .buttonStyle(.icon)
                .help("View options")
                .accessibilityLabel("View options")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) { settings }
                Button(action: importMedia) {
                    Image(systemName: Design.Symbol.add)
                }
                .buttonStyle(.icon)
                .help("Import media")
                .accessibilityLabel("Import media")
            }
            switch tab {
            case .clips:
                if project.clips.isEmpty && imports?.items.isEmpty != false {
                    noMedia
                } else {
                    MediaProblemsBar(
                        controller: replacement,
                        context: .init(project: access.binding, analysis: analysis, packageURL: packageURL)
                    )
                    ClipsTab(
                        access: access, activeTimelineID: activeTimelineID, selection: $selection,
                        analysis: analysis, replacement: replacement, packageURL: packageURL,
                        revealing: $revealing, onImport: importMedia
                    )
                }
            case .timelines: timelinesList
            case .presets: presetsList
            }
        }
        .panelSurface(.base)
        .alert("Rename Preset", isPresented: $presets.renaming.isPresent) {
            @Bindable var presets = presets
            TextField("Name", text: $presets.draftName)
            Button("Rename") { presets.commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .messageAlert("Preset Problem", message: $presets.errorMessage)
        .onReceive(NotificationCenter.default.publisher(for: .presetsChanged)) { _ in presets.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .revealInBrowser)) { note in
            guard let piece = note.object as? MediaPiece, project.mediaClip(id: piece.assetID) != nil else { return }
            tab = .clips
            revealing = piece
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in presets.reload() }
        // Files from the Finder. The app's own drags are URLs too, but
        // never file URLs.
        .dropDestination(for: URL.self) { urls, _ in importDropped(urls) }
        .messageAlert("Import Failed", message: $importError)
        .focusedSceneValue(\.importMedia, FileMenuAction(run: importMedia))
    }

    /// The Clips tab of a project with no media yet: where everything
    /// starts, so it says how to begin rather than showing nothing. Files
    /// dropped on it land as on the list.
    private var noMedia: some View {
        ContentUnavailableView {
            Label("No media yet", systemImage: "film.stack")
        } description: {
            Text("Import footage and music, or drag files here from the Finder. Their scenes then show here, ready to drag onto the timeline.")
        } actions: {
            Button("Import Media…", action: importMedia)
                .buttonStyle(.borderedProminent)
                .tint(Design.accentFill)
        }
        .frame(maxHeight: .infinity)
        // A double-click anywhere on it imports too, as on the list.
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: importMedia)
    }

    /// The order, time per thumbnail and thumbnail size, for every browser tab.
    private var settings: some View {
        VStack(alignment: .leading, spacing: Design.Space.group) {
            Picker("Sort by", selection: $sort) {
                ForEach(BrowserSort.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.menu)
            .help("The order of the clips, and of the timelines when sorted by name")
            Picker("Timelines", selection: $timelinesLayout) {
                ForEach(TimelinesLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .help("Show the Timelines tab as filmstrips to skim, or as the tree of what embeds what, with names, durations and settings")
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                HStack {
                    Text("Time per thumbnail")
                    Spacer()
                    Text(interval.title)
                        .font(Design.Typeface.numericSmall)
                        .foregroundStyle(Design.textSecondary)
                }
                // The most thumbnails on the left, one per clip on the right.
                let last = Double(ThumbnailInterval.allCases.count - 1)
                Slider(
                    value: Binding(
                        get: { last - Double(interval.rawValue) },
                        set: { interval = ThumbnailInterval(rawValue: Int((last - $0).rounded())) ?? .all }
                    ),
                    in: 0...last,
                    step: 1
                ) {
                    Text("Time per thumbnail")
                } minimumValueLabel: {
                    Text("1 s")
                } maximumValueLabel: {
                    Text("All")
                }
                .labelsHidden()
                .accessibilityValue(interval.title)
            }
            Picker("Thumbnail size", selection: $thumbnailSize) {
                ForEach(ThumbnailSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                Toggle("Skimming", isOn: $skimming)
                    .help("Show the frame under the pointer in the viewer as it moves over a clip; off, click to show a frame")
                // Sound comes with skimming, so it is set under it.
                Toggle("Skim audio", isOn: $skimAudio)
                    .help("Play a moment of a clip's sound at each frame skimmed to")
                    .disabled(!skimming)
                    .padding(.leading, Design.Space.step)
            }
            Toggle("Mute added video sound", isOn: $mutesAddedSound)
                .help("Put video on the timeline with its sound muted; detaching the sound unmutes it")
        }
        .font(Design.Typeface.label)
        .padding(Design.Space.group)
        .frame(width: 260)
    }

    private var timelinesList: some View {
        TimelinesList(
            project: project, activeTimelineID: activeTimelineID,
            onOpen: onOpenTimeline,
            onEmbed: embed,
            onDuplicate: { id in project.duplicateTimeline(id) },
            onRename: { id, name in project.renameTimeline(id, to: name) },
            onOpenInNewWindow: onOpenTimelineInNewWindow,
            onDelete: { ids in project.deleteUnusedTimelines(ids) }
        )
    }

    private var presetsList: some View {
        PresetsList(model: presets, onApply: applyToSelectedClip)
    }

    /// Puts a preset's effects on the selected clip, below its stacks; a
    /// beep when no clip is selected or it has nowhere to put them.
    private func applyToSelectedClip(_ preset: EffectPreset) {
        guard let selection, !project.paste(preset.bundle, ontoClip: selection.timelineClipID, in: selection.timelineID).isEmpty else {
            NSSound.beep()
            return
        }
    }

    /// Puts timelines (or, with `range`, that stretch of the one timeline)
    /// on one new layer of the active one, back to back in the order given,
    /// as clips added together go, and selects the first clip it makes.
    /// Nothing goes in when any of them can't (`canEmbed`).
    private func embed(_ timelineIDs: [UUID], range: CMTimeRange?) {
        let pieces = timelineIDs.compactMap { id -> MediaPiece? in
            guard let timeline = project.timeline(id: id) else { return nil }
            let whole = CMTimeRange(start: .zero, duration: timeline.duration)
            let played = range.map { $0.intersection(whole) } ?? whole
            return played.duration > .zero ? .timeline(id, from: played.start, to: played.end) : nil
        }
        guard let result = project.addPieces(pieces, intoTimeline: activeTimelineID), let clipID = result.clipIDs.first else { return }
        selection = TimelineSelection(timelineID: activeTimelineID, layerID: result.layerID, timelineClipID: clipID)
    }

    /// Imported files go into the library only; they reach a timeline when
    /// dragged there or added from their menu. When the project copies
    /// imports, each file is copied into its `Media/` folder first and the
    /// copy is what's imported.
    private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImportFlow.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Starts as the project's setting, and can differ for one import.
        let copyOption = NSButton(checkboxWithTitle: "Copy into the project", target: nil, action: nil)
        copyOption.state = project.copiesMediaOnImport ? .on : .off
        copyOption.toolTip = "Off: the files stay where they are and the project refers to them there. The default is in File > Project Settings."
        if packageURL != nil {
            let accessory = NSStackView(views: [copyOption])
            accessory.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            panel.accessoryView = accessory
            panel.isAccessoryViewDisclosed = true
        }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard let copying = MediaImportFlow.filesToCopy(urls, copy: copyOption.state == .on, packageURL: packageURL) else { return }
        Task {
            let imported = await MediaImportFlow.importFiles(
                urls, copying: copying, packageURL: packageURL, project: access.binding, imports: imports,
                onError: { importError = $0 }
            )
            if !imported.isEmpty { tab = .clips }
        }
    }

    /// Files dragged in from the Finder go into the library, as Import…
    /// would bring them, copied when the project copies imports.
    private func importDropped(_ urls: [URL]) -> Bool {
        guard !MediaImportFlow.importable(urls).isEmpty else { return false }
        Task {
            if await MediaImportFlow.importDropped(
                urls, packageURL: packageURL, project: access.binding, imports: imports, onError: { importError = $0 }
            ) != nil {
                tab = .clips
            }
        }
        return true
    }
}

extension View {
    /// A list in a browser tab: the sidebar's rows over the sunken well.
    func browserListStyle() -> some View {
        listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .sunken(.sunken)
    }
}

extension BrowserPanel: Equatable {
    /// Whether the browser would draw the same, so it needn't be redrawn
    /// (the editor marks it `.equatable()`). It shows nothing an effect's
    /// values decide, so dragging one doesn't redraw it. The analysis and
    /// replacement it shows are observed on their own.
    nonisolated static func == (lhs: BrowserPanel, rhs: BrowserPanel) -> Bool {
        MainActor.assumeIsolated { lhs.shown == rhs.shown && lhs.packageURL == rhs.packageURL }
    }
}
