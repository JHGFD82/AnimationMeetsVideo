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
        case .pan: "Pan from left to right; centered plays the media as it is"
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
    let playhead: PlayheadTime
    let onEdit: ((inout AnimatedValue<Double>) -> Void) -> Void
    let onSeek: (CMTime) -> Void
    /// Opens the property's graph editor; offered while it is animated.
    var onShowGraph: (() -> Void)?
    /// The value as a drag held to one side of the project has it, or nil
    /// when none is: dragging the number moves the slider beside it. Read
    /// as the row draws, so only these rows follow a step of a drag.
    var held: (() -> AnimatedValue<Double>?)?

    init(
        property: AudioProperty = .volume, value: AnimatedValue<Double>, playhead: PlayheadTime,
        onEdit: @escaping ((inout AnimatedValue<Double>) -> Void) -> Void, onSeek: @escaping (CMTime) -> Void,
        onShowGraph: (() -> Void)? = nil, held: (() -> AnimatedValue<Double>?)? = nil
    ) {
        self.property = property
        self.value = value
        self.playhead = playhead
        self.onEdit = onEdit
        self.onSeek = onSeek
        self.onShowGraph = onShowGraph
        self.held = held
    }

    /// A row with the playhead at `time`.
    init(
        property: AudioProperty = .volume, value: AnimatedValue<Double>, time: CMTime,
        onEdit: @escaping ((inout AnimatedValue<Double>) -> Void) -> Void, onSeek: @escaping (CMTime) -> Void,
        onShowGraph: (() -> Void)? = nil
    ) {
        self.init(
            property: property, value: value, playhead: PlayheadTime(fixed: time), onEdit: onEdit, onSeek: onSeek,
            onShowGraph: onShowGraph
        )
    }


    // The actions find the playhead when they run (see `PlayheadTime`).

    /// Turns keyframing on, with a keyframe where the playhead is, or off.
    func toggleAnimated() {
        let at = playhead.now
        onEdit { $0.setAnimated(!value.isAnimated, at: at) }
    }

    /// Sets the value at the playhead, or all of it while it is fixed.
    func setValue(_ newValue: Double) {
        let at = playhead.now
        onEdit { $0.set(newValue, at: at) }
    }

    /// Adds a keyframe where the playhead is, or removes the one there.
    func toggleKeyframe() {
        let at = playhead.now
        onEdit { $0.toggleKeyframe(at: at) }
    }
    private var lowercaseName: String { property.name.lowercased() }

    var body: some View {
        let value = held?() ?? self.value
        let time = playhead.shown(animated: value.isAnimated)
        let current = value.value(at: time)
        HStack(spacing: 4) {
            AnimateToggle(name: lowercaseName, isAnimated: value.isAnimated, onToggle: toggleAnimated)

            Text(property.name)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 50, alignment: .leading)

            NumericField(
                value: current, label: property.label, dragStep: 1, dragRange: property.range,
                accessibilityName: "\(property.name) \(property == .volume ? "level" : "position")"
            ) { newValue in
                setValue(property.clamped(newValue))
            }
            .frame(width: 54, alignment: .leading)

            Slider(
                value: Binding(
                    get: { property.clamped(current) },
                    set: { newValue in setValue(property.rounded(newValue)) }
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
                KeyframeNavigator(name: lowercaseName, keyframeTimes: value.keyframes.map(\.time), time: time, onSeek: onSeek, onToggle: toggleKeyframe)
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
