import AppKit

/// What an edit by hand to the keyframes of a control a method drives does
/// (`ProjectState.Refusal.drivenKeyframes`): nothing changes, and an alert
/// says why, with a button that bakes them (see docs/keyframing-effects.md,
/// "Editing by hand"). The method starts from the control as it was before
/// it first wrote, so the change would be gone the next time it made its
/// keyframes; saying so here is clearer than losing it later.
@MainActor
enum DrivenKeyframesWarning {
    /// One alert at a time: a drag is refused at every step and again at
    /// its release, and those say nothing more.
    private static var isPending = false

    /// Shows the alert for `edit`. `onBake` bakes the method's keyframes.
    static func show(_ edit: DrivenKeyframesEdit, onBake: @escaping @MainActor @Sendable () -> Void) {
        guard !isPending else { return }
        isPending = true
        present(edit, onBake: onBake)
    }

    static func title(for edit: DrivenKeyframesEdit) -> String {
        "\(edit.methodName) makes the keyframes of \(edit.controlName)"
    }

    static func explanation(for edit: DrivenKeyframesEdit) -> String {
        "A change made by hand would be lost the next time \(edit.methodName) makes them again. "
            + "Bake the keyframes to keep them as plain keyframes you can edit, "
            + "or choose None in the Keyframe Designer to put the control back as it was."
    }

    /// After the event that was refused, and once the mouse is up: the
    /// write is refused inside a control's action or a drag's step, and an
    /// alert opened there would run its events inside it and take the
    /// drag's mouse-up.
    private static func present(_ edit: DrivenKeyframesEdit, onBake: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else {
                    present(edit, onBake: onBake)
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = title(for: edit)
                alert.informativeText = explanation(for: edit)
                alert.addButton(withTitle: "Bake Keyframes")
                alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                isPending = false
                if response == .alertFirstButtonReturn { onBake() }
            }
        }
    }
}
