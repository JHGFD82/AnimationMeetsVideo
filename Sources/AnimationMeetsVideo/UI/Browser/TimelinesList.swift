import AppKit
import CoreMedia
import SwiftUI

/// How the browser's Timelines tab is laid out, chosen in its view options.
enum TimelinesLayout: String, CaseIterable, Identifiable {
    /// Each timeline a filmstrip of its frames, skimmed as clips are
    /// (`TimelineFilmstrips`).
    case filmstrips
    /// The tree of what embeds what, each timeline a row with its icon,
    /// name, duration and settings, and no pictures.
    case tree

    var id: Self { self }

    var title: String {
        switch self {
        case .filmstrips: "Filmstrips"
        case .tree: "Tree"
        }
    }
}

/// The browser's Timelines tab, laid out as filmstrips
/// (`TimelineFilmstrips`) or as the tree below, as its view options say.
///
/// The tree: the project's timelines, each nested under the timeline it is
/// embedded in (with a disclosure triangle), the main timeline first, with
/// its duration and settings. Selecting works as in the Clips tab in both:
/// a click selects one, Command-click adds or takes one out, Shift-click
/// selects a run, and the arrows move the selection. A double-click opens
/// one in the editor, and a click on the name of the only one selected,
/// or Return, renames it. Its menu embeds the selected timelines (or the
/// picked range of one) in the active timeline or duplicates them, and
/// renames or opens the one clicked; it and Delete delete those nothing
/// uses. Dragged, the selected timelines go
/// onto the timeline embedded, as clips do, or onto an effect that takes
/// an input. The active timeline is marked as open.
struct TimelinesList: View {
    let project: EditingProject
    let activeTimelineID: UUID
    let onOpen: (UUID) -> Void
    /// Embeds a timeline in the active timeline, all of it or a range.
    let onEmbed: (UUID, CMTimeRange?) -> Void
    let onDuplicate: (UUID) -> Void
    var onRename: (UUID, String) -> Void = { _, _ in }
    /// Opens a timeline in a window of its own; nil where there is none.
    var onOpenInNewWindow: ((UUID) -> Void)?
    /// Deletes timelines; only ones `canDeleteTimeline` allows are passed.
    var onDelete: ([UUID]) -> Void = { _ in }

    @AppStorage(Preferences.browserSort) private var sort = BrowserSort.added
    @AppStorage(Preferences.timelinesLayout) private var layout = TimelinesLayout.filmstrips
    @State private var picked = BrowserSelection<UUID>()
    /// The timeline whose name is being edited in its row.
    @State private var renamingID: UUID?
    @FocusState private var focused: Bool
    @Environment(BrowserSkim.self) private var skim: BrowserSkim?

    /// A timeline at its place in the tree.
    struct Node: Identifiable {
        var id: UUID { timelineID }
        let timelineID: UUID
        let children: [Node]?
    }

    /// The tree, each timeline once: under the timeline nearest the top
    /// that embeds it (the first of those, in order), so one embedded in two
    /// timelines isn't listed twice. Sorted by name, each level is in
    /// name order, the main timeline still first.
    nonisolated static func nodes(of project: EditingProject, sort: BrowserSort = .added) -> [Node] {
        // Breadth first, so a timeline goes to its shallowest parent;
        // claiming each once also stops a cycle a damaged file could hold.
        let roots = project.topLevelTimelines
        let main = roots.filter { $0 == project.rootTimelineID }
        let top = main + sort.ordered(roots.filter { $0 != project.rootTimelineID }, in: project)
        var claimed = Set(top)
        var children: [UUID: [UUID]] = [:]
        var queue = top[...]
        while let parent = queue.popFirst() {
            for child in project.embeddedTimelines(in: parent) where !claimed.contains(child) {
                claimed.insert(child)
                children[parent, default: []].append(child)
                queue.append(child)
            }
        }
        func node(_ timelineID: UUID) -> Node {
            let below = sort.ordered(children[timelineID] ?? [], in: project).map(node)
            return Node(timelineID: timelineID, children: below.isEmpty ? nil : below)
        }
        return top.map(node)
    }

