import AppKit
import SwiftUI

/// An effect package from outside the app that waits for the person's
/// approval before its kernel is compiled (see docs/effect-packages.md,
/// "Safety"): its name, where it came from, and the button that asks.
struct PackageApprovalRow: View {
    let package: EffectPackage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: Design.Symbol.awaitingApproval)
                .foregroundStyle(Design.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.name)
                Text("Not compiled until approved: \(EffectPackageOrigin.describe(package.url)).")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Approve\u{2026}") { NewEffectPackagePrompt.shared.askApproval(for: package) }
                .controlSize(.small)
                .accessibilityLabel("Approve \(package.name)")
        }
        .font(Design.Typeface.label)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([package.url]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(package.name), waiting for approval to run")
        .accessibilityAction(named: "Approve") { NewEffectPackagePrompt.shared.askApproval(for: package) }
        .accessibilityAction(named: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([package.url]) }
    }
}
