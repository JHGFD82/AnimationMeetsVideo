import SwiftUI

/// The Find All panel's contents: a table of the uses `UsesFinder` finds,
/// under a heading per thing found when there are several. A table, so the
/// arrow keys move through it and VoiceOver reads it by row and column.
struct UsesFinderView: View {
    let finder: UsesFinder
    @State private var selected: Set<UsesFinder.Row.ID> = []

    var body: some View {
        let rows = finder.rows
        VStack(spacing: 0) {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Not used in any timeline", systemImage: "magnifyingglass",
                    description: Text("Nothing in the project's timelines plays it.")
                )
                .frame(maxHeight: .infinity)
            } else {
                table(rows)
            }
            Divider()
            Text(Self.summary(rows))
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Space.group)
                .padding(.vertical, Design.Space.step)
        }
        .frame(minWidth: 480, minHeight: 200)
        .background(Design.Surface.base.color)
        .preferredColorScheme(.dark)
    }

    private func table(_ rows: [UsesFinder.Row]) -> some View {
        let grouped = finder.queries.count > 1
        return Table(of: UsesFinder.Row.self, selection: $selected) {
            TableColumn("Timeline", value: \.timelineName)
                .width(min: 80, ideal: 120)
            TableColumn("Layer", value: \.layerName)
                .width(min: 60, ideal: 90)
            TableColumn("As") { row in
                Text(row.effectName.map { "Input of \($0)" } ?? "Clip")
                    .foregroundStyle(row.effectName == nil ? Design.textPrimary : Design.textSecondary)
            }
            .width(min: 60, ideal: 110)
            // Times take what they need, so the names get the rest.
            TableColumn("Start") { Text($0.start).font(Design.Typeface.numericSmall) }
                .width(64)
            TableColumn("End") { Text($0.end).font(Design.Typeface.numericSmall) }
                .width(64)
            TableColumn("Duration") { Text($0.duration).font(Design.Typeface.numericSmall) }
                .width(72)
        } rows: {
            if grouped {
                ForEach(finder.queries, id: \.name) { query in
                    Section(query.name) {
                        ForEach(rows.filter { $0.itemName == query.name }) { TableRow($0) }
                    }
                }
            } else {
                ForEach(rows) { TableRow($0) }
            }
        }
        // A double-click or Return opens the use's timeline on its clip.
        .contextMenu(forSelectionType: UsesFinder.Row.ID.self) { ids in
            Button("Show in Timeline") { show(ids, in: rows) }
                .disabled(ids.count != 1)
        } primaryAction: { ids in
            show(ids, in: rows)
        }
    }

    private func show(_ ids: Set<UsesFinder.Row.ID>, in rows: [UsesFinder.Row]) {
        guard let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
        finder.onShow(row.use)
    }

    /// "3 uses in 2 timelines".
    static func summary(_ rows: [UsesFinder.Row]) -> String {
        let timelines = Set(rows.map(\.use.timelineID)).count
        let uses = rows.count == 1 ? "1 use" : "\(rows.count) uses"
        return rows.isEmpty ? "No uses" : "\(uses) in \(timelines == 1 ? "1 timeline" : "\(timelines) timelines")"
    }
}
