import SwiftUI

/// The project's own settings (File > Project Settings…). Changes apply
/// together on Done, as one undoable edit.
struct ProjectSettingsView: View {
    /// What the sheet changes.
    struct Settings: Equatable {
        var name: String
        var copiesMediaOnImport: Bool
        var jointAudioCrossfade: AudioCrossfade
    }

    let project: EditingProject
    let onApply: (Settings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var copiesMediaOnImport = true
    @State private var jointAudioCrossfade = AudioCrossfade.sCurve

    private static let importNote = "The import dialog starts with this choice and can still change it for one import. Off, imported files stay where they are and the project refers to them in place."
    private static let crossfadeNote = "How the sound of two clips crossfades under a transition joining them, while it is attached to their pictures. A transition can choose its own; detached sound is faded by hand."

    var body: some View {
        SheetFrame(
            title: "Project Settings",
            subtitle: "These apply to the whole project. Changes are made together when you save them, and can be undone.",
            width: Design.SheetWidth.standard,
            scrollsContent: true
        ) {
            SheetSection {
                SheetRow("Name") {
                    TextField("Name", text: $name)
                        .labelsHidden()
                }
            }

            SheetSection("Importing") {
                SheetRow("Media files", alignment: .center) {
                    Toggle("Copy into the project", isOn: $copiesMediaOnImport)
                        .accessibilityHint(Self.importNote)
                }
                SheetNote(Self.importNote)
            }

            SheetSection("Transitions") {
                SheetRow("Sound at cuts", alignment: .center) {
                    Picker("Sound at cuts", selection: $jointAudioCrossfade) {
                        ForEach(AudioCrossfade.allCases) { shape in
                            Text(shape.name).tag(shape)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help(jointAudioCrossfade.detail)
                    .accessibilityHint(Self.crossfadeNote)
                }
                SheetNote(Self.crossfadeNote)
            }
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save Settings") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                onApply(Settings(
                    name: trimmed.isEmpty ? project.name : trimmed,
                    copiesMediaOnImport: copiesMediaOnImport,
                    jointAudioCrossfade: jointAudioCrossfade
                ))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            name = project.name
            copiesMediaOnImport = project.copiesMediaOnImport
            jointAudioCrossfade = project.jointAudioCrossfade
        }
    }
}

/// The project settings for a sheet, reading the project only once shown,
/// so the scene that presents it doesn't depend on the project.
struct ProjectSettingsSheet: View {
    @Binding var project: EditingProject

    var body: some View {
        ProjectSettingsView(project: project) { settings in
            var changed = project
            changed.name = settings.name
            changed.copiesMediaOnImport = settings.copiesMediaOnImport
            changed.jointAudioCrossfade = settings.jointAudioCrossfade
            if changed != project { project = changed }
        }
    }
}
