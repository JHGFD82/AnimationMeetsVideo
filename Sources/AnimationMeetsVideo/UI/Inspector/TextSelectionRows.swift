import CoreGraphics
import CoreMedia
import SwiftUI

/// The Character settings of a Text effect's selected letters, set apart
/// from the block as a styled run (see `TextRunStyle`). Each shows what the
/// first selected letter has at the playhead: its own setting, or the
/// block's, dimmer. Case is icon buttons, and superscript, subscript,
/// underline and strikethrough buttons that stay lit, as in the block's
/// Character group.
///
/// A number or color keeps the stopwatch and keyframe buttons, the one
/// place in the inspector that keyframes something other than an animator:
/// the effects panel doesn't show styled runs yet, so a run's keyframes
/// have no other home. Setting one starts from the block's value there. A
/// setting the letters have their own of has a button that gives them the
/// block's back.
struct TextSelectionRows: View {
    /// What the first selected letter sets apart from the block.
    let style: TextRunStyle
    /// The block's settings at the playhead.
    let block: TextOutline.Setting
    /// The block's fill and stroke colors and stroke width at the playhead.
    let blockFill: [Double]
    let blockStroke: [Double]
    let blockStrokeWidth: Double
    /// The playhead in the clip's source time, snapped to a frame.
    let playhead: PlayheadTime
    let onSeek: (CMTime) -> Void
    let onChange: ((inout TextRunStyle) -> Void) -> Void

    var body: some View {
        let letter = block.letterStyle(style.at(playhead.now))
        FontPickerRows(fontName: style.fontName ?? letter.fontName) { name in onChange { $0.fontName = name } }
        if style.fontName != nil { resetRow("Font") { $0.fontName = nil } }
        number("Size", \.size, block: block.size, unit: " px", range: 1...10_000)
        number("Tracking", \.tracking, block: block.tracking, unit: "", range: -1000...10_000)
        number("Baseline Shift", \.baselineShift, block: block.baselineShift, unit: " px", range: -100_000...100_000)
        number("Vertical Scale", \.verticalScale, block: block.verticalScale, unit: "%", range: 1...10_000)
        number("Horizontal Scale", \.horizontalScale, block: block.horizontalScale, unit: "%", range: 1...10_000)
        InspectorLabelledRow("Case") {
            PanelSegmentedPicker(
                name: "Case",
                segments: TextCase.allCases.map { PanelSegment(value: $0, glyph: .text(InspectorGlyphs.caseGlyph($0)), name: $0.name) },
                selection: letter.textCase, fills: true
            ) { picked in onChange { $0.textCase = picked } }
        }
        if style.textCase != nil { resetRow("Case") { $0.textCase = nil } }
        InspectorLabelledRow("Position") {
            HStack(spacing: Design.Space.step) {
                PanelToggleStrip(name: "Position", items: [
                    position(.superscript, glyph: "textformat.superscript"), position(.subscript, glyph: "textformat.subscript"),
                ])
                .help("Superscript or subscript: the font's own where it has them, else smaller and raised or lowered")
                PanelToggleStrip(name: "Decoration", items: [
                    PanelToggleStrip.Item(glyph: .symbol("underline"), name: "Underline", isOn: letter.underline) { on in
                        onChange { $0.underline = on }
                    },
                    PanelToggleStrip.Item(glyph: .symbol("strikethrough"), name: "Strikethrough", isOn: letter.strikethrough) { on in
                        onChange { $0.strikethrough = on }
                    },
                ])
            }
        }
        color("Fill", \.fill, block: blockFill)
        color("Stroke", \.stroke, block: blockStroke)
        number("Stroke Width", \.strokeWidth, block: blockStrokeWidth, unit: " px", range: 0...10_000)
    }

    /// A number the letters can have their own of, keyframed or not.
    private func number(
        _ name: String, _ path: WritableKeyPath<TextRunStyle, AnimatedValue<Double>?>, block: Double, unit: String,
        range: ClosedRange<Double>
    ) -> some View {
        TextRunNumberRow(
            name: name, own: style[keyPath: path], block: block, unit: unit, range: range, playhead: playhead, onSeek: onSeek,
            onChange: { change in onChange { change(&$0[keyPath: path]) } }
        )
    }

    /// Superscript or subscript as a button that stays lit while on;
    /// turning it off sets the letters back to normal.
    private func position(_ position: TextPosition, glyph: String) -> PanelToggleStrip.Item {
        PanelToggleStrip.Item(glyph: .symbol(glyph), name: position.name, isOn: style.position == position) { on in
            onChange { $0.position = on ? position : nil }
        }
    }

