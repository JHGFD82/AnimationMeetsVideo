import SwiftUI

/// The project's own settings (File > Project Settings…). Changes apply
/// together on Done, as one undoable edit.
struct ProjectSettingsView: View {
    let project: EditingProject
    let onApply: (_ name: String, _ copiesMediaOnImport: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var copiesMediaOnImport = true

    private static let importNote = "The import dialog starts with this choice and can still change it for one import. Off, imported files stay where they are and the project refers to them in place."

    var body: some View {
        SheetFrame(
            title: "Project Settings",
            subtitle: "These apply to the whole project. Changes are made together when you save them, and can be undone.",
            width: Design.SheetWidth.standard
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
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save Settings") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                onApply(trimmed.isEmpty ? project.name : trimmed, copiesMediaOnImport)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            name = project.name
            copiesMediaOnImport = project.copiesMediaOnImport
        }
    }
}
