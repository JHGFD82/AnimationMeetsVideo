import SwiftUI

extension View {
    /// The project's dialogs, Project Settings and Replace Media with its
    /// notices, shown on this window while it is the project's window last
    /// in front (`ProjectSession.dialogWindow`). The project's own window
    /// passes nil for `window`; a timeline window passes its own ID, so a
    /// dialog asked for there opens there, and not on the project's window,
    /// which may be behind.
    func projectDialogs(session: ProjectSession, window: UUID?) -> some View {
        modifier(ProjectDialogs(session: session, window: window))
    }
}

private struct ProjectDialogs: ViewModifier {
    let session: ProjectSession
    let window: UUID?
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        let isHost = session.dialogWindow == window
        content
            .mediaReplacementDialogs(
                project: Bindable(session.projectState).value, controller: session.replacement,
                analysis: session.analysis, packageURL: session.projectURL,
                isHost: isHost, checksFiles: window == nil
            )
            .background(
                Color.clear.sheet(isPresented: Binding(
                    get: { isHost && session.showsProjectSettings },
                    set: { if isHost { session.showsProjectSettings = $0 } }
                )) {
                    // Read in the sheet's own view, so the window doesn't
                    // read the project.
                    ProjectSettingsSheet(project: Bindable(session.projectState).value)
                }
            )
            .onChange(of: activeState, initial: true) { _, state in
                if state == .key { session.showDialogs(in: window) }
            }
            // A dialog kept its window while this one came forward; once
            // it is gone, the next shows here.
            .onChange(of: session.showsProjectSettings || session.replacement.isPresenting) { _, busy in
                if !busy, activeState == .key { session.showDialogs(in: window) }
            }
            .onDisappear {
                if let window { session.windowClosed(window) }
            }
    }
}
