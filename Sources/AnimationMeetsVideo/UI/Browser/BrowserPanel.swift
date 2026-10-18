import AppKit
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
    @Binding var project: EditingProject
    @Binding var activeTimelineID: UUID
    @Binding var selection: TimelineSelection?
    let analysis: AssetAnalysis
    let replacement: MediaReplacementController
    let packageURL: URL?
    /// What the browser shows, as the editor had it when it drew, which the
    /// comparison uses (see `==`): the bindings always read the current
    /// values.
    let shown: Shown

    struct Shown: Equatable {
        /// The project without its values (`EditingProject.structure`):
        /// the media, the timelines and what of the media they use.
        var structure: EditingProject
        var activeTimelineID: UUID
        var selection: TimelineSelection?
    }
    @State private var importError: String?
    @State private var presets = PresetsModel()
    @State private var showingSettings = false
    @AppStorage(Preferences.browserTab) private var tab = BrowserTab.clips
    @AppStorage(Preferences.thumbnailInterval) private var interval = ThumbnailInterval.all
    @AppStorage(Preferences.thumbnailSize) private var thumbnailSize = ThumbnailSize.medium

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar(tabs: BrowserTab.allCases, selection: $tab, title: \.title) {
                Button {
                    showingSettings.toggle()
                } label: {
                    Image(systemName: Design.Symbol.viewOptions)
                }
                .buttonStyle(.icon)
                .help("Thumbnail settings")
                .accessibilityLabel("Thumbnail settings")
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
                ClipsTab(
                    project: $project, activeTimelineID: activeTimelineID, selection: $selection,
                    analysis: analysis, replacement: replacement, packageURL: packageURL
                )
            case .timelines: timelinesList
            case .presets: presetsList
            }
        }
        .panelSurface(.base)
        .alert("Rename Preset", isPresented: Binding(get: { presets.renaming != nil }, set: { if !$0 { presets.renaming = nil } })) {
            @Bindable var presets = presets
            TextField("Name", text: $presets.draftName)
            Button("Rename") { presets.commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Preset Problem",
            isPresented: Binding(get: { presets.errorMessage != nil }, set: { if !$0 { presets.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(presets.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .presetsChanged)) { _ in presets.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in presets.reload() }
        .alert(
            "Import Failed",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    /// Time per thumbnail and thumbnail size, for every browser tab.
    private var settings: some View {
        VStack(alignment: .leading, spacing: Design.Space.group) {
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
        }
        .font(Design.Typeface.label)
        .padding(Design.Space.group)
        .frame(width: 260)
    }

    private var timelinesList: some View {
        List {
            ForEach(project.timelines) { timeline in
                if timeline.id != activeTimelineID {
                    Button {
                        embed(timeline)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(timeline.name)
                                Text(timeline.timebaseSummary)
                                    .font(Design.Typeface.numericMicro)
                                    .foregroundStyle(Design.textTertiary)
                            }
                        } icon: {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(Design.ClipTone.nested.color)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!project.canEmbed(timeline.id, into: activeTimelineID))
                    .help("Embed into the active timeline, or drag onto an effect that takes an input")
                    .draggable(TimelineDragPayload(timelineID: timeline.id))
                }
            }
        }
        .browserListStyle()
    }

    private var presetsList: some View {
        List {
            PresetsList(model: presets)
        }
        .browserListStyle()
    }

    private func embed(_ timeline: Timeline) {
        if let result = project.embedTimeline(timeline.id, intoTimeline: activeTimelineID) {
            selection = TimelineSelection(timelineID: activeTimelineID, layerID: result.layerID, timelineClipID: result.clipID)
        }
    }

    /// Imported files go into the library only; they reach a timeline when
    /// dragged there or added from their menu. When the project copies
    /// imports, each file is copied into its `Media/` folder first and the
    /// copy is what's imported.
    private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .image]
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
        guard let copying = filesToCopy(urls, copy: copyOption.state == .on) else { return }
        let packageURL = packageURL

        Task {
            // A file imported before (and since removed, or never saved)
            // comes back under its old ID, so its analysis is reused, and
            // its earlier copy in Media/ is used instead of copying again.
            var claimedIDs = Set(project.clips.map(\.id))
            var usedPaths = Set(project.clips.compactMap { $0.url?.standardizedFileURL.resolvingSymlinksInPath().path })
            for url in urls {
                var madeCopy: URL?
                do {
                    var source = url
                    if copying.contains(url), let packageURL {
                        if let existing = ProjectStore.existingCopy(of: url, in: packageURL, excluding: usedPaths) {
                            source = existing
                        } else {
                            madeCopy = try await PackageCoordinator.shared.run(on: [packageURL]) {
                                try ProjectStore.copyIntoPackage(url, packageURL: packageURL)
                            }
                            source = madeCopy ?? url
                        }
                    }
                    var clip = try await MediaImporter.importClip(at: source)
                    // A copy may be numbered to avoid a name already in Media/.
                    clip.name = url.deletingPathExtension().lastPathComponent
                    if let packageURL, let earlier = ProjectStore.reusableAssetID(for: source, in: packageURL, excluding: claimedIDs) {
                        clip.id = earlier
                    }
                    claimedIDs.insert(clip.id)
                    usedPaths.insert(source.standardizedFileURL.resolvingSymlinksInPath().path)
                    project.addMedia(clip)
                    tab = .clips
                } catch {
                    if let madeCopy { try? FileManager.default.removeItem(at: madeCopy) }
                    importError = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    /// Which of `urls` to copy into the package: none when this import
    /// references them in place, otherwise all, after asking about any
    /// that would use real disk space. Nil to cancel the import.
    private func filesToCopy(_ urls: [URL], copy: Bool) -> Set<URL>? {
        guard copy, let packageURL else { return [] }
        let clones = urls.filter { ProjectStore.copyIsClone(of: $0, into: packageURL) }
        let heavy = urls.filter { !clones.contains($0) }
        guard !heavy.isEmpty else { return Set(urls) }
        let total = heavy.reduce(Int64(0)) { $0 + ProjectStore.fileSize(of: $1) }
        switch MediaCopyPrompt.ask(fileCount: heavy.count, byteCount: total) {
        case .copy: return Set(urls)
        case .referenceInPlace: return Set(clones)
        case nil: return nil
        }
    }
}

private extension View {
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
