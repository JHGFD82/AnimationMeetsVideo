import SwiftUI

/// The sheet over a window while a script runs on its project: it names
/// the script, counts the seconds, and has Stop. Being a sheet, it keeps
/// the window from the pointer meanwhile (`WindowInputBlock`), so nothing
/// is edited under a run that will write the project when it ends.
struct ScriptRunSheet: View {
    let run: ScriptRunner.Run
    let onStop: () -> Void

    var body: some View {
        SheetFrame(title: "Running \u{201C}\(run.name)\u{201D}", subtitle: "Its changes are one undo step, made when it ends. A script that raises changes nothing.") {
            HStack(spacing: Design.Space.step) {
                ProgressView().controlSize(.small)
                SwiftUI.TimelineView(.periodic(from: run.started, by: 1)) { context in
                    let seconds = max(Int(context.date.timeIntervalSince(run.started)), 0)
                    Text(verbatim: seconds == 1 ? "1 second" : "\(seconds) seconds")
                        .font(Design.Typeface.numeric)
                        .foregroundStyle(Design.textSecondary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        } actions: {
            Button("Stop", action: onStop)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Stops the script; it changes nothing")
            // Command-Period too, as Stop answers to in a Mac app. Not
            // `.hidden()`, whose key equivalents don't fire.
            Button("Stop") { onStop() }
                .keyboardShortcut(".", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
