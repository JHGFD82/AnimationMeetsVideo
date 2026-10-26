import CoreMedia
import SwiftUI

/// A variable font's axes (weight, width, optical size) for a Text effect,
/// a field each, two to a row like the Character panel's numbers. The
/// values are the effect's `TextContent` variations, kept by axis tag, so
/// they last through a change of font to one with the same axes. A font
/// that doesn't vary shows none.
///
/// Set outright here; an axis animated in the effects panel shows its
/// value at the playhead read-only, as the controls do.
struct FontAxisRows: View {
    let fontName: String
    let content: TextContent
    /// The playhead in the clip's source time, snapped to a frame.
    let playhead: PlayheadTime
    let onChange: ((inout TextContent) -> Void) -> Void

    var body: some View {
        let axes = FontCatalog.axes(of: fontName)
        if !axes.isEmpty {
            Grid(horizontalSpacing: Design.Space.step, verticalSpacing: Design.Space.close) {
                ForEach(Array(stride(from: 0, to: axes.count, by: 2)), id: \.self) { start in
                    GridRow {
                        field(axes[start])
                        if start + 1 < axes.count { field(axes[start + 1]) } else { Color.clear.gridCellUnsizedAxes(.vertical) }
                    }
                }
            }
        }
    }

    private func field(_ axis: FontCatalog.Axis) -> some View {
        let value = content.variations.first { $0.axis == axis.tag }?.value ?? AnimatedValue(axis.defaultValue)
        let time = playhead.shown(animated: value.isAnimated)
        let name = axis.name.lowercased()
        return PanelField(glyph: nil, name: "Font \(name)") {
            HStack(spacing: 4) {
                Text(axis.name)
                    .foregroundStyle(Design.textTertiary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
                NumericField(
                    value: value.value(at: time), fractionDigits: axis.maximum - axis.minimum < 10 ? 2 : 0,
                    dragStep: (axis.maximum - axis.minimum) / 200, dragRange: axis.minimum...axis.maximum,
                    accessibilityName: value.isAnimated ? "Font \(name), animated" : "Font \(name)"
                ) { picked in
                    let kept = picked.clamped(between: axis.minimum, and: axis.maximum)
                    onChange { $0.changeVariation(axis.tag, initial: axis.defaultValue) { $0.set(kept, at: .zero) } }
                }
                .disabled(value.isAnimated)
                .opacity(value.isAnimated ? 0.7 : 1)
            }
        } accessory: {
            if value.isAnimated { AnimatedInEffectsBadge(name: "font \(name)") }
        }
        .font(Design.Typeface.label)
        .help("The font's \(name), from \(NumericExpression.format(axis.minimum)) to \(NumericExpression.format(axis.maximum))")
    }
}
