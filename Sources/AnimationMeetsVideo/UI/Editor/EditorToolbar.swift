import AppKit
import SwiftUI

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
    /// Where the format and sound are picked and the export runs.
    let exportWindow: ExportWindow
    @Environment(ProjectState.self) private var projectState: ProjectState?
    @State private var showsPasteChanges = false
    /// Whether the Paste Changes list was opened by trying to export.
    @State private var exportAfterAccepting = false
    @AppStorage(Preferences.showsSidePanel) private var showsSidePanel = true
    @AppStorage(Preferences.sidePanelTab) private var sideTab = SidePanelTab.inspector

    /// What an export of the active timeline would be blocked by.
    private var pasteChanges: [PasteChangeEntry] { project.unresolvedPasteChanges(drawnBy: activeTimelineID) }

    private var externalScreens: [NSScreen] {
        // Exclude the screen the editor window is on; covering it with the
        // borderless viewer window would hide the editor itself.
        let editorScreen = NSApp.windows.first { $0.isMainWindow || $0.isKeyWindow }?.screen ?? NSScreen.main
        return NSScreen.screens.filter { $0 != editorScreen }
    }

    var body: some View {
        // Once a redraw: it looks through the app's windows.
        let externalScreens = externalScreens
        return HStack(spacing: Design.Space.group) {
            Text(project.name)
                .font(Design.Typeface.panelTitle)
                .foregroundStyle(Design.textPrimary)
            Spacer(minLength: Design.Space.group)
            Menu {
                ForEach(externalScreens.indices, id: \.self) { index in
                    let screen = externalScreens[index]
                    Button(screen.localizedName) {
                        externalDisplay.start(
                            on: screen,
                            project: $project,
                            projectState: projectState,
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
            } label: {
                Image(systemName: Design.Symbol.externalDisplay)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Lit while the viewer is out on another screen, as a toggle
            // that is on; quiet otherwise, like the other icon buttons.
            .tint(externalDisplay.isActive ? Design.accent : Design.textSecondary)
            .disabled(externalScreens.isEmpty && !externalDisplay.isActive)
            .help(externalDisplay.isActive
                  ? "Showing the viewer on an external display"
                  : externalScreens.isEmpty ? "Connect a second display to show the viewer on it" : "Show the viewer on an external display")
            .accessibilityLabel("External display")
            .accessibilityValue(externalDisplay.isActive ? "On" : "Off")

            AutosaveWarning()

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

            // The format and sound are picked in the Export window, so
            // no menu here keeps the arrow keys from the playhead; an
            // export under way shows its progress beside the button.
            HStack(spacing: Design.Space.close) {
                ExportProgress(export: exportWindow)
                Button("Export\u{2026}") {
                    showExport()
                }
                .buttonStyle(.borderedProminent)
                .tint(Design.accentFill)
                .help("Pick the format and sound, and export the timeline")
            }
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
        .focusedSceneValue(\.exportTimeline, FileMenuAction { showExport() })
        .onChange(of: pasteChanges.count, initial: true) { _, count in
            exportWindow.pasteChangeCount = count
        }
        .onChange(of: project.timeline(id: activeTimelineID)?.name ?? "", initial: true) { _, name in
            exportWindow.timelineName = name
        }
        .onAppear {
            exportWindow.onExport = { exportProject() }
            exportWindow.onReviewPasteChanges = {
                exportWindow.showEditor()
                exportAfterAccepting = false
                showsPasteChanges = true
            }
        }
    }

    private func showExport() {
        exportWindow.show()
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
            exportWindow.showEditor()
            exportAfterAccepting = true
            showsPasteChanges = true
            return
        }
        exportWindow.run(project: project, timelineID: activeTimelineID, renderer: renderer)
    }
}

/// The running export's progress on the toolbar, which reads it itself so
/// its updates redraw it alone. Shown only while one runs.
private struct ExportProgress: View {
    let export: ExportWindow

    var body: some View {
        if export.isRunning {
            ProgressView(value: export.progress)
                .controlSize(.small)
                .frame(width: 90)
                .accessibilityLabel("Export progress")
                .help("Exporting")
        }
    }
}
