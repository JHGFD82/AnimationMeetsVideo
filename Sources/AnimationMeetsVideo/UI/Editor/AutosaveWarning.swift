import SwiftUI

/// In the toolbar while automatic saves or backups are failing
/// (`AutosaveStatus`): a warning that opens an explanation, with Save Now.
/// Nothing shows while they are written.
struct AutosaveWarning: View {
    @Environment(AutosaveStatus.self) private var status: AutosaveStatus?
    @State private var explains = false

    var body: some View {
        if let status, let failure = status.failure {
            let isSave = status.kind == .save
            Button {
                explains = true
            } label: {
                Label(isSave ? "Not saved" : "Not backed up", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(Design.statusWarning)
            }
            .buttonStyle(.borderless)
            .help(isSave ? "Your changes aren't being saved. Click for details." : "Automatic backups aren't being written. Click for details.")
            .accessibilityLabel(isSave ? "Automatic saving failing" : "Automatic backups failing")
            .accessibilityHint("Shows why, and offers to save now")
            .alert(isSave ? "Changes Not Saved" : "Automatic Backups Stopped", isPresented: $explains) {
                Button("Save Now") { status.save?() }
                Button("Later", role: .cancel) {}
            } message: {
                Text(Self.message(failure: failure, since: status.failingSince, kind: status.kind))
            }
        }
    }

    static func message(failure: String, since: Date?, kind: AutosaveStatus.Kind = .backup) -> String {
        let when = since.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        switch kind {
        case .save:
            return "Your changes couldn't be saved\(when): \(failure)\n\nThey are still open here. Fix the problem and choose Save Now, or use Save Project As… to save somewhere else."
        case .backup:
            return "The project's automatic backup couldn't be written\(when): \(failure)\n\nYour changes are still open here, but if the app quits unexpectedly they can't be recovered. Save to keep them."
        }
    }
}
