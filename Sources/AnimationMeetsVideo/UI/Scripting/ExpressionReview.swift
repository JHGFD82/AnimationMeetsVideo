import AppKit
import SwiftUI

/// Review Expressions… (Scripts menu): every expression of the project in
/// the front window, with its clip, control, state and code, in one
/// window, to read and allow them together, and to find them (see
/// docs/python-scripting.md, "Allowing code").
@MainActor
final class ExpressionReviewWindow {
    static let shared = ExpressionReviewWindow()

    private var panel: NSPanel?
    private var closeWatcher: ReviewCloseWatcher?

    func show(for session: ProjectSession) {
        let content = NSHostingView(rootView: ExpressionReview(session: session, approval: .shared))
        if let panel {
            panel.contentView = content
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Expressions"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 420, height: 240)
        panel.contentView = content
        let watcher = ReviewCloseWatcher { [weak self] in
            self?.panel = nil
            self?.closeWatcher = nil
        }
        panel.delegate = watcher
        panel.center()
        panel.setFrameAutosaveName("ExpressionReview")
        self.panel = panel
        closeWatcher = watcher
        panel.makeKeyAndOrderFront(nil)
    }
}

private final class ReviewCloseWatcher: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}

/// The list itself.
struct ExpressionReview: View {
    let session: ProjectSession
    let approval: CodeApproval

    /// One expression as the list shows it.
    struct Row: Identifiable, Equatable {
        var id: UUID
        var clip: String
        var control: String
        var state: String
        var code: String
        var isAllowed: Bool
    }

    private var rows: [Row] {
        let project = session.project
        // Read so the list follows what is allowed.
        _ = approval.allowedHashes
        return project.expressions().compactMap { found in
            guard let timeline = project.timeline(id: found.timelineID),
                  let clip = project.clipAndLayer(found.clipID, in: found.timelineID)?.clip
            else { return nil }
            let effect = found.effect
            let control = effect.keyframing?.target.map { project.name(of: $0, in: clip) } ?? "Nothing"
            let allowed = EditingProject.expressionIsAllowed(effect)
            let note = project.expressionNote(for: effect, in: clip, of: timeline)
            let state = !allowed ? "Not allowed yet" : note.map { $0.text } ?? (effect.enabled ? "Keyframes made" : "Off")
            return Row(
                id: effect.id, clip: "\(timeline.name) · \(project.clipName(found.clipID, in: found.timelineID))",
                control: control, state: state, code: effect.expression ?? "", isAllowed: allowed
            )
        }
    }

    var body: some View {
        let rows = rows
        let waiting = rows.filter { !$0.isAllowed }
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text("This project has no expressions.")
                    .font(Design.Typeface.body)
                    .foregroundStyle(Design.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    ExpressionReviewRow(row: row) { approval.allow(row.code) }
                }
                .scrollContentBackground(.hidden)
            }
            Groove()
            HStack {
                Text(verbatim: "\(rows.count) expression\(rows.count == 1 ? "" : "s"), \(waiting.count) not allowed")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                Spacer()
                Button("Allow All in This Project (\(waiting.count))") { approval.allow(waiting.map(\.code)) }
                    .disabled(waiting.isEmpty)
                    .accessibilityHint("Lets every expression listed run on this Mac")
            }
            .padding(Design.Space.step + 2)
        }
        .background(Design.Surface.floating.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
    }
}

private struct ExpressionReviewRow: View {
    let row: ExpressionReview.Row
    let onAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.clip)
                    .font(Design.Typeface.bodyEmphasis)
                    .foregroundStyle(Design.textPrimary)
                Text(verbatim: row.control)
                    .font(Design.Typeface.body)
                    .foregroundStyle(Design.textSecondary)
                Spacer()
                if !row.isAllowed {
                    Button("Allow", action: onAllow)
                        .accessibilityHint("Lets this expression's code run on this Mac")
                }
            }
            Text(verbatim: row.state)
                .font(Design.Typeface.label)
                .foregroundStyle(row.isAllowed ? Design.textSecondary : Design.statusWarning)
            Text(verbatim: row.code)
                .font(Design.Typeface.numeric)
                .foregroundStyle(Design.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Design.Surface.well.color, in: RoundedRectangle(cornerRadius: Design.Radius.control))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