    /// A color the letters can have their own of, keyframed or not. It
    /// paints them whether or not the block's fill or stroke is on; a
    /// stroke color given to letters with no stroke width gives them one.
    private func color(_ name: String, _ path: WritableKeyPath<TextRunStyle, AnimatedValue<ComponentValue>?>, block: [Double]) -> some View {
        let own = style[keyPath: path]
        let value = own ?? AnimatedValue(ComponentValue(values: block))
        let time = playhead.shown(animated: value.isAnimated)
        let lowercase = name.lowercased()
        let isStroke = path == \TextRunStyle.stroke
        let strokeWidth = blockStrokeWidth
        let fallbackWidth = max(1, (block.isEmpty ? 0 : self.block.size / 30).rounded())
        return HStack(spacing: 4) {
            AnimateToggle(name: "the selected letters' \(lowercase)", isAnimated: value.isAnimated) {
                let at = playhead.current
                onChange { style in
                    var value = style[keyPath: path] ?? AnimatedValue(ComponentValue(values: block))
                    value.setAnimated(!value.isAnimated, at: at)
                    style[keyPath: path] = value
                }
            }
            Text(name)
                .foregroundStyle(Design.textSecondary)
                .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
            ColorPicker(name, selection: Binding(
                get: {
                    let c = value.value(at: time).values.map { CGFloat($0) }
                    return c.count == 4 ? CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3]) : CGColor(gray: 1, alpha: 1)
                },
                set: { picked in
                    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                          let srgb = picked.converted(to: space, intent: .defaultIntent, options: nil),
                          let parts = srgb.components, parts.count >= 4
                    else { return }
                    let values = parts.prefix(4).map { Double($0).clamped(between: 0, and: 1) }
                    let at = playhead.current
                    onChange { style in
                        var value = style[keyPath: path] ?? AnimatedValue(ComponentValue(values: block))
                        value.set(ComponentValue(values: values), at: at)
                        style[keyPath: path] = value
                        if isStroke, (style.strokeWidth?.value(at: at) ?? strokeWidth) <= 0 {
                            style.strokeWidth = AnimatedValue(fallbackWidth)
                        }
                    }
                }
            ), supportsOpacity: true)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Selected letters' \(lowercase)")
            .opacity(own != nil ? 1 : 0.6)
            Spacer(minLength: 4)
            if value.isAnimated {
                KeyframeNavigator(
                    name: "the selected letters' \(lowercase)", keyframeTimes: value.keyframes.map(\.time), time: time, onSeek: onSeek,
                    onToggle: {
                        let at = playhead.current
                        onChange { style in
                            var value = style[keyPath: path] ?? AnimatedValue(ComponentValue(values: block))
                            value.toggleKeyframe(at: at)
                            style[keyPath: path] = value
                        }
                    }
                )
            }
            if own != nil { resetButton(name) { $0[keyPath: path] = nil } }
        }
        .font(Design.Typeface.label)
    }

    /// A row giving the letters the block's `name` back.
    private func resetRow(_ name: String, clear: @escaping (inout TextRunStyle) -> Void) -> some View {
        HStack {
            Spacer()
            Button("Use the Block's \(name)") { onChange(clear) }
                .buttonStyle(.link)
                .font(Design.Typeface.label)
        }
    }

    private func resetButton(_ name: String, clear: @escaping (inout TextRunStyle) -> Void) -> some View {
        Button {
            onChange(clear)
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.icon)
        .help("Use the block's \(name.lowercased())")
        .accessibilityLabel("Use the block's \(name.lowercased()) for the selected letters")
    }
}

/// One number some letters can have their own of (`TextRunStyle`): a
/// stopwatch that animates it, its value at the playhead, dimmer while it
/// is the block's, the keyframe buttons once animated, and a button that
/// gives the letters the block's back. Setting it starts from the block's
/// value there.
struct TextRunNumberRow: View {
    let name: String
    /// The letters' own value; nil while they take the block's.
    let own: AnimatedValue<Double>?
    /// The block's value at the playhead.
    let block: Double
    let unit: String
    let range: ClosedRange<Double>
    let playhead: PlayheadTime
    let onSeek: (CMTime) -> Void
    /// Changes the letters' own value; setting nil gives them the block's.
    let onChange: ((inout AnimatedValue<Double>?) -> Void) -> Void

    var body: some View {
        let value = own ?? AnimatedValue(block)
        let time = playhead.shown(animated: value.isAnimated)
        let lowercase = name.lowercased()
        let block = block
        HStack(spacing: 4) {
            AnimateToggle(name: "the selected letters' \(lowercase)", isAnimated: value.isAnimated) {
                let at = playhead.current
                onChange { own in
                    var value = own ?? AnimatedValue(block)
                    value.setAnimated(!value.isAnimated, at: at)
                    own = value
                }
            }
            Text(name)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
                .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
            PanelField(glyph: nil, name: name) {
                NumericField(
                    value: value.value(at: time), unit: unit, dragStep: 1, dragRange: range,
                    accessibilityName: "Selected letters' \(lowercase)"
                ) { picked in
                    let at = playhead.current
                    let kept = picked.clamped(between: range.lowerBound, and: range.upperBound)
                    onChange { own in
                        var value = own ?? AnimatedValue(block)
                        value.set(kept, at: at)
                        own = value
                    }
                }
                .opacity(own != nil ? 1 : 0.6)
            }
            if value.isAnimated {
                KeyframeNavigator(
                    name: "the selected letters' \(lowercase)", keyframeTimes: value.keyframes.map(\.time), time: time, onSeek: onSeek,
                    onToggle: {
                        let at = playhead.current
                        onChange { own in
                            var value = own ?? AnimatedValue(block)
                            value.toggleKeyframe(at: at)
                            own = value
                        }
                    }
                )
            }
            if own != nil {
                Button {
                    onChange { $0 = nil }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.icon)
                .help("Use the block's \(lowercase)")
                .accessibilityLabel("Use the block's \(lowercase) for the selected letters")
            }
        }
        .font(Design.Typeface.label)
        .help(own != nil ? "The selected letters' own \(lowercase)" : "The block's \(lowercase); change it to give the selected letters their own")
    }
}
