import AppKit
import SwiftUI

/// Names the app in the window's title bar, and shows the open project
/// there as the Mac shows a document: the package's icon beside the title
/// (drag it, or Command-click the title for the folders it is in), and the
/// dot in the close button while there are unsaved changes. The project's
/// own name is on the timeline's header, at the start of its breadcrumb.
///
/// A view of its own, so reading the project on every edit runs only this
/// body and not the scene's.
struct ProjectWindowTitle: View {
    let projectState: ProjectState
    let savedProject: EditingProject
    let packageURL: URL?
    let autosaveStatus: AutosaveStatus
    @AppStorage(Preferences.savesAutomatically) private var savesAutomatically = true

    var body: some View {
        let project = projectState.value
        // Saving after every change, an edit is unsaved only for a moment;
        // the dot would flicker at each one, so it shows only when those
        // saves are failing.
        let savingFails = autosaveStatus.failure != nil && autosaveStatus.kind == .save
        WindowDocumentState(
            title: "Animation Meets Video",
            url: packageURL,
            isEdited: packageURL != nil && project != savedProject && (!savesAutomatically || savingFails)
        )
    }
}

/// Sets the window's title, represented file and edited state. SwiftUI's
/// `navigationTitle` and `navigationDocument` would cover the first two,
/// but nothing in SwiftUI sets the edited dot.
private struct WindowDocumentState: NSViewRepresentable {
    let title: String
    let url: URL?
    let isEdited: Bool

    func makeNSView(context: Context) -> StateView {
        let view = StateView()
        view.state = self
        return view
    }

    func updateNSView(_ view: StateView, context: Context) {
        view.state = self
        view.apply()
    }

    final class StateView: NSView {
        var state: WindowDocumentState?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window, let state else { return }
            if window.title != state.title { window.title = state.title }
            if window.representedURL != state.url { window.representedURL = state.url }
            if window.isDocumentEdited != state.isEdited { window.isDocumentEdited = state.isEdited }
        }
    }
}
