import AppKit
import SwiftUI

/// The browser's Timelines tab: the project's timelines, each nested under
/// the timelines it is embedded in (with a disclosure triangle), the main
/// timeline first. Clicking one embeds it into the active timeline;
/// dragging it puts it on an effect that takes an input; its menu also
/// renames and duplicates it. The active timeline is listed, marked as
/// open, but can't be embedded into itself.
struct TimelinesList: View {
    let project: EditingProject
    let activeTimelineID: UUID
    let onEmbed: (UUID) -> Void
    let onDuplicate: (UUID) -> Void
    var onRename: (UUID, String) -> Void = { _, _ in }

    /// The timeline whose name is being edited in its row.
    @State private var renamingID: UUID?

    /// A timeline at one place in the tree. One embedded in two timelines
    /// shows under both, so a row is told apart by its path from the top.
    struct Node: Identifiable {
        let id: String
        let timelineID: UUID
        let children: [Node]?
    }

    nonisolated static func nodes(of project: EditingProject) -> [Node] {
        func node(_ timelineID: UUID, path: [UUID]) -> Node {
            let here = path + [timelineID]
            // A timeline can't embed itself, but a damaged file could say so.
            let children = project.embeddedTimelines(in: timelineID)
                .filter { !here.contains($0) }
                .map { node($0, path: here) }
            return Node(id: here.map(\.uuidString).joined(separator: "/"), timelineID: timelineID, children: children.isEmpty ? nil : children)
        }
        return project.topLevelTimelines.map { node($0, path: []) }
    }

    /// Rows whose nested timelines are hidden. All start shown, since the
    /// nesting is what the tab is for.
    @State private var collapsed: Set<String> = []

    var body: some View {
        List {
            ForEach(Self.nodes(of: project)) { node in
                outline(node)
            }
        }
        .browserListStyle()
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

    @ViewBuilder
    private func row(_ timeline: Timeline) -> some View {
        if renamingID == timeline.id {
            // Out of the button while its name is edited, so a click in the
            // field doesn't embed the timeline.
            rowLabel(timeline)
        } else {
            embedButton(timeline)
        }
    }

    private func rowLabel(_ timeline: Timeline) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Design.Space.close) {
                    InlineNameField(
                        name: timeline.name,
                        isEditing: Binding(
                            get: { renamingID == timeline.id },
                            set: { editing in renamingID = editing ? timeline.id : nil }
                        ),
                        onCommit: { onRename(timeline.id, $0) }
                    )
                    .foregroundStyle(Design.textPrimary)
                    if timeline.id == activeTimelineID {
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

    private func embedButton(_ timeline: Timeline) -> some View {
        let isActive = timeline.id == activeTimelineID
        let canEmbed = project.canEmbed(timeline.id, into: activeTimelineID)
        // Not disabled when it can't be embedded: its name stays readable
        // and its menu still renames and duplicates it; a click just beeps.
        return Button {
            if canEmbed { onEmbed(timeline.id) } else { NSSound.beep() }
        } label: {
            rowLabel(timeline)
        }
        .buttonStyle(.plain)
        .help(isActive ? "The timeline open below; it can't be embedded into itself"
              : canEmbed ? "Embed into the active timeline, or drag onto an effect that takes an input"
              : "Can't be embedded here: it's empty, or it contains the active timeline")
        .draggable(TimelineDragPayload(timelineID: timeline.id))
        .contextMenu {
            Button("Embed in Active Timeline") { onEmbed(timeline.id) }
                .disabled(!canEmbed)
            Button("Rename Timeline") { renamingID = timeline.id }
            Button("Duplicate Timeline") { onDuplicate(timeline.id) }
        }
        .accessibilityAction(named: "Rename timeline") { renamingID = timeline.id }
        .accessibilityAction(named: "Duplicate timeline") { onDuplicate(timeline.id) }
    }
}
