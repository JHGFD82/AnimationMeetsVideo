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
    @State private var selectedPreset: ProResPreset = .proRes422
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress: Double = 0
    @State private var exportError: String?

    private var isExporting: Bool { exportTask != nil }

    private var externalScreens: [NSScreen] {
        // Exclude the screen the editor window is on; covering it with the
        // borderless viewer window would hide the editor itself.
        let editorScreen = NSApp.windows.first { $0.isMainWindow || $0.isKeyWindow }?.screen ?? NSScreen.main
        return NSScreen.screens.filter { $0 != editorScreen }
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
            Picker("ProRes preset", selection: $selectedPreset) {
                ForEach(ProResPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
            if isExporting {
                ProgressView(value: exportProgress)
                    .frame(width: 90)
                Button("Cancel") {
                    exportTask?.cancel()
                }
            } else {
                Button("Export") {
                    exportProject()
                }
                .buttonStyle(.borderedProminent)
            }
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
        exportProgress = 0
        exportTask = Task {
            defer { exportTask = nil }
            do {
                try await CompositionExporter.export(
                    project: snapshot,
                    timelineID: timelineID,
                    preset: preset,
                    to: url,
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
