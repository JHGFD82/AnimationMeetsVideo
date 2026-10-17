import SwiftUI

extension Notification.Name {
    /// Asks the effects panel to select an effect (the ID is the
    /// notification's object), once the clip it is on is selected.
    static let revealEffect = Notification.Name("AnimationMeetsVideo.revealEffect")
}

/// Every unresolved paste change in what an export draws, each with a button
/// to go to it and one to mark it resolved, and **Accept All**. See
/// docs/effects.md, "Paste changes".
struct PasteChangesSheet: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    /// Whether the person asked to export, so accepting goes on to do it.
    let isBlockingExport: Bool
    let onGoTo: (PasteChangeEntry) -> Void
    let onAcceptAll: () -> Void
    let onClose: () -> Void

    private var entries: [PasteChangeEntry] { project.unresolvedPasteChanges(drawnBy: timelineID) }

    var body: some View {
        SheetFrame(
            title: "Paste Changes",
            subtitle: isBlockingExport
                ? "Some pasted effects didn't come over exactly. Resolve each one, or accept them all, to export."
                : "Some pasted effects didn't come over exactly. They have to be resolved, or accepted, before this timeline can be exported.",
            width: Design.SheetWidth.wide
        ) {
            if entries.isEmpty {
                Text("Nothing is left to resolve.")
                    .font(Design.Typeface.body)
                    .foregroundStyle(Design.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.step) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        } actions: {
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(isBlockingExport ? "Accept All and Export" : "Accept All", action: onAcceptAll)
                .keyboardShortcut(.defaultAction)
                .disabled(entries.isEmpty)
        }
    }

    private func row(_ entry: PasteChangeEntry) -> some View {
        HStack(alignment: .top, spacing: Design.Space.group) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Design.statusWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.timelineName) · \(entry.clipName) · \(entry.effectName)")
                    .font(Design.Typeface.bodyEmphasis)
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.change.message)
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Design.Space.step)
            Button("Go To") { onGoTo(entry) }
            Button("Mark Resolved") {
                project.resolvePasteChange(entry.change, ofEffect: entry.effectID, onClip: entry.clipID, in: entry.timelineID)
            }
        }
    }
}
