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
    var playhead: CMTime = .zero

    @ObservationIgnored var onEdit: ((inout EditingProject) -> Void) -> Void = { _ in }
    @ObservationIgnored var onSeek: (CMTime) -> Void = { _ in }
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
        panel.contentMinSize = NSSize(width: 360, height: 200)
        panel.title = title(of: key)
        panel.contentView = NSHostingView(rootView: KeyframeGraphView(hud: self, key: key))
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

    private func forget(_ key: ParameterKey) {
        if let observer = closeObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        panels.removeValue(forKey: key)
    }

    private func title(of key: ParameterKey) -> String {
        guard let timeline = project.timeline(id: key.timelineID), let layer = timeline.layer(id: key.layerID) else {
            return key.parameter.name
        }
        return "\(project.displayName(of: layer, in: timeline)) · \(key.parameter.name)"
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
