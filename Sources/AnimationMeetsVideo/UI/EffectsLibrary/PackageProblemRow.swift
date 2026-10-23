import AppKit
import SwiftUI

/// An effect package the library can't offer, or whose look can't draw,
/// and why (see docs/effect-packages.md, "Where packages come from"), as
/// the Presets tab lists a preset it can't read.
struct PackageProblemRow: View {
    /// The package's name, or its folder's.
    let name: String
    let message: String
    /// The package's folder, shown in Finder from the menu.
    let url: URL

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(message)
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Design.statusWarning)
        }
        .font(Design.Typeface.label)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("This effect package can't be used. Fix or remove its folder, then open the app again.")
        .contextMenu {
            Button("Show in Finder") { showInFinder() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(name) can't be used")
        .accessibilityValue(message)
        .accessibilityAction(named: "Show in Finder") { showInFinder() }
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
