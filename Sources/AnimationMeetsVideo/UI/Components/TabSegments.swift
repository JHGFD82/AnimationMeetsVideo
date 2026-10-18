import SwiftUI

/// A panel's tabs as a segmented control, stepping down a size when the
/// panel is too narrow for it. Redrawn only when the tabs or the chosen one
/// change (its parent marks it `.equatable()`): a segmented control is
/// costly to lay out, and the panels around it redraw on every edit.
struct TabSegments<Tab: Hashable & Identifiable>: View, Equatable {
    let tabs: [Tab]
    let titles: [String]
    /// The chosen tab when the parent drew, which the comparison uses: the
    /// binding always reads the current one.
    let current: Tab
    @Binding var selection: Tab

    var body: some View {
        // A segmented control doesn't shrink, so in a narrow panel it
        // pushed the panel's own buttons out of sight. It steps down a
        // size first, so the buttons stay.
        ViewThatFits(in: .horizontal) {
            picker
            picker.controlSize(.small)
            picker.controlSize(.mini)
        }
    }

    private var picker: some View {
        Picker("", selection: $selection) {
            ForEach(Array(zip(tabs, titles)), id: \.0.id) { tab, title in
                Text(title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    nonisolated static func == (lhs: TabSegments, rhs: TabSegments) -> Bool {
        MainActor.assumeIsolated {
            lhs.tabs == rhs.tabs && lhs.titles == rhs.titles && lhs.current == rhs.current
        }
    }
}
