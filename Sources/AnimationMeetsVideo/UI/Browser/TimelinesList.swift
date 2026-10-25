import AppKit
import SwiftUI

/// The browser's Timelines tab: the project's timelines, each nested under
/// the timeline it is embedded in (with a disclosure triangle), the main
/// timeline first. A click selects one, as in the Finder: a double-click
/// opens it in the editor, and a click on the name of the one selected,
/// or Return, renames it. Its menu also embeds it in the active timeline,
/// renames and duplicates it; dragging it puts it on an effect that takes
/// an input. The active timeline is marked as open.
struct TimelinesList: View {
    let project: EditingProject
    let activeTimelineID: UUID
    let onOpen: (UUID) -> Void
    let onEmbed: (UUID) -> Void
    let onDuplicate: (UUID) -> Void
    var onRename: (UUID, String) -> Void = { _, _ in }
    /// Opens a timeline in a window of its own; nil where there is none.
    var onOpenInNewWindow: ((UUID) -> Void)?

    @AppStorage(Preferences.browserSort) private var sort = BrowserSort.added
    @State private var selectedID: UUID?
    /// The timeline whose name is being edited in its row.
    @State private var renamingID: UUID?
    @FocusState private var focused: Bool

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
        List {
            ForEach(Self.rows(of: Self.nodes(of: project, sort: sort), collapsed: collapsed)) { listed in
                if let timeline = project.timeline(id: listed.timelineID) {
                    row(timeline, listed)
                }
            }
        }
        .browserListStyle()
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // Return renames the selected timeline, as in the Finder.
        .onKeyPress(.return) {
            guard renamingID == nil, let selectedID else { return .ignored }
            renamingID = selectedID
            return .handled
        }
        // Right and Left show and hide what the selected timeline embeds,
        // as in the Finder's list view.
        .onKeyPress(.rightArrow) { showNested(true) }
        .onKeyPress(.leftArrow) { showNested(false) }
    }

    private func showNested(_ shown: Bool) -> KeyPress.Result {
        guard renamingID == nil, let selectedID else { return .ignored }
        if shown { collapsed.remove(selectedID) } else { collapsed.insert(selectedID) }
        return .handled
    }

    private func toggleNested(_ id: UUID) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
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

    private func row(_ timeline: Timeline, _ listed: Row) -> some View {
        let isSelected = selectedID == timeline.id
        let isActive = timeline.id == activeTimelineID
        let canEmbed = project.canEmbed(timeline.id, into: activeTimelineID)
        return HStack(spacing: Design.Space.tight) {
            disclosure(timeline, listed)
            label(timeline, isSelected: isSelected, isActive: isActive)
        }
        .padding(.leading, CGFloat(listed.depth) * Design.Space.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .selectedRow(isSelected)
        // On the press, with the system's click count: a tap gesture for
        // the single click waits to rule out a double-click, and quick
        // clicks were lost (see `onMouseDown`).
        .onMouseDown { clicks in
            focused = true
            selectedID = timeline.id
            if clicks == 2 { open(timeline.id) }
        }
        .help(isActive ? "The timeline open in the editor" : "Double-click to open in the editor")
        .draggable(TimelineDragPayload(timelineID: timeline.id))
        .contextMenu {
            Button("Open") { open(timeline.id) }
                .disabled(isActive)
            if let onOpenInNewWindow {
                Button("Open in New Window") { onOpenInNewWindow(timeline.id) }
            }
            Divider()
            Button("Embed in Active Timeline") { onEmbed(timeline.id) }
                .disabled(!canEmbed)
            Button("Rename Timeline") {
                selectedID = timeline.id
                renamingID = timeline.id
            }
            Button("Duplicate Timeline") { onDuplicate(timeline.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Opens the timeline in the editor")
        .accessibilityAction { open(timeline.id) }
        .accessibilityAction(named: "Embed in active timeline") {
            if canEmbed { onEmbed(timeline.id) } else { NSSound.beep() }
        }
        .accessibilityAction(named: "Rename timeline") { renamingID = timeline.id }
        .accessibilityAction(named: "Duplicate timeline") { onDuplicate(timeline.id) }
        .accessibilityAction(named: collapsed.contains(timeline.id) ? "Show nested timelines" : "Hide nested timelines") {
            if listed.hasChildren { toggleNested(timeline.id) } else { NSSound.beep() }
        }
    }

    private func label(_ timeline: Timeline, isSelected: Bool, isActive: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Design.Space.close) {
                    InlineNameField(
                        name: timeline.name,
                        isEditing: Binding(
                            get: { renamingID == timeline.id },
                            set: { editing in renamingID = editing ? timeline.id : nil }
                        ),
                        isSelected: isSelected,
                        onCommit: { onRename(timeline.id, $0) }
                    )
                    .foregroundStyle(Design.textPrimary)
                    if isActive {
                        Text("Open")
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.textSecondary)
                    }
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
        selectedID = id
        onOpen(id)
    }
}
