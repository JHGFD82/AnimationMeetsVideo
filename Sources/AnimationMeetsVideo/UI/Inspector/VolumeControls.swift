import CoreMedia
import SwiftUI

/// A layer's volume: the stopwatch that turns keyframing on and off, the
/// level at the playhead (click to type decibels; anything at or below
/// −60 mutes), a fader, and once animated the keyframe buttons, as on a
/// transform property. Used in the timeline and the inspector.
struct VolumePropertyRow: View {
    let volume: AnimatedValue<Double>
    /// The playhead, snapped to a frame.
    let time: CMTime
    let onEdit: ((inout AnimatedValue<Double>) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    private var keyframeTimes: [CMTime] { volume.keyframes.map(\.time) }

    var body: some View {
        let level = volume.value(at: time)
        HStack(spacing: 4) {
            Button {
                onEdit { $0.setAnimated(!volume.isAnimated, at: time) }
            } label: {
                Image(systemName: volume.isAnimated ? "stopwatch.fill" : "stopwatch")
                    .foregroundStyle(volume.isAnimated ? Design.accent : Design.textTertiary)
            }
            .buttonStyle(.plain)
            .help(volume.isAnimated ? "Stop animating volume (keeps the current level)" : "Animate volume")

            Text("Volume")
                .foregroundStyle(Design.textSecondary)
                .frame(width: 50, alignment: .leading)

            NumericField(value: level, label: AudioLevel.label) { newValue in
                onEdit { $0.set(AudioLevel.clamped(newValue), at: time) }
            }
            .frame(width: 54, alignment: .leading)

            Slider(
                value: Binding(
                    get: { AudioLevel.clamped(level) },
                    set: { newValue in onEdit { $0.set((newValue * 2).rounded() / 2, at: time) } }
                ),
                in: AudioLevel.range
            )
            .controlSize(.mini)
            .frame(minWidth: 40, maxWidth: 90)
            .help("Volume from mute to +6 dB; 0 dB plays the media as it is")

            Spacer(minLength: 4)

            if volume.isAnimated {
                keyframeNavigation
            }
        }
        .font(Design.Typeface.label)
        .contextMenu {
            Button("Reset to 0 dB") { onEdit { $0 = AnimatedValue(0.0) } }
                .disabled(volume == AnimatedValue(0.0))
        }
    }

    private var keyframeNavigation: some View {
        let previous = keyframeTimes.last { $0 < time }
        let next = keyframeTimes.first { $0 > time }
        let hasKeyframe = keyframeTimes.contains(time)
        return HStack(spacing: 2) {
            Button {
                if let previous { onSeek(previous) }
            } label: {
                Image(systemName: "arrowtriangle.left.fill")
            }
            .disabled(previous == nil)
            .help("Previous keyframe")
            Button {
                onEdit { $0.toggleKeyframe(at: time) }
            } label: {
                Image(systemName: hasKeyframe ? "diamond.fill" : "diamond")
                    .foregroundStyle(hasKeyframe ? Design.keyframe : Design.textTertiary)
            }
            .help(hasKeyframe ? "Remove the keyframe at the playhead" : "Add a keyframe at the playhead")
            Button {
                if let next { onSeek(next) }
            } label: {
                Image(systemName: "arrowtriangle.right.fill")
            }
            .disabled(next == nil)
            .help("Next keyframe")
        }
        .buttonStyle(.plain)
        .font(.system(size: 8))
    }
}
