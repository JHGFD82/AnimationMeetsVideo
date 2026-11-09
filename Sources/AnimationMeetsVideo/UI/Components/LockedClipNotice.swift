import SwiftUI

/// Says, over a panel's controls for a clip, that the clip is open in the
/// Motion Designer, which alone may change it meanwhile; the controls
/// under it are disabled (`lockedForMotionDesigner`).
struct LockedClipNotice: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text("Open in the Motion Designer")
                    .font(Design.Typeface.bodyEmphasis)
                    .foregroundStyle(Design.textPrimary)
                Text("Close the designer to edit this clip.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
            }
        } icon: {
            Image(systemName: "lock.fill")
                .foregroundStyle(Design.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Space.group)
        .padding(.vertical, Design.Space.step)
        .rail(.raised)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A panel's controls for a clip, disabled under a `LockedClipNotice`
    /// while the clip is open in the Motion Designer.
    func lockedForMotionDesigner(_ locked: Bool) -> some View {
        VStack(spacing: 0) {
            if locked { LockedClipNotice() }
            disabled(locked)
        }
    }
}
