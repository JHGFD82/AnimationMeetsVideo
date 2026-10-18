import CoreMedia
import SwiftUI

/// The sound properties a clip or a Sound or Music layer has.
enum AudioProperty {
    /// Decibels, from mute to +6 (see `AudioLevel`).
    case volume
    /// −100 (left) to 100 (right) (see `AudioPan`).
    case pan

    var name: String {
        switch self {
        case .volume: "Volume"
        case .pan: "Pan"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .volume: AudioLevel.range
        case .pan: AudioPan.range
        }
    }

    func clamped(_ value: Double) -> Double {
        switch self {
        case .volume: AudioLevel.clamped(value)
        case .pan: AudioPan.clamped(value)
        }
    }

    func label(_ value: Double) -> String {
        switch self {
        case .volume: AudioLevel.label(value)
        case .pan: AudioPan.label(value)
        }
    }

    /// What the slider rounds to: half a decibel, or a whole step of pan.
    func rounded(_ value: Double) -> Double {
        switch self {
        case .volume: (value * 2).rounded() / 2
        case .pan: value.rounded()
        }
    }

    var help: String {
        switch self {
        case .volume: "Volume from mute to +6 dB; 0 dB plays the media as it is"
        case .pan: "Pan from left to right; centered plays the media as it is. Mono sound stays centered"
        }
    }

    var resetTitle: String {
        switch self {
        case .volume: "Reset to 0 dB"
        case .pan: "Reset to Center"
        }
    }
}

/// A clip's or layer's volume or pan: the stopwatch that turns keyframing
/// on and off, the value at the playhead (click to type it; arithmetic
/// works), a slider, and once animated the keyframe buttons, as on a
/// transform property. Used in the timeline, the effects panel and the
/// inspector.
struct AudioPropertyRow: View {
    var property: AudioProperty = .volume
    let value: AnimatedValue<Double>
    /// The playhead, snapped to a frame.
    let time: CMTime
    let onEdit: ((inout AnimatedValue<Double>) -> Void) -> Void
    let onSeek: (CMTime) -> Void
    /// Opens the property's graph editor; offered while it is animated.
    var onShowGraph: (() -> Void)?

    private var keyframeTimes: [CMTime] { value.keyframes.map(\.time) }
    private var lowercaseName: String { property.name.lowercased() }

    var body: some View {
        let current = value.value(at: time)
        HStack(spacing: 4) {
            AnimateToggle(name: lowercaseName, isAnimated: value.isAnimated) {
                onEdit { $0.setAnimated(!value.isAnimated, at: time) }
            }

            Text(property.name)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 50, alignment: .leading)

            NumericField(
                value: current, label: property.label, dragStep: 1, dragRange: property.range,
                accessibilityName: "\(property.name) \(property == .volume ? "level" : "position")"
            ) { newValue in
                onEdit { $0.set(property.clamped(newValue), at: time) }
            }
            .frame(width: 54, alignment: .leading)

            Slider(
                value: Binding(
                    get: { property.clamped(current) },
                    set: { newValue in onEdit { $0.set(property.rounded(newValue), at: time) } }
                ),
                in: property.range
            )
            .controlSize(.mini)
            .frame(minWidth: 40, maxWidth: 90)
            .help(property.help)
            .accessibilityLabel(property.name)
            .accessibilityValue(property.label(current))

            Spacer(minLength: 4)

            if value.isAnimated {
                KeyframeNavigator(name: lowercaseName, keyframeTimes: keyframeTimes, time: time, onSeek: onSeek) {
                    onEdit { $0.toggleKeyframe(at: time) }
                }
                if let onShowGraph { GraphEditorButton(name: lowercaseName, action: onShowGraph) }
            }
        }
        .font(Design.Typeface.label)
        .contextMenu {
            Button(property.resetTitle) { onEdit { $0 = AnimatedValue(0.0) } }
                .disabled(value == AnimatedValue(0.0))
        }
    }
}
