import SwiftUI

/// The project's own settings (File > Project Settings…). Changes apply
/// together on Done, as one undoable edit.
struct ProjectSettingsView: View {
    let project: EditingProject
    let onApply: (_ name: String, _ copiesMediaOnImport: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var copiesMediaOnImport = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project Settings")
                .font(.title3.bold())
            Form {
                TextField("Name", text: $name)
                Toggle("Copy imported media into the project", isOn: $copiesMediaOnImport)
                Text("The import dialog starts with this choice; it can still be changed for each import. When off, imported files stay where they are and the project refers to them there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onApply(trimmed.isEmpty ? project.name : trimmed, copiesMediaOnImport)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            name = project.name
            copiesMediaOnImport = project.copiesMediaOnImport
        }
    }
}
