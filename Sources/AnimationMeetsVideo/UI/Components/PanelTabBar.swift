import SwiftUI

/// A row of tabs along the top of a panel, with a button that hides it.
struct PanelTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: KeyPath<Tab, String>
    let onClose: () -> Void
    let closeHelp: String

    var body: some View {
        HStack(spacing: Design.Space.close) {
            Picker("", selection: $selection) {
                ForEach(tabs) { tab in
                    Text(tab[keyPath: title]).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(closeHelp)
        }
        .padding(.horizontal, Design.Space.group)
        .padding(.vertical, Design.Space.close)
        .rail(.raised)
    }
}
