import SwiftUI

extension View {
    /// Runs the project's expressions that wait for a run after each edit,
    /// and when code is allowed, and calls `onArrived` when results land,
    /// for the editor to write their keyframes (see
    /// docs/python-scripting.md, "Arriving").
    ///
    /// With `projectState`, a held drag (`ProjectState.hold`) of something
    /// an expression reads, such as one of its inputs in the Keyframe
    /// Designer, runs it against the drag as it goes, and the editor
    /// writes what lands into the drag (`applyExpressionResultsWhileHeld`),
    /// so the viewer follows each step.
    func runsExpressions(
        of project: EditingProject, projectState: ProjectState? = nil, onArrived: @escaping () -> Void
    ) -> some View {
        modifier(ExpressionFollowing(project: project, onArrived: onArrived))
            .background(HeldExpressionFollower(projectState: projectState))
    }
}

/// Runs the expressions a held drag leaves waiting, against the drag. A
/// view of its own, as the dragged row and the viewer are: reading `held`
/// in the editor's body would run the whole editor again at each step,
/// which holding the drag is there to avoid.
private struct HeldExpressionFollower: View {
    let projectState: ProjectState?

    var body: some View {
        Color.clear
            .onChange(of: projectState?.held?.editCount) { _, _ in
                if let held = projectState?.held { ExpressionRunner.shared.runWaiting(in: held) }
            }
            .accessibilityHidden(true)
    }
}

private struct ExpressionFollowing: ViewModifier {
    let project: EditingProject
    let onArrived: () -> Void

    func body(content: Content) -> some View {
        content
            // Each edit stamps the project anew (`EditStamp`), which is
            // cheaper to compare than the project.
            .onChange(of: project.editCount, initial: true) { _, _ in ExpressionRunner.shared.runWaiting(in: project) }
            .onReceive(NotificationCenter.default.publisher(for: .expressionsAllowed)) { _ in
                ExpressionRunner.shared.runWaiting(in: project)
            }
            .onReceive(NotificationCenter.default.publisher(for: .expressionResultsChanged)) { _ in onArrived() }
    }
}
