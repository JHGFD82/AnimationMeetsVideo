import AppKit
import CoreMedia
import Observation
import SwiftUI

/// The graph editors open for an editor surface: floating HUD panels, one
/// per parameter (a layer's position, its volume, …) or several linked
/// into one on a shared timeline, so several can be open side by side, and
/// the Audio Keys editors, one per effect. Dragging a graph panel by its
/// title bar onto another links their graphs into that one. The surface
/// keeps `project` and `playhead` current and says how to edit and seek;
/// the panels' graphs read from here.
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
    @ObservationIgnored private var panels: [Subject: NSPanel] = [:]
    @ObservationIgnored private var observers: [Subject: [NSObjectProtocol]] = [:]
    /// The graphs of each graph panel.
    private var links: [UUID: KeyframeGraphLink] = [:]

    /// A graph panel dragged over another, which letting go links into it
    /// when `allowed`.
    struct DropTarget: Equatable {
        var link: UUID
        var allowed: Bool
    }

    /// The graph panel under a graph panel being dragged, for it to show.
    private(set) var dropTarget: DropTarget?
    /// The graph panel being dragged by its title bar.
    @ObservationIgnored private var draggedLink: UUID?
    /// Watches for the end of a panel's drag, which the window server
    /// moves without telling the app when the mouse goes up.
    @ObservationIgnored private var dragTimer: Timer?

    /// What a panel shows.
    private enum Subject: Hashable {
        case graphs(UUID)
        case audioKeys(AudioKeysEditorKey)
    }

    /// A graph's height in a panel, which a linked graph adds to it.
    private static let graphHeight: CGFloat = 300

    /// Opens the parameter's graph editor, or brings forward the panel that
    /// has it.
    func show(_ key: ParameterKey) {
        if let link = links.values.first(where: { $0.keys.contains(key) }), let panel = panels[.graphs(link.id)] {
            panel.orderFront(nil)
            return
        }
        openGraphs(KeyframeGraphLink([key]))
    }

    /// Opens an Audio Keys effect's editor, or brings it to the front.
    func showAudioKeys(_ key: AudioKeysEditorKey) {
        let host = GraphHostingView(rootView: AudioKeysEditor(hud: self, key: key))
        open(.audioKeys(key), content: host, size: NSSize(width: 640, height: 460), minimum: NSSize(width: 480, height: 360))
    }

    private func openGraphs(_ link: KeyframeGraphLink) {
        links[link.id] = link
        let input = GraphInput()
        let host = GraphHostingView(rootView: KeyframeGraphStack(hud: self, link: link, input: input))
        host.input = input
        let count = CGFloat(link.keys.count)
        open(
            .graphs(link.id), content: host, size: NSSize(width: 520, height: Self.graphHeight * count),
            minimum: NSSize(width: 360, height: 220 * count)
        )
    }

    private func open(_ subject: Subject, content: NSView, size: NSSize, minimum: NSSize) {
        if let panel = panels[subject] {
            panel.orderFront(nil)
            return
        }
        let key = subject
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        panel.contentMinSize = minimum
        panel.title = title(of: key)
        panel.contentView = content
        watchSpace()
        place(panel)
        var watching = [NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(key) }
        }]
        if case .graphs(let id) = key {
            watching.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelMoved(id) }
            })
        }
        observers[key] = watching
        panels[key] = panel
        panel.orderFront(nil)
    }

    /// Keeps the graphs current, retitles panels whose layer was renamed,
    /// and closes those whose layer is gone; a linked graph whose layer is
    /// gone leaves its panel.
    func update(project: EditingProject) {
        self.project = project
        for link in links.values {
            let kept = link.keys.filter { project.components(of: $0) != nil }
            if kept.count != link.keys.count, !kept.isEmpty { link.keys = kept }
        }
        for (key, panel) in panels {
            if !exists(key) {
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

    // MARK: Linking

    /// The other open graph panels whose graphs can join `id`'s, with their
    /// titles.
    func linkCandidates(for id: UUID) -> [(id: UUID, title: String)] {
        guard let link = links[id] else { return [] }
        return links.values
            .filter { link.canLink($0) && panels[.graphs($0.id)] != nil }
            .map { ($0.id, title(of: .graphs($0.id))) }
            .sorted { $0.title < $1.title }
    }

    /// Links the graphs of panel `source` into panel `target`, under its
    /// own, and closes `source`. The panel grows by the graphs it takes
    /// in, its top staying put, within the screen; their time fits them all.
    func link(_ source: UUID, into target: UUID) {
        guard source != target, let from = links[source], let into = links[target], into.canLink(from),
              let panel = panels[.graphs(target)]
        else { return }
        let added = from.keys.filter { !into.keys.contains($0) }
        into.keys += added
        into.viewport.times = nil
        panels[.graphs(source)]?.close()
        resize(panel, toHold: into.keys.count)
        panel.title = title(of: .graphs(target))
        panel.makeKeyAndOrderFront(nil)
        AccessibilityNotification.Announcement("Linked \(added.count == 1 ? "a graph" : "\(added.count) graphs"); \(into.keys.count) graphs now share one timeline").post()
    }

    /// Takes a linked graph out of panel `id` into a panel of its own; the
    /// panel it leaves shrinks by it.
    func unlink(_ key: ParameterKey, from id: UUID) {
        guard let link = links[id], link.isLinked, let panel = panels[.graphs(id)] else { return }
        link.keys.removeAll { $0 == key }
        link.viewport.times = nil
        resize(panel, toHold: link.keys.count)
        panel.title = title(of: .graphs(id))
        openGraphs(KeyframeGraphLink([key]))
    }

    /// Sizes a graph panel for `count` graphs, its top where it was.
    private func resize(_ panel: NSPanel, toHold count: Int) {
        let graphs = CGFloat(max(count, 1))
        panel.contentMinSize = NSSize(width: 360, height: 220 * graphs)
        var frame = panel.frame
        let visible = panel.screen?.visibleFrame ?? frame
        let chrome = frame.height - panel.contentLayoutRect.height
        let height = min(Self.graphHeight * graphs + chrome, visible.height)
        frame.origin.y = max(frame.maxY - height, visible.minY)
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: !Design.Motion.isReduced)
    }

    /// A graph panel moved: while the mouse is down, it is being dragged
    /// by its title bar, and may be over another to link into.
    private func panelMoved(_ id: UUID) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        if draggedLink != id {
            draggedLink = id
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchDrag() }
            }
            RunLoop.main.add(timer, forMode: .common)
            dragTimer?.invalidate()
            dragTimer = timer
        }
        updateDropTarget()
    }

    /// Follows a panel's drag until the mouse goes up, then links it into
    /// the panel under it, if it may.
    private func watchDrag() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return updateDropTarget() }
        dragTimer?.invalidate()
        dragTimer = nil
        let source = draggedLink, target = dropTarget
        draggedLink = nil
        dropTarget = nil
        if let source, let target, target.allowed { link(source, into: target.link) }
    }

    /// The graph panel under the pointer, behind the one being dragged.
    private func updateDropTarget() {
        guard let source = draggedLink, let dragged = links[source], let draggedPanel = panels[.graphs(source)] else {
            if dropTarget != nil { dropTarget = nil }
            return
        }
        let mouse = NSEvent.mouseLocation
        let under = NSApp.orderedWindows.first { $0 !== draggedPanel && $0.isVisible && $0.frame.contains(mouse) }
        let target = panels.first { $0.value === under }.flatMap { entry -> DropTarget? in
            guard case .graphs(let id) = entry.key, let link = links[id] else { return nil }
            return DropTarget(link: id, allowed: link.canLink(dragged))
        }
        if target != dropTarget { dropTarget = target }
    }

    // MARK: Panels

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

    private func exists(_ subject: Subject) -> Bool {
        switch subject {
        case .graphs(let id): links[id]?.keys.contains { project.components(of: $0) != nil } == true
        case .audioKeys(let key): project.clipAndLayer(key.clipID, in: key.timelineID)?.clip.effect(id: key.effectID) != nil
        }
    }

    private func forget(_ key: Subject) {
        for observer in observers.removeValue(forKey: key) ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
        panels.removeValue(forKey: key)
        if case .graphs(let id) = key {
            links.removeValue(forKey: id)
            if draggedLink == id {
                draggedLink = nil
                dragTimer?.invalidate()
                dragTimer = nil
            }
            if dropTarget?.link == id { dropTarget = nil }
        }
    }

    private func title(of subject: Subject) -> String {
        switch subject {
        case .graphs(let id):
            let titles = (links[id]?.keys ?? []).map { project.parameterTitle(of: $0) }
            return titles.count > 1 ? "Linked: \(titles.joined(separator: ", "))" : titles.first ?? "Graph"
        case .audioKeys(let key):
            let name = project.clipAndLayer(key.clipID, in: key.timelineID)?.clip.effect(id: key.effectID)?.displayName ?? "Audio Keys"
            return "\(project.clipName(key.clipID, in: key.timelineID)) · \(name)"
        }
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
private final class GraphHostingView<Content: View>: NSHostingView<Content> {
    var input: GraphInput?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Scrolling moves the graph, which SwiftUI has no modifier for here.
    override func scrollWheel(with event: NSEvent) {
        guard let input else { return super.scrollWheel(with: event) }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let point = convert(event.locationInWindow, from: nil)
        input.scroll = GraphInput.Scroll(
            dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale, phase: ScrollInputPhase(event),
            location: CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
        )
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
        /// For time's edge to know when to spring back.
        var phase = ScrollInputPhase.wheel
        /// Where the pointer is, from the panel's top left, for linked
        /// graphs to tell which one it is over.
        var location: CGPoint?
    }

    var scroll: Scroll?
}
