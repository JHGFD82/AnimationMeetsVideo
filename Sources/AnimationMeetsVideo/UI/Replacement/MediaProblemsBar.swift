import SwiftUI

/// Over the Clips list while media files are missing or changed on disk:
/// how many, and a button to locate them or check their sync. The alert
/// that first reports them can be put off with Later; this stays until
/// they are dealt with, so nothing depends on finding each file's menu.
struct MediaProblemsBar: View {
    let controller: MediaReplacementController
    let context: MediaReplacementController.Context

    var body: some View {
        let missing = controller.missingMedia.count
        let changed = controller.changedMedia.count
        if missing > 0 || changed > 0 {
            VStack(alignment: .leading, spacing: Design.Space.tight) {
                if missing > 0 {
                    row(
                        symbol: "questionmark.folder",
                        text: missing == 1 ? "1 file missing" : "\(missing) files missing",
                        action: .locateMissing
                    )
                }
                if changed > 0 {
                    row(
                        symbol: "arrow.triangle.2.circlepath",
                        text: changed == 1 ? "1 file changed on disk" : "\(changed) files changed on disk",
                        action: .checkSync
                    )
                }
            }
            .padding(.horizontal, Design.Space.step)
            .padding(.vertical, Design.Space.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.statusWarning.opacity(0.14))
            .overlay(alignment: .bottom) { Groove() }
        }
    }

    private func row(symbol: String, text: String, action: MediaReplacementController.NoticeAction) -> some View {
        HStack(spacing: Design.Space.close) {
            Image(systemName: symbol)
                .foregroundStyle(Design.statusWarning)
                .accessibilityHidden(true)
            Text(text)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textPrimary)
            Spacer(minLength: Design.Space.close)
            Button(action.title) { controller.perform(action, context: context) }
                .controlSize(.small)
                .disabled(controller.session != nil)
        }
        // The button stays an element of its own, read after the count, so
        // VoiceOver presses it as a button and finds it dimmed while a
        // replacement is under way; folded into the row, its action would
        // have run regardless.
        .accessibilityElement(children: .contain)
    }
}
