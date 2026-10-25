import AppKit
import CoreMedia
import Observation
import SwiftUI

/// Find All: a floating panel listing where the timelines use what is
/// picked in the browser (an asset, a scene of one, or a timeline), one row
/// per use with its timeline, layer, start, end and duration. It follows
/// the project as it is edited, and double-clicking a row (or Return)
/// opens its timeline with the clip selected. See docs/browser.md,
/// "Finding uses".
@MainActor
@Observable
final class UsesFinder {
    /// What to find: an item, all of it or, for a scene, a stretch of its
    /// asset's original time, under the name the browser gives it.
    struct Query: Equatable {
        var item: UsedItem
        var range: CMTimeRange?
        var name: String
    }

    /// One use as listed: what it is a use of, and where.
    struct Row: Identifiable, Equatable {
        var use: ItemUse
        var itemName: String
        var timelineName: String
        var layerName: String
        /// The effect taking it as its input, for an input.
        var effectName: String?
        var start: String
        var end: String
        var duration: String

        var id: String { "\(itemName)|\(use.id)" }
    }

    private(set) var project = EditingProject.empty
    private(set) var queries: [Query] = []
    private(set) var isOpen = false
    /// Opens a use's timeline in the editor with its clip selected.
    @ObservationIgnored var onShow: (ItemUse) -> Void = { _ in }
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    /// Every use of what is shown, in the order of the queries.
    var rows: [Row] {
        queries.flatMap { query in
            project.uses(of: query.item, within: query.range).compactMap { row(for: $0, of: query) }
        }
    }

    /// What the panel is titled: the one thing it finds, or how many.
    var title: String {
        queries.count == 1 ? "Uses of \(queries[0].name)" : "Uses of \(queries.count) Items"
    }

    private func row(for use: ItemUse, of query: Query) -> Row? {
        guard let timeline = project.timeline(id: use.timelineID), let layer = timeline.layer(id: use.layerID) else { return nil }
        let effect = use.effectID.flatMap { id in layer.clips.first(id: use.clipID)?.effects.first(id: id) }
        func code(_ time: CMTime) -> String { time.compactTimecode(frameRate: timeline.frameRate) }
        return Row(
            use: use, itemName: query.name, timelineName: timeline.name,
            layerName: project.displayName(of: layer, in: timeline), effectName: effect?.displayName,
            start: code(use.start), end: code(use.end), duration: code(use.duration)
        )
    }

    /// Opens the panel on `queries`, or shows them in the one open and
    /// brings it to the front.
    func show(_ queries: [Query]) {
        self.queries = queries
        panel?.title = title
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: UsesFinderView(finder: self))
        host.sizingOptions = [.minSize]
        panel.contentView = host
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose() }
        }
        panel.setFrameAutosaveName("UsesFinder")
        if panel.frame.origin == .zero { panel.center() }
        self.panel = panel
        isOpen = true
        panel.makeKeyAndOrderFront(nil)
    }

    /// Shows `queries` as if open, without a panel, for a picture of the
    /// view (`UISnapshots`) and tests.
    func showWithoutPanel(_ queries: [Query]) {
        self.queries = queries
        isOpen = true
    }

    func close() {
        panel?.close()
    }

    private func didClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        panel = nil
        isOpen = false
        queries = []
    }

    /// Keeps it current with the project, after any edit, undo or redo.
    /// What is gone from the project drops out of it.
    func update(project: EditingProject) {
        self.project = project
        let present = queries.filter { query in
            switch query.item {
            case .media(let id): project.mediaClip(id: id) != nil
            case .timeline(let id): project.timeline(id: id) != nil
            }
        }
        if present != queries {
            queries = present
            panel?.title = title
        }
    }
}
