import SwiftUI

/// The ⋯ button that opens a row's menu: an effect's, a control's, a
/// layer's sound effect's. An 18-point target, so it is as easy to hit in
/// every list.
struct RowMenu<Content: View>: View {
    /// What the row is, for the help and VoiceOver: "Blur".
    let name: String
    /// Help that says more than "Actions for …", when the menu is short
    /// enough to list.
    let help: String?
    @ViewBuilder let content: () -> Content

    init(name: String, help: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.name = name
        self.help = help
        self.content = content
    }

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help ?? "Actions for \(name)")
        .accessibilityLabel("\(name) options")
    }
}
