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
    /// Opens the volume's graph editor; offered while it is animated.
    var onShowGraph: (() -> Void)?

    private var keyframeTimes: [CMTime] { volume.keyframes.map(\.time) }

    var body: some View {
        let level = volume.value(at: time)
        HStack(spacing: 4) {
            AnimateToggle(name: "volume", isAnimated: volume.isAnimated) {
                onEdit { $0.setAnimated(!volume.isAnimated, at: time) }
            }

            Text("Volume")
                .foregroundStyle(Design.textSecondary)
                .frame(width: 50, alignment: .leading)

            NumericField(value: level, label: AudioLevel.label, accessibilityName: "Volume level") { newValue in
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
            .accessibilityLabel("Volume")
            .accessibilityValue(AudioLevel.label(level))

            Spacer(minLength: 4)

            if volume.isAnimated {
                KeyframeNavigator(name: "volume", keyframeTimes: keyframeTimes, time: time, onSeek: onSeek) {
                    onEdit { $0.toggleKeyframe(at: time) }
                }
                if let onShowGraph { GraphEditorButton(name: "volume", action: onShowGraph) }
            }
        }
        .font(Design.Typeface.label)
        .contextMenu {
            Button("Reset to 0 dB") { onEdit { $0 = AnimatedValue(0.0) } }
                .disabled(volume == AnimatedValue(0.0))
        }
    }
}
