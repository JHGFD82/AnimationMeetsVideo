import CoreMedia
import SwiftUI

/// A small glyph in a target big enough to hit: property rows pack their
/// buttons tight, and an 8-point triangle alone is hard to click.
struct PropertyRowIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 10))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
    }
}

/// An animated property's keyframe buttons: go to the previous keyframe,
/// add or remove one at the playhead, go to the next. Shared by every
/// property row (transform and volume).
struct KeyframeNavigator: View {
    /// The property's name, for help and VoiceOver: "position", "volume".
    let name: String
    let keyframeTimes: [CMTime]
    /// The playhead, snapped to a frame.
    let time: CMTime
    let onSeek: (CMTime) -> Void
    /// Adds a keyframe at `time`, or removes the one there.
    let onToggle: () -> Void

    var body: some View {
        let previous = keyframeTimes.last { $0 < time }
        let next = keyframeTimes.first { $0 > time }
        let hasKeyframe = keyframeTimes.contains(time)
        HStack(spacing: 0) {
            Button {
                if let previous { onSeek(previous) }
            } label: {
                PropertyRowIcon(systemName: "arrowtriangle.left.fill")
            }
            .disabled(previous == nil)
            .help("Previous keyframe")
            .accessibilityLabel("Previous \(name) keyframe")

            Button(action: onToggle) {
                PropertyRowIcon(systemName: hasKeyframe ? "diamond.fill" : "diamond")
                    .foregroundStyle(hasKeyframe ? Design.keyframe : Design.textTertiary)
            }
            .help(hasKeyframe ? "Remove the keyframe at the playhead" : "Add a keyframe at the playhead")
            .accessibilityLabel(hasKeyframe ? "Remove \(name) keyframe at the playhead" : "Add \(name) keyframe at the playhead")

            Button {
                if let next { onSeek(next) }
            } label: {
                PropertyRowIcon(systemName: "arrowtriangle.right.fill")
            }
            .disabled(next == nil)
            .help("Next keyframe")
            .accessibilityLabel("Next \(name) keyframe")
        }
        .buttonStyle(.plain)
    }
}

/// Opens a property's graph editor.
struct GraphEditorButton: View {
    /// The property's name, as in `KeyframeNavigator`.
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PropertyRowIcon(systemName: "chart.xyaxis.line")
                .foregroundStyle(Design.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Open \(name)'s graph editor to shape its eases")
        .accessibilityLabel("Open \(name) graph editor")
    }
}

/// The stopwatch that turns a property's keyframing on and off.
struct AnimateToggle: View {
    /// The property's name, as in `KeyframeNavigator`.
    let name: String
    let isAnimated: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            PropertyRowIcon(systemName: isAnimated ? "stopwatch.fill" : "stopwatch")
                .foregroundStyle(isAnimated ? Design.accent : Design.textTertiary)
        }
        .buttonStyle(.plain)
        .help(isAnimated ? "Stop animating \(name) (keeps the current value)" : "Animate \(name)")
        .accessibilityLabel("Animate \(name)")
        .accessibilityValue(isAnimated ? "On" : "Off")
    }
}
