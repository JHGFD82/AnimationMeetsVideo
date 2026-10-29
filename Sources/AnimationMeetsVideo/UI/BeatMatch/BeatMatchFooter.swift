import SwiftUI

/// The ways out, pinned below the sidebar so they never scroll away:
/// Start Over, Undo and Redo, Cancel, and the step's way on, on ⌘Return.
struct BeatMatchFooter: View {
    let session: BeatMatchSession
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var confirmingStartOver = false

    var body: some View {
        HStack(spacing: Design.Space.close) {
            HStack(spacing: 0) {
                // A draft already emptied has nothing to start over, which
                // leaves Remove Beats room.
                if !session.removesBeats {
                    Button { confirmingStartOver = true } label: {
                        Image(systemName: Design.Symbol.startOver)
                    }
                    .buttonStyle(.icon)
                    .disabled(session.step == .chooseMode)
                    .help("Start over: remove every section and beat of this song")
                    .accessibilityLabel("Start over")
                }
                Button(action: session.undo) { Image(systemName: Design.Symbol.undo) }
                    .buttonStyle(.icon)
                    .disabled(!session.canUndo)
                    .help("Undo (⌘Z)")
                    .accessibilityLabel("Undo")
                Button(action: session.redo) { Image(systemName: Design.Symbol.redo) }
                    .buttonStyle(.icon)
                    .disabled(!session.canRedo)
                    .help("Redo (⇧⌘Z)")
                    .accessibilityLabel("Redo")
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            // Emptied by Start Over, the draft can take the song's beats off
            // the timeline. While drawing, the way on is to mark the beats;
            // once a section has them, they can go on the timeline. Return
            // alone fills the selected section, so these take ⌘Return.
            if session.removesBeats {
                Button("Remove Beats", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accentFill)
                    .keyboardShortcut(.return, modifiers: .command)
                    .fixedSize()
                    .help("Take this song's beats off the timeline, which goes back to the detected beats; you can undo it there (⌘↩)")
            } else if session.step == .drawSections {
                Button("Continue", action: session.finishDrawing)
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accentFill)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.map.sections.contains { $0.kind != .none })
                    .fixedSize()
                    .help("Done drawing sections: go on to mark their beats (⌘↩)")
            } else {
                Button("Confirm", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accentFill)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.canConfirm)
                    .fixedSize()
                    .help(session.canConfirm
                          ? "Put these beats on the timeline; until then nothing here changes it (⌘↩)"
                          : "Fill a section with beats first, or Start Over to remove the song's beats")
            }
        }
        .padding(.horizontal, Design.Space.rail)
        .padding(.vertical, Design.Space.step + 2)
        .background(Design.Surface.raised.color)
        .overlay(alignment: .top) { Groove() }
        .confirmationDialog("Start over?", isPresented: $confirmingStartOver) {
            Button("Start Over", role: .destructive, action: session.startOver)
        } message: {
            Text(session.original.isEmpty
                 ? "Every section and beat of this song is removed. You can undo this."
                 : "Every section and beat of this song is removed here. Remove Beats then takes them off the timeline. You can undo this.")
        }
    }
}