    /// A timeline as listed: where it is in the tree.
    struct Row: Identifiable, Equatable {
        var id: UUID { timelineID }
        let timelineID: UUID
        let depth: Int
        let hasChildren: Bool
    }

    /// The tree as the rows it shows, top to bottom, leaving out what is
    /// under a collapsed row. It is drawn as one flat list with triangles
    /// of our own: rows in a `DisclosureGroup` are an outline view's, which
    /// takes clicks on them for itself, so double-clicking a timeline that
    /// embeds others, or is embedded, often didn't open it.
    nonisolated static func rows(of nodes: [Node], collapsed: Set<UUID>) -> [Row] {
        var rows: [Row] = []
        func add(_ node: Node, depth: Int) {
            rows.append(Row(timelineID: node.timelineID, depth: depth, hasChildren: node.children != nil))
            guard !collapsed.contains(node.timelineID) else { return }
            for child in node.children ?? [] { add(child, depth: depth + 1) }
        }
        for node in nodes { add(node, depth: 0) }
        return rows
    }

    /// Rows whose nested timelines are hidden. All start shown, since the
    /// nesting is what the tab is for.
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        let nodes = Self.nodes(of: project, sort: sort)
        // Every timeline, in the tree's order read top to bottom.
        let all = Self.rows(of: nodes, collapsed: []).map(\.timelineID)
        Group {
            switch layout {
            case .tree:
                tree(Self.rows(of: nodes, collapsed: collapsed))
            case .filmstrips:
                TimelineFilmstrips(
                    project: project, activeTimelineID: activeTimelineID, order: all,
                    picked: $picked, renamingID: $renamingID,
                    onOpen: open, onRename: onRename,
                    menu: { id in AnyView(menu(id, order: all)) }
                )
                .onChange(of: all) { _, order in picked.keep(only: order) }
            }
        }
        // In either layout, from the keys or the Edit menu while the
        // browser is the active panel (see `EditCommands`).
        .onKeyPress(keys: [.delete, .deleteForward]) { press in
            guard renamingID == nil, press.modifiers.isDisjoint(with: [.control, .option, .shift]), !picked.items.isEmpty else {
                return .ignored
            }
            if !deleteSelection(order: all) { NSSound.beep() }
            return .handled
        }
        .focusedSceneValue(\.browserEditActions, EditMenuActions(
            delete: { if !deleteSelection(order: all) { NSSound.beep() } },
            // What is shown: a collapsed row's timelines stay out.
            selectAll: { picked.selectAll(in: layout == .tree ? Self.rows(of: nodes, collapsed: collapsed).map(\.timelineID) : all) },
            state: [AnyHashable(picked.revision), AnyHashable(all), AnyHashable(collapsed), AnyHashable(layout)]
        ))
    }

    /// Deletes the selected timelines that nothing uses; false when none
    /// of them can go.
    private func deleteSelection(order: [UUID]) -> Bool {
        delete(picked.ordered(in: order))
    }

    /// Deletes those of `ids` that nothing uses, leaving the rest; false
    /// when none can go. One being skimmed stops being skimmed first.
    @discardableResult
    private func delete(_ ids: [UUID]) -> Bool {
        let deletable = ids.filter(project.canDeleteTimeline)
        guard !deletable.isEmpty else { return false }
        if let skimmed = skim?.target?.item.base as? TimelineStripID, deletable.contains(skimmed.timelineID) { skim?.end() }
        renamingID = nil
        onDelete(deletable)
        return true
    }

    private func tree(_ rows: [Row]) -> some View {
        let order = rows.map(\.timelineID)
        return List {
            ForEach(rows) { listed in
                if let timeline = project.timeline(id: listed.timelineID) {
                    row(timeline, listed, order: order)
                }
            }
        }
        .browserListStyle()
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // Return renames the selected timeline, as in the Finder.
        .onKeyPress(.return) {
            guard renamingID == nil, picked.items.count == 1, let id = picked.items.first else { return .ignored }
            renamingID = id
            return .handled
        }
        // Up and Down move the selection, Shift extends it, as in the
        // Clips tab; Right and Left show and hide what the selected
        // timeline embeds, as in the Finder's list view.
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard renamingID == nil else { return .ignored }
            return step(press.key == .upArrow ? -1 : 1, extending: press.modifiers.contains(.shift), in: order)
        }
        .onKeyPress(.rightArrow) { showNested(true) }
        .onKeyPress(.leftArrow) { showNested(false) }
        .onChange(of: order) { _, order in picked.keep(only: order) }
    }

    /// Moves the selection a row up or down from the timeline last clicked,
    /// or extends it there with Shift.
    private func step(_ by: Int, extending: Bool, in order: [UUID]) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let from = picked.anchor.flatMap(order.firstIndex(of:)) ?? (by > 0 ? -1 : order.count)
        let to = order[(from + by).clamped(between: 0, and: order.count - 1)]
        if extending {
            picked.shiftClick(to, in: order)
        } else {
            picked.click(to)
        }
        return .handled
    }

    private func showNested(_ shown: Bool) -> KeyPress.Result {
        guard renamingID == nil, picked.items.count == 1, let id = picked.items.first else { return .ignored }
        if shown { collapsed.remove(id) } else { collapsed.insert(id) }
        return .handled
    }

    private func toggleNested(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// What a drag of `id` carries, noted as the drag begins: the whole of
    /// every selected timeline, in browser order, when `id` is one of them,
    /// otherwise all of `id`. Dropped on the timeline each goes down
    /// embedded (not in itself), as clips do; dropped on an effect, the
    /// first is its input.
    static func dragPayload(from id: UUID, picked: BrowserSelection<UUID>, order: [UUID], in project: EditingProject) -> MediaDragPayload {
        let pieces = picked.dragged(from: id, in: order)
            .compactMap { project.timeline(id: $0) }
            .map { MediaPiece.timeline($0.id, from: .zero, to: $0.duration) }
        return MediaDragPayload.beginDrag(pieces)
    }

    /// What a menu on `id` acts on: everything selected when it is, in
    /// browser order, otherwise just it.
    private func targets(of id: UUID, in order: [UUID]) -> [UUID] {
        picked.dragged(from: id, in: order)
    }

    /// The triangle that shows or hides what a timeline embeds, or room for
    /// one, so names line up at each depth.
    @ViewBuilder
    private func disclosure(_ timeline: Timeline, _ listed: Row) -> some View {
        if listed.hasChildren {
            let isOpen = !collapsed.contains(timeline.id)
            Button { toggleNested(timeline.id) } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Design.textSecondary)
            .accessibilityLabel(isOpen ? "Hide timelines in \(timeline.name)" : "Show timelines in \(timeline.name)")
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    /// A timeline's menu, in either layout. Embedding and duplicating act
    /// on everything selected when it is; with a range picked of it,
    /// embedding takes only the range.
    @ViewBuilder
    private func menu(_ id: UUID, order: [UUID]) -> some View {
        let targets = targets(of: id, in: order)
        let embeddable = targets.filter { project.canEmbed($0, into: activeTimelineID) }
        let range = picked.range.flatMap { range -> CMTimeRange? in
            guard range.item == id else { return nil }
            let timescale: CMTimeScale = 600
            return CMTimeRange(
                start: CMTime(seconds: range.start, preferredTimescale: timescale),
                end: CMTime(seconds: range.end, preferredTimescale: timescale)
            )
        }
        Button("Open") { open(id) }
            .disabled(id == activeTimelineID)
        if let onOpenInNewWindow {
            Button("Open in New Window") { onOpenInNewWindow(id) }
        }
        Divider()
        if let range {
            Button("Embed Range in Active Timeline") { onEmbed(id, range) }
                .disabled(!project.canEmbed(id, into: activeTimelineID))
        }
        Button(embeddable.count > 1 ? "Embed \(embeddable.count) Timelines in Active Timeline" : "Embed in Active Timeline") {
            embeddable.forEach { onEmbed($0, nil) }
        }
        .disabled(embeddable.isEmpty)
        Button("Rename Timeline") {
            picked.click(id)
            renamingID = id
        }
        Button(targets.count > 1 ? "Duplicate \(targets.count) Timelines" : "Duplicate Timeline") {
            targets.forEach(onDuplicate)
        }
        Divider()
        // Not the main timeline, nor one another embeds or takes as an input.
        let deletable = targets.filter(project.canDeleteTimeline)
        Button(deletable.count > 1 ? "Delete \(deletable.count) Timelines" : "Delete Timeline") { delete(deletable) }
            .disabled(deletable.isEmpty)
    }

    private func row(_ timeline: Timeline, _ listed: Row, order: [UUID]) -> some View {
        let isSelected = picked.contains(timeline.id)
        let isActive = timeline.id == activeTimelineID
        return HStack(spacing: Design.Space.tight) {
            disclosure(timeline, listed)
            label(timeline, isSelected: isSelected, isOnlySelection: isSelected && picked.items.count == 1, isActive: isActive)
        }
        .padding(.leading, CGFloat(listed.depth) * Design.Space.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .selectedRow(isSelected)
        // On the press, with the system's click count and keys: a tap
        // gesture for the single click waits to rule out a double-click,
        // and quick clicks were lost (see `onMouseDown`).
        .onMouseDown { clicks in
            focused = true
            let keys = NSApp.currentEvent?.modifierFlags ?? []
            if keys.contains(.command) {
                picked.commandClick(timeline.id)
            } else if keys.contains(.shift) {
                picked.shiftClick(timeline.id, in: order)
            } else {
                picked.click(timeline.id)
                if clicks == 2 { open(timeline.id) }
            }
        }
        .help(isActive ? "The timeline open in the editor" : "Double-click to open in the editor")
        .draggable(Self.dragPayload(from: timeline.id, picked: picked, order: order, in: project))
        .contextMenu { menu(timeline.id, order: order) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens the timeline in the editor")
        .accessibilityAction { open(timeline.id) }
        .accessibilityAction(named: "Embed in active timeline") {
            if project.canEmbed(timeline.id, into: activeTimelineID) { onEmbed(timeline.id, nil) } else { NSSound.beep() }
        }
        .accessibilityAction(named: "Rename timeline") { renamingID = timeline.id }
        .accessibilityAction(named: "Duplicate timeline") { onDuplicate(timeline.id) }
        .accessibilityAction(named: "Delete timeline") { if !delete([timeline.id]) { NSSound.beep() } }
        .accessibilityAction(named: isSelected ? "Deselect" : "Add to selection") { picked.commandClick(timeline.id) }
        .accessibilityAction(named: collapsed.contains(timeline.id) ? "Show nested timelines" : "Hide nested timelines") {
            if listed.hasChildren { toggleNested(timeline.id) } else { NSSound.beep() }
        }
    }

    /// The icon, and the name and duration over the settings.
    private func label(_ timeline: Timeline, isSelected: Bool, isOnlySelection: Bool, isActive: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.close) {
                    InlineNameField(
                        name: timeline.name,
                        isEditing: Binding(
                            get: { renamingID == timeline.id },
                            set: { editing in renamingID = editing ? timeline.id : nil }
                        ),
                        isSelected: isOnlySelection,
                        onCommit: { onRename(timeline.id, $0) }
                    )
                    .foregroundStyle(Design.textPrimary)
                    if isActive {
                        Text("Open")
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Text(timeline.duration.compactTimecode(frameRate: timeline.frameRate))
                        .font(Design.Typeface.numericSmall)
                        .foregroundStyle(Design.textSecondary)
                        .accessibilityLabel("\(timeline.duration.formatted) long")
                }
                Text(timeline.timebaseSummary)
                    .font(Design.Typeface.numericMicro)
                    .foregroundStyle(Design.textTertiary)
            }
        } icon: {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(Design.ClipTone.nested.color)
        }
    }

    private func open(_ id: UUID) {
        renamingID = nil
        picked.click(id)
        onOpen(id)
    }
}
