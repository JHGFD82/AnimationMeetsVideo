import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibrarySidebar: View {
    @Binding var project: EditingProject
    @Binding var activeTimelineID: UUID
    @Binding var selection: TimelineSelection?
    let analysis: AssetAnalysis
    let replacement: MediaReplacementController
    let packageURL: URL?
    @State private var importError: String?
    @State private var selectedScenes: Set<SceneKey> = []
    @State private var expandedAssets: Set<UUID> = []
    @State private var sensitivityTarget: SensitivityTarget?
    @State private var previewTarget: ScenePreviewTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library")
                    .font(Design.Typeface.panelTitle)
                    .foregroundStyle(Design.textPrimary)
                Spacer()
                Button(action: importMedia) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Import media")
            }
            .padding(.horizontal, Design.Space.group)
            .padding(.vertical, Design.Space.step)
            .rail(.raised)
            list
        }
        .panelSurface(.base)
        .alert(
            "Import Failed",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var list: some View {
        List(selection: $selectedScenes) {
            Section("Clips") {
                ForEach(project.clips) { clip in
                    if clip.kind == .video {
                        videoRow(clip)
                    } else {
                        assetLabel(clip)
                            .draggable(wholeAssetPayload(clip))
                            .contextMenu {
                                Button("Add to Timeline") { place(clip) }
                                Divider()
                                ReplaceMediaMenuItems(
                                    clip: clip, project: $project, analysis: analysis,
                                    controller: replacement, packageURL: packageURL
                                )
                            }
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
                        .help("Embed into the active timeline")
                    }
                }
            }
        }
        .contextMenu(forSelectionType: SceneKey.self) { keys in
            sceneMenu(for: keys)
        } primaryAction: { keys in
            addToTimeline(keys)
        }
        .sheet(item: $sensitivityTarget) { target in
            SensitivitySheet(project: $project, target: target, track: analysis.tracks[target.assetID])
        }
        .sheet(item: $previewTarget) { target in
            ScenePreviewSheet(project: $project, target: target, track: analysis.tracks[target.assetID])
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .sunken(.sunken)
    }

    private func assetLabel(_ clip: MediaClip) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.name)
                assetStatus(clip)
            }
        } icon: {
            // The same hue the clip takes on the timeline, so what you drag
            // and what lands there are recognisably the same thing.
            Image(systemName: clip.kind.systemImage)
                .foregroundStyle(Design.ClipTone.of(.media(clip), streams: .videoAndAudio).color)
        }
    }

    /// "120 BPM", or "92–140 BPM" when the tempo changes noticeably.
    static func tempoText(_ beats: BeatTrack) -> String {
        if let range = beats.tempoRange, range.upperBound / range.lowerBound > 1.04 {
            return "\(Int(range.lowerBound.rounded()))–\(Int(range.upperBound.rounded())) BPM"
        }
        return "\(Int(beats.beatsPerMinute.rounded())) BPM"
    }

    @ViewBuilder
    private func assetStatus(_ clip: MediaClip) -> some View {
        if let fraction = analysis.progress[clip.id] {
            HStack(spacing: Design.Space.close) {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(width: 60)
                Text(analysis.stages[clip.id]?.label ?? "Waiting…")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textTertiary)
            }
        } else if replacement.missingMedia.contains(clip.id) {
            Text("File missing")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help("Its clips play as gaps until the file is back. Control-click to replace it.")
        } else if let failure = analysis.failures[clip.id] {
            Text("Scene detection failed")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help(failure)
        } else if let failure = analysis.beatFailures[clip.id] {
            Text("Beat detection failed")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help(failure)
        } else if let beats = analysis.beats[clip.id], !beats.isEmpty {
            HStack(spacing: Design.Space.tight) {
                Text(clip.kind.rawValue)
                    .font(Design.Typeface.label)
                Text(Self.tempoText(beats))
                    .font(Design.Typeface.numericMicro)
            }
            .foregroundStyle(Design.textTertiary)
        } else {
            Text(clip.kind.rawValue)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
        }
    }

    private func videoRow(_ clip: MediaClip) -> some View {
        let isExpanded = Binding(
            get: { expandedAssets.contains(clip.id) },
            set: { if $0 { expandedAssets.insert(clip.id) } else { expandedAssets.remove(clip.id) } }
        )
        return DisclosureGroup(isExpanded: isExpanded) {
            let scenes = project.scenes(ofAsset: clip.id, track: analysis.tracks[clip.id])
            ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                let key = SceneKey(assetID: clip.id, sceneID: scene.id)
                SceneRowView(clip: clip, scene: scene, number: index + 1)
                    .tag(key)
                    .draggable(dragPayload(for: key))
            }
        } label: {
            assetLabel(clip)
                .draggable(wholeAssetPayload(clip))
                .contextMenu {
                    Button("Add to Timeline") { place(clip) }
                    Divider()
                    Button("Cut Sensitivity…") {
                        sensitivityTarget = SensitivityTarget(assetID: clip.id, scope: .asset)
                    }
                    .disabled(analysis.tracks[clip.id] == nil)
                    Button("Find Scenes Again") {
                        analysis.reanalyze(clip, in: project)
                    }
                    .disabled(analysis.progress[clip.id] != nil)
                    Divider()
                    ReplaceMediaMenuItems(
                        clip: clip, project: $project, analysis: analysis,
                        controller: replacement, packageURL: packageURL
                    )
                }
        }
    }

    private struct PickedScenes {
        struct Item {
            var number: Int
            var scene: SceneRange
        }

        var clip: MediaClip
        var items: [Item]
        var scenes: [SceneRange] { items.map(\.scene) }
    }

    /// Scenes picked in the browser, grouped by asset in library order, each
    /// group in source order.
    private func pickedScenes(_ keys: Set<SceneKey>) -> [PickedScenes] {
        var groups: [PickedScenes] = []
        for clip in project.clips {
            var wanted = Set<String>()
            for key in keys where key.assetID == clip.id { wanted.insert(key.sceneID) }
            if wanted.isEmpty { continue }

            let all = project.scenes(ofAsset: clip.id, track: analysis.tracks[clip.id])
            var items: [PickedScenes.Item] = []
            for (index, scene) in all.enumerated() where wanted.contains(scene.id) {
                items.append(PickedScenes.Item(number: index + 1, scene: scene))
            }
            if !items.isEmpty { groups.append(PickedScenes(clip: clip, items: items)) }
        }
        return groups
    }

    /// Dragging an asset itself carries the whole file as one scene.
    /// `.draggable` builds this as the drag begins.
    private func wholeAssetPayload(_ clip: MediaClip) -> SceneDragPayload {
        SceneDragPayload.beginDrag(assetID: clip.id, scenes: [SceneRange(start: .zero, end: clip.duration, origin: .auto)])
    }

    private func place(_ clip: MediaClip) {
        if let result = project.placeAsset(clip.id, intoTimeline: activeTimelineID) {
            selection = TimelineSelection(timelineID: activeTimelineID, layerID: result.layerID, timelineClipID: result.clipID)
        }
    }

    private func dragPayload(for key: SceneKey) -> SceneDragPayload {
        let keys = selectedScenes.contains(key) ? selectedScenes : [key]
        let group = pickedScenes(keys).first { $0.clip.id == key.assetID }
        return SceneDragPayload.beginDrag(assetID: key.assetID, scenes: group?.scenes ?? [])
    }

    @ViewBuilder
    private func sceneMenu(for keys: Set<SceneKey>) -> some View {
        let groups = pickedScenes(keys)
        if let only = groups.first, groups.count == 1 {
            Button("Add to Timeline") { addToTimeline(keys) }

            if only.items.count == 1, let one = only.items.first, let url = only.clip.url {
                Button("Preview…") {
                    previewTarget = ScenePreviewTarget(assetID: only.clip.id, url: url, scene: one.scene, number: one.number)
                }
            }

            Divider()

            if let span = only.scenes.span, analysis.tracks[only.clip.id] != nil {
                Button("Adjust Cut Sensitivity…") {
                    sensitivityTarget = SensitivityTarget(assetID: only.clip.id, scope: .span(start: span.start, end: span.end))
                }
            }
            Button(only.items.count == 1 ? "Merge with Previous Scene" : "Merge Selected Scenes") {
                mergeScenes(keys, assetID: only.clip.id)
            }
            .disabled(!canMerge(keys, assetID: only.clip.id))
        } else if !groups.isEmpty {
            Button("Add to Timeline") { addToTimeline(keys) }
        }
    }

    private func addToTimeline(_ keys: Set<SceneKey>) {
        var firstClip: (layerID: UUID, clipID: UUID)?
        for group in pickedScenes(keys) {
            if let result = project.addScenes(group.scenes, ofAsset: group.clip.id, intoTimeline: activeTimelineID),
               firstClip == nil, let clipID = result.clipIDs.first {
                firstClip = (result.layerID, clipID)
            }
        }
        if let firstClip {
            selection = TimelineSelection(timelineID: activeTimelineID, layerID: firstClip.layerID, timelineClipID: firstClip.clipID)
        }
    }

    /// The cuts whose removal joins the picked scenes: each picked scene's
    /// start, except where it begins the run (a single scene merges back into
    /// the one before it).
    private func cutsToRemove(_ keys: Set<SceneKey>, assetID: UUID) -> [SceneCut] {
        let all = project.scenes(ofAsset: assetID, track: analysis.tracks[assetID])
        let wanted = Set(keys.filter { $0.assetID == assetID }.map(\.sceneID))
        let single = wanted.count == 1
        var cuts: [SceneCut] = []
        for (index, scene) in all.enumerated() where wanted.contains(scene.id) && index > 0 {
            if single || wanted.contains(all[index - 1].id) {
                cuts.append(SceneCut(time: scene.start, origin: scene.origin))
            }
        }
        return cuts
    }

    private func canMerge(_ keys: Set<SceneKey>, assetID: UUID) -> Bool {
        !cutsToRemove(keys, assetID: assetID).isEmpty
    }

    private func mergeScenes(_ keys: Set<SceneKey>, assetID: UUID) {
        let cuts = cutsToRemove(keys, assetID: assetID)
        project.editScenes(ofAsset: assetID) { edits in
            for cut in cuts { edits.removeCut(cut) }
        }
        selectedScenes = []
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
        panel.allowedContentTypes = [.movie, .audio]
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
                            madeCopy = try await Task.detached(priority: .userInitiated) {
                                try ProjectStore.copyIntoPackage(url, packageURL: packageURL)
                            }.value
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
