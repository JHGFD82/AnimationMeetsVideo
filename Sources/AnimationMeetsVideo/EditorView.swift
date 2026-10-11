import AVFoundation
import SwiftUI

struct EditorView: View {
    @Binding var project: EditingProject
    @State private var selectedClipID: UUID?

    private var selectedClip: MediaClip? {
        project.clips.first { $0.id == selectedClipID }
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(clips: project.clips, selectedClipID: $selectedClipID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                EditorToolbar(project: $project)
                Divider()

                HStack(spacing: 0) {
                    ViewerPanel(clip: selectedClip)
                    InspectorPanel(clip: selectedClip)
                        .frame(width: 260)
                }

                Divider()
                TimelineView(project: $project, selectedClipID: $selectedClipID)
                    .frame(height: 190)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            selectedClipID = project.clips.first?.id
        }
    }
}

private struct LibrarySidebar: View {
    let clips: [MediaClip]
    @Binding var selectedClipID: UUID?

    var body: some View {
        List(clips, selection: $selectedClipID) { clip in
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
            .tag(clip.id)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button(action: {}) {
                    Image(systemName: "plus")
                }
                .help("Import media")
            }
        }
    }
}

private struct EditorToolbar: View {
    @Binding var project: EditingProject

    var body: some View {
        HStack {
            Text(project.name)
                .font(.headline)
            Spacer()
            Picker("Viewer scale", selection: .constant(ViewerScale.fit)) {
                ForEach(ViewerScale.allCases) { scale in
                    Text(scale.rawValue).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            Button("Export") {}
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ViewerPanel: View {
    let clip: MediaClip?

    var body: some View {
        ZStack {
            Color.black
            MetalPreviewView()
                .aspectRatio(16 / 9, contentMode: .fit)
                .padding(36)
            if let clip {
                VStack {
                    Spacer()
                    HStack {
                        Label(clip.name, systemImage: clip.kind.systemImage)
                        Spacer()
                        Text(clip.formatSummary)
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(12)
                }
            } else {
                ContentUnavailableView("No Clip Selected", systemImage: "film")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InspectorPanel: View {
    let clip: MediaClip?

    var body: some View {
        Form {
            Section("Inspector") {
                if let clip {
                    LabeledContent("Name", value: clip.name)
                    LabeledContent("Duration", value: clip.duration.formatted)
                    LabeledContent("Color", value: clip.colorSpace.rawValue)
                } else {
                    Text("Select a clip to inspect it.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Non-destructive controls") {
                Toggle("Auto matte", isOn: .constant(false))
                Toggle("Vector source", isOn: .constant(false))
                Button("Add text effect") {}
            }
        }
        .formStyle(.grouped)
        .disabled(clip == nil)
    }
}

private struct TimelineView: View {
    @Binding var project: EditingProject
    @Binding var selectedClipID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Timeline", systemImage: "timeline.selection")
                    .font(.headline)
                Spacer()
                Text(project.timebaseSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)

            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(project.clips) { clip in
                        Button {
                            selectedClipID = clip.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(clip.name)
                                    .lineLimit(1)
                                Text(clip.duration.formatted)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: max(120, clip.duration.seconds * 35), height: 66, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(selectedClipID == clip.id ? Color.accentColor.opacity(0.3) : Color.blue.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 12)
    }
}

private enum ViewerScale: String, CaseIterable, Identifiable {
    case fit = "Fit"
    case oneToOne = "100%"

    var id: Self { self }
}
