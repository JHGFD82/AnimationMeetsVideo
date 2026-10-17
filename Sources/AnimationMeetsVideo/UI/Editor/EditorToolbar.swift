import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorToolbar: View {
    @Binding var project: EditingProject
    @Binding var activeTimelineID: UUID
    @Binding var selection: TimelineSelection?
    let playback: PlaybackModel
    let annotations: AnnotationModel
    let externalDisplay: ExternalDisplayController
    let analysis: AssetAnalysis
    /// Pauses for an export, whose ProRes 422 output reuses its renders.
    let renderer: RenderScheduler
    @State private var selectedPreset: ProResPreset = .proRes422
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress: Double = 0
    @State private var exportError: String?
    @State private var showsPasteChanges = false
    /// Whether the Paste Changes list was opened by trying to export.
    @State private var exportAfterAccepting = false
    @AppStorage("showsSidePanel") private var showsSidePanel = true
    @AppStorage("sidePanelTab") private var sideTab = SidePanelTab.inspector

    /// What an export of the active timeline would be blocked by.
    private var pasteChanges: [PasteChangeEntry] { project.unresolvedPasteChanges(drawnBy: activeTimelineID) }

    private var isExporting: Bool { exportTask != nil }

    private var externalScreens: [NSScreen] {
        // Exclude the screen the editor window is on; covering it with the
        // borderless viewer window would hide the editor itself.
        let editorScreen = NSApp.windows.first { $0.isMainWindow || $0.isKeyWindow }?.screen ?? NSScreen.main
        return NSScreen.screens.filter { $0 != editorScreen }
    }

    var body: some View {
        HStack(spacing: Design.Space.group) {
            Text(project.name)
                .font(Design.Typeface.panelTitle)
                .foregroundStyle(Design.textPrimary)
            Spacer(minLength: Design.Space.group)
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
                            annotations: annotations,
                            analysis: analysis
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

            if !pasteChanges.isEmpty {
                Button {
                    exportAfterAccepting = false
                    showsPasteChanges = true
                } label: {
                    Label("\(pasteChanges.count)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Design.statusWarning)
                }
                .help("\(pasteChanges.count) pasted effect change\(pasteChanges.count == 1 ? "" : "s") to resolve before exporting")
            }

            Groove(axis: .vertical)
                .frame(height: 18)

            // The preset and the button are one thing — what you are about
            // to export, and exporting it — so they sit together with no
            // gap, away from everything else on the rail.
            HStack(spacing: Design.Space.close) {
                Picker("ProRes preset", selection: $selectedPreset) {
                    ForEach(ProResPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 130)
                .help("ProRes 422 exports reuse the stretches already rendered in the background; ProRes 4444 composites everything from the sources.")
                .disabled(isExporting)

                if isExporting {
                    ProgressView(value: exportProgress)
                        .controlSize(.small)
                        .frame(width: 90)
                    Button("Cancel") {
                        exportTask?.cancel()
                    }
                } else {
                    Button("Export") {
                        exportProject()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accentFill)
                }
            }
            .editorAnimation(Design.Motion.panel, value: isExporting)
        }
        .padding(.horizontal, Design.Space.rail)
        .padding(.vertical, Design.Space.step + 2)
        .rail(.raised)
        .sheet(isPresented: $showsPasteChanges) {
            PasteChangesSheet(
                project: $project,
                timelineID: activeTimelineID,
                isBlockingExport: exportAfterAccepting,
                onGoTo: goTo,
                onAcceptAll: acceptAll,
                onClose: { showsPasteChanges = false }
            )
        }
        .onChange(of: pasteChanges.isEmpty) { _, empty in
            if empty { showsPasteChanges = false }
        }
        .alert(
            "Export Failed",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Selects the clip an entry is on, with the effects panel open at it.
    private func goTo(_ entry: PasteChangeEntry) {
        guard let layer = project.clipAndLayer(entry.clipID, in: entry.timelineID)?.layer else { return }
        showsPasteChanges = false
        activeTimelineID = entry.timelineID
        selection = TimelineSelection(timelineID: entry.timelineID, layerID: layer.id, timelineClipID: entry.clipID)
        showsSidePanel = true
        sideTab = .effects
        let effectID = entry.effectID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            NotificationCenter.default.post(name: .revealEffect, object: effectID)
        }
    }

    /// Resolves everything in the list; when the list came up because of an
    /// export, the export goes ahead.
    private func acceptAll() {
        project.resolve(pasteChanges)
        showsPasteChanges = false
        if exportAfterAccepting {
            exportAfterAccepting = false
            exportProject(checkingPasteChanges: false)
        }
    }

    /// `checkingPasteChanges` is false right after accepting them all, when
    /// the project binding may not have caught up yet.
    private func exportProject(checkingPasteChanges: Bool = true) {
        // Pasted effects with changes nobody has looked at block the export.
        guard !checkingPasteChanges || pasteChanges.isEmpty else {
            exportAfterAccepting = true
            showsPasteChanges = true
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = project.name
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = project
        let timelineID = activeTimelineID
        let preset = selectedPreset
        let cache = renderer.cache
        exportProgress = 0
        renderer.setExporting(true)
        exportTask = Task {
            defer {
                exportTask = nil
                renderer.setExporting(false)
            }
            do {
                try await CompositionExporter.export(
                    project: snapshot,
                    timelineID: timelineID,
                    preset: preset,
                    to: url,
                    cache: cache,
                    progress: { fraction in
                        Task { @MainActor in exportProgress = fraction }
                    }
                )
            } catch is CancellationError {
                // The user cancelled; nothing to report.
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}
