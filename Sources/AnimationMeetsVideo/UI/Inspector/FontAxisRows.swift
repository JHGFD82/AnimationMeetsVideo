import CoreMedia
import SwiftUI

/// A variable font's axes (weight, width, optical size) for a Text effect,
/// a row each, laid out like the inspector's control rows: a stopwatch
/// that animates the axis, its value at the playhead, and once animated
/// the keyframe buttons. The values are the effect's `TextContent`
/// variations, kept by axis tag, so they last through a change of font
/// to one with the same axes. A font that doesn't vary shows none.
struct FontAxisRows: View {
    let fontName: String
    let content: TextContent
    /// The playhead in the clip's source time, snapped to a frame.
    let playhead: PlayheadTime
    let onChange: ((inout TextContent) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    var body: some View {
        ForEach(FontCatalog.axes(of: fontName)) { axis in
            row(axis)
        }
    }

    private func row(_ axis: FontCatalog.Axis) -> some View {
        let value = content.variations.first { $0.axis == axis.tag }?.value ?? AnimatedValue(axis.defaultValue)
        let time = playhead.shown(animated: value.isAnimated)
        let name = axis.name.lowercased()
        func change(_ edit: @escaping (inout AnimatedValue<Double>) -> Void) {
            onChange { $0.changeVariation(axis.tag, initial: axis.defaultValue, edit) }
        }
        return HStack(spacing: 4) {
            AnimateToggle(name: name, isAnimated: value.isAnimated) {
                let at = playhead.current
                change { $0.setAnimated(!$0.isAnimated, at: at) }
            }
            Text(axis.name)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
                .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
            NumericField(
                value: value.value(at: time), fractionDigits: axis.maximum - axis.minimum < 10 ? 2 : 0,
                dragStep: (axis.maximum - axis.minimum) / 200, dragRange: axis.minimum...axis.maximum,
                accessibilityName: "Font \(name)"
            ) { picked in
                let at = playhead.current
                let kept = picked.clamped(between: axis.minimum, and: axis.maximum)
                change { $0.set(kept, at: at) }
            }
            Spacer(minLength: 4)
            if value.isAnimated {
                KeyframeNavigator(
                    name: name, keyframeTimes: value.keyframes.map(\.time), time: time, onSeek: onSeek,
                    onToggle: {
                        let at = playhead.current
                        change { $0.toggleKeyframe(at: at) }
                    }
                )
            }
        }
        .font(Design.Typeface.label)
        .help("The font's \(name), from \(NumericExpression.format(axis.minimum)) to \(NumericExpression.format(axis.maximum))")
    }
}
