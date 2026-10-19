import AppKit
import Observation
import SwiftUI

/// The parts of the editor window that can be the active one.
enum EditorPanel: Hashable {
    case browser, viewer, sidePanel, timeline, effectsLibrary
}

/// Which panel the person is working in: the one they last clicked in,
/// whatever the click did. It wears a light border (`editorPanel`), its
/// selection is drawn in the accent while the others' turn grey
/// (`selectedRow`), and the Edit menu and Delete go to it first, so the
/// border says where the keys will act.
@MainActor @Observable
final class ActivePanel {
    var current: EditorPanel = .timeline
    /// Where each panel is, in window coordinates (top-left origin).
    @ObservationIgnored var frames: [EditorPanel: CGRect] = [:]

    /// A click at `point` in the window makes the panel under it active.
    func click(at point: CGPoint) {
        let hit = frames.filter { $0.value.contains(point) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?.key
        if let hit, hit != current { current = hit }
    }
}

extension Design {
    /// The border of the active panel: light, and inside the panel's edge
    /// so it never covers the grooves between panels.
    static let activePanelBorder = Color.white.opacity(0.4)
}

extension View {
    /// Makes this the editor's `panel`: a click in it makes it the active
    /// one, which draws a light border round it and tells the views in it
    /// (`isInActivePanel`).
    func editorPanel(_ panel: EditorPanel, _ active: ActivePanel) -> some View {
        modifier(EditorPanelFrame(panel: panel, active: active))
    }
}

private struct EditorPanelFrame: ViewModifier {
    let panel: EditorPanel
    let active: ActivePanel

    func body(content: Content) -> some View {
        let isActive = active.current == panel
        content
            .environment(\.isInActivePanel, isActive)
            .overlay {
                Rectangle()
                    .strokeBorder(Design.activePanelBorder, lineWidth: 1.5)
                    .opacity(isActive ? 1 : 0)
                    .decorative()
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { active.frames[panel] = $0 }
    }
}

/// Watches clicks in the window it is in, without taking them, and tells
/// `ActivePanel` where they landed. A gesture on each panel would miss
/// clicks a button or a clip's own drag takes first.
struct ActivePanelMonitor: NSViewRepresentable {
    let active: ActivePanel

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.active = active
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.active = active
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var active: ActivePanel?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, let height = window.contentView?.bounds.height else { return }
            active?.click(at: CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y))
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private struct ActivePanelKey: FocusedValueKey {
    typealias Value = EditorPanel
}

extension FocusedValues {
    /// The editor's active panel, for the Edit menu to ask it first.
    var activePanel: EditorPanel? {
        get { self[ActivePanelKey.self] }
        set { self[ActivePanelKey.self] = newValue }
    }
}
