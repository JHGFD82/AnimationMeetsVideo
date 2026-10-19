import AppKit
import CoreMedia
import Observation
import SwiftUI

/// The graph editors open for an editor surface: one floating HUD panel
/// per parameter (a layer's position, its volume, …), so several can be
/// open side by side. The surface keeps `project` and `playhead` current
/// and says how to edit and seek; the panels' graphs read from here.
@MainActor @Observable
final class KeyframeGraphHUDs {
    private(set) var project = EditingProject.empty
    /// Where the playhead is parked; see `TimelineView.playheadTime`.
    var playhead: CMTime = .zero
    /// The player, which the graphs' playhead lines follow while it plays.
    @ObservationIgnored var playback: PlaybackModel?

    @ObservationIgnored var onEdit: ((inout EditingProject) -> Void) -> Void = { _ in }
    @ObservationIgnored var onSeek: (CMTime) -> Void = { _ in }
    @ObservationIgnored var onTogglePlayback: () -> Void = {}
    /// Space in a graph's panel plays or pauses, as it does in the main
    /// window: the viewer's shortcut for it only reaches the key window.
    @ObservationIgnored private var spaceMonitor: Any?
    @ObservationIgnored private var panels: [ParameterKey: NSPanel] = [:]
    @ObservationIgnored private var closeObservers: [ParameterKey: NSObjectProtocol] = [:]

    /// Opens the parameter's graph editor, or brings it to the front.
    func show(_ key: ParameterKey) {
        if let panel = panels[key] {
            panel.orderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        // Drags inside belong to the graph; the panel moves by its title
        // bar only. HUD panels otherwise move from anywhere on them.
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = NSSize(width: 360, height: 200)
        panel.title = title(of: key)
        let input = GraphInput()
        let host = GraphHostingView(rootView: KeyframeGraphView(hud: self, key: key, input: input))
        host.input = input
        panel.contentView = host
        watchSpace()
        place(panel)
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(key) }
        }
        panels[key] = panel
        panel.orderFront(nil)
    }

    /// Keeps the graphs current, retitles panels whose layer was renamed,
    /// and closes those whose layer is gone.
    func update(project: EditingProject) {
        self.project = project
        for (key, panel) in panels {
            if project.components(of: key) == nil {
                panel.close()
            } else {
                let title = title(of: key)
                if panel.title != title { panel.title = title }
            }
        }
    }

    func closeAll() {
        for panel in Array(panels.values) { panel.close() }
    }

    /// Starts listening for Space in the graphs' panels, once.
    private func watchSpace() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let window = event.window, !(window.firstResponder is NSText)
            else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panels.values.contains(where: { $0 === window }) else { return false }
                self.onTogglePlayback()
                return true
            }
            return handled ? nil : event
        }
    }

    private func forget(_ key: ParameterKey) {
        if let observer = closeObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        panels.removeValue(forKey: key)
    }

    private func title(of key: ParameterKey) -> String {
        project.parameterTitle(of: key)
    }

    /// Near the top right of the main window, each new panel stepped down
    /// from the last so none hides another.
    private func place(_ panel: NSPanel) {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else {
            panel.center()
            return
        }
        let step = CGFloat(panels.count % 8) * 26
        let frame = window.frame
        panel.setFrameTopLeftPoint(NSPoint(
            x: frame.maxX - panel.frame.width - 40 - step,
            y: frame.maxY - 80 - step
        ))
    }
}

/// Hosts a graph without letting a mouse down on it move the window: a
/// hosting view's see-through parts otherwise say it may, and the panel
/// then moves instead of the graph seeing the drag. The first click on a
/// panel that isn't in front goes to the graph too.
private final class GraphHostingView: NSHostingView<KeyframeGraphView> {
    var input: GraphInput?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Scrolling moves the graph, which SwiftUI has no modifier for here.
    override func scrollWheel(with event: NSEvent) {
        guard let input else { return super.scrollWheel(with: event) }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        input.scroll = GraphInput.Scroll(dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale)
    }
}

/// Input a graph's panel hands to its graph.
@MainActor @Observable
final class GraphInput {
    struct Scroll: Equatable {
        let id = UUID()
        /// Points, positive rightward and downward as the content moves.
        var dx: CGFloat
        var dy: CGFloat
    }

    var scroll: Scroll?
}
