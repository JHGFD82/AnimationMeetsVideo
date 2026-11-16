import SwiftUI

extension View {
    /// Runs the project's expressions that wait for a run after each edit,
    /// and when code is allowed, and calls `onArrived` when results land,
    /// for the editor to write their keyframes (see
    /// docs/python-scripting.md, "Arriving").
    func runsExpressions(of project: EditingProject, onArrived: @escaping () -> Void) -> some View {
        modifier(ExpressionFollowing(project: project, onArrived: onArrived))
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
