import AppKit
import SwiftUI

/// Shown while no project is open. The editor always works inside a saved
/// package, so imported media and analysis results go straight to disk.
struct ProjectStartView: View {
    let onNew: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Animation Meets Video")
                .font(.title2.bold())
            Text("Create a project or open one to start. A new project is saved first, so imported media and the pictures and analysis made from it are stored in the project as they're made.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Button("Open Project…", action: onOpen)
                Button("New Project…", action: onNew)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}
