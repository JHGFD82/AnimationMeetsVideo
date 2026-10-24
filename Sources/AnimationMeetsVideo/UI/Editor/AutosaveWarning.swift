import SwiftUI

/// In the toolbar while automatic backups are failing (`AutosaveStatus`):
/// a warning that opens an explanation, with Save Now. Nothing shows while
/// backups are written.
struct AutosaveWarning: View {
    @Environment(AutosaveStatus.self) private var status: AutosaveStatus?
    @State private var explains = false

    var body: some View {
        if let status, let failure = status.failure {
            Button {
                explains = true
            } label: {
                Label("Not backed up", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(Design.statusWarning)
            }
            .buttonStyle(.borderless)
            .help("Automatic backups aren't being written. Click for details.")
            .accessibilityLabel("Automatic backups failing")
            .accessibilityHint("Shows why, and offers to save now")
            .alert("Automatic Backups Stopped", isPresented: $explains) {
                Button("Save Now") { status.save?() }
                Button("Later", role: .cancel) {}
            } message: {
                Text(Self.message(failure: failure, since: status.failingSince))
            }
        }
    }

    static func message(failure: String, since: Date?) -> String {
        let when = since.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return "The project's automatic backup couldn't be written\(when): \(failure)\n\nYour changes are still open here, but if the app quits unexpectedly they can't be recovered. Save to keep them."
    }
}
