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

    /// How wide the control is at each size, measured once for `titles`.
    @State private var measured = Measured()
    /// How wide the bar leaves it.
    @State private var room: CGFloat?

    private struct Measured: Equatable {
        var titles: [String] = []
        var widths: [ControlSize: CGFloat] = [:]
    }

    private static var sizes: [ControlSize] { [.regular, .small, .mini] }

    var body: some View {
        // A segmented control doesn't shrink, so in a narrow panel it
        // pushed the panel's own buttons out of sight. It steps down a
        // size first, so the buttons stay. Not with `ViewThatFits`: that
        // measured all three controls in AppKit on every layout pass, which
        // each edit in the editor caused, and made dragging a value lag.
        // Each size is measured once here, and only the one shown is laid out.
        picker
            .controlSize(size)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { room = $0 }
            .background(alignment: .leading) {
                if !isMeasured { measuring }
            }
    }

    private var isMeasured: Bool {
        measured.titles == titles && measured.widths.count == Self.sizes.count
    }

    /// The largest size that fits the room, or the smallest.
    private var size: ControlSize {
        guard let room, isMeasured else { return .regular }
        return Self.sizes.first { (measured.widths[$0] ?? .infinity) <= room } ?? .mini
    }

    /// The control at each size, unseen, until each has been measured.
    private var measuring: some View {
        ZStack(alignment: .leading) {
            ForEach(Self.sizes, id: \.self) { size in
                picker
                    .controlSize(size)
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
                        if measured.titles != titles { measured = Measured(titles: titles) }
                        measured.widths[size] = width
                    }
            }
        }
        .hidden()
        .accessibilityHidden(true)
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
