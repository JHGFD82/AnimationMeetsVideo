import SwiftUI

/// A row of tabs along the top of a panel, with buttons of the panel's own
/// after them, and a button that hides the panel when it can be hidden.
struct PanelTabBar<Tab: Hashable & Identifiable, Accessory: View>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: KeyPath<Tab, String>
    let onClose: (() -> Void)?
    let closeHelp: String
    @ViewBuilder let accessory: () -> Accessory

    init(
        tabs: [Tab], selection: Binding<Tab>, title: KeyPath<Tab, String>,
        onClose: (() -> Void)? = nil, closeHelp: String = "",
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.tabs = tabs
        _selection = selection
        self.title = title
        self.onClose = onClose
        self.closeHelp = closeHelp
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: Design.Space.close) {
            TabSegments(tabs: tabs, titles: tabs.map { $0[keyPath: title] }, current: selection, selection: $selection)
                .equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: Design.Symbol.close)
                }
                .buttonStyle(.icon)
                .help(closeHelp)
                .accessibilityLabel(closeHelp)
            }
        }
        .padding(.horizontal, Design.Space.group)
        .padding(.vertical, Design.Space.close)
        .rail(.raised)
    }
}

extension PanelTabBar where Accessory == EmptyView {
    init(tabs: [Tab], selection: Binding<Tab>, title: KeyPath<Tab, String>, onClose: (() -> Void)? = nil, closeHelp: String = "") {
        self.init(tabs: tabs, selection: selection, title: title, onClose: onClose, closeHelp: closeHelp) { EmptyView() }
    }
}
