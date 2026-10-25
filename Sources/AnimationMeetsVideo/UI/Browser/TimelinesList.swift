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

    /// Rows whose nested timelines are hidden. All start shown, since the
    /// nesting is what the tab is for.
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        List {
            ForEach(Self.nodes(of: project, sort: sort)) { node in
                outline(node)
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
    }

    /// A row, and under a disclosure triangle the timelines it embeds.
    private func outline(_ node: Node) -> AnyView {
        guard let timeline = project.timeline(id: node.timelineID) else { return AnyView(EmptyView()) }
        guard let children = node.children else { return AnyView(row(timeline)) }
        let isExpanded = Binding(
            get: { !collapsed.contains(node.id) },
            set: { shown in if shown { collapsed.remove(node.id) } else { collapsed.insert(node.id) } }
        )
        return AnyView(DisclosureGroup(isExpanded: isExpanded) {
            ForEach(children) { child in outline(child) }
        } label: {
            row(timeline)
        })
    }

    private func row(_ timeline: Timeline) -> some View {
        let isSelected = selectedID == timeline.id
        let isActive = timeline.id == activeTimelineID
        let canEmbed = project.canEmbed(timeline.id, into: activeTimelineID)
        return Label {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .selectedRow(isSelected)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(timeline.id) }
        .simultaneousGesture(TapGesture().onEnded {
            focused = true
            selectedID = timeline.id
        })
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
    }

    private func open(_ id: UUID) {
        renamingID = nil
        selectedID = id
        onOpen(id)
    }
}
