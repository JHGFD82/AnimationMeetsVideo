import AppKit
import SwiftUI

/// What a timeline window shows: one timeline of a project already open in
/// its own window.
struct TimelineWindowRef: Codable, Hashable {
    var projectURL: URL
    var timelineID: UUID
}

/// A second editor on a project open in its window, on another timeline,
/// from the Timelines tab's Open in New Window. It shares that window's
/// session: the same project, analysis and history, and that window's
/// undo, so ⌘Z in either undoes the last edit made in either (the history
/// keeps whole snapshots, and two stacks would undo each other's edits).
/// It saves with the project and closes when the project's window does.
struct TimelineWindow: View {
    static let groupID = "timeline"

    @Binding var ref: TimelineWindowRef?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let ref, let session = ProjectWindows.shared.session(showing: ref.projectURL) {
            EditorView(
                project: Bindable(session.projectState).value, history: session.history, analysis: session.analysis,
                replacement: session.replacement, packageURL: session.projectURL,
                timelineID: ref.timelineID, sharesHistory: true
            )
            .equatable()
            .environment(session.projectState)
            .environment(session.autosaveStatus)
            .frame(minWidth: 1_100, minHeight: 700)
            .focusedSceneValue(\.projectSession, session)
            .background(SharedUndoWindow(source: { session.editorWindow }))
            .navigationTitle(title(in: session, ref: ref))
            .onChange(of: session.isClosed) { _, closed in
                if closed { dismiss() }
            }
        } else {
            // The project was closed, or this window was restored after it.
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { dismiss() }
        }
    }

    private func title(in session: ProjectSession, ref: TimelineWindowRef) -> String {
        let timeline = session.projectState.value.timeline(id: ref.timelineID)?.name ?? "Timeline"
        return "\(ref.projectURL.deletingPathExtension().lastPathComponent) — \(timeline)"
    }
}

/// Records the window this view is in, for a timeline window to borrow its
/// undo (see `SharedUndoWindow`).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

/// Makes this view's window undo with another window's undo manager. The
/// undo manager is the delegate's to give (`windowWillReturnUndoManager`),
/// and SwiftUI owns the delegate, so this sits in front of it and passes
/// every other call through, as `WindowCloseGuard` does.
struct SharedUndoWindow: NSViewRepresentable {
    /// The window whose undo manager to use; nil leaves the window its own.
    let source: () -> NSWindow?

    func makeNSView(context: Context) -> ProxyView {
        let view = ProxyView()
        view.source = source
        return view
    }

    func updateNSView(_ view: ProxyView, context: Context) {
        view.source = source
    }

    final class ProxyView: NSView {
        var source: (() -> NSWindow?)?
        private var proxy: DelegateProxy?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.delegate is DelegateProxy) else { return }
            let proxy = DelegateProxy(original: window.delegate) { [weak self] in self?.source?()?.undoManager }
            self.proxy = proxy
            window.delegate = proxy
        }
    }

    final class DelegateProxy: NSObject, NSWindowDelegate {
        private weak var original: NSWindowDelegate?
        private let undoManager: () -> UndoManager?

        init(original: NSWindowDelegate?, undoManager: @escaping () -> UndoManager?) {
            self.original = original
            self.undoManager = undoManager
        }

        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
            undoManager() ?? original?.windowWillReturnUndoManager?(window)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original
        }
    }
}
