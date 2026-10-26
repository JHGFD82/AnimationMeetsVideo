import CoreGraphics
import SwiftUI

/// The Character settings of a Text effect's selected letters, set apart
/// from the block as a styled run (see `TextStyle`). Each shows what the
/// first selected letter has: its own setting, or the block's at the
/// playhead, dimmer. A setting the letters have their own of has a button
/// that gives them the block's back. These hold still: keyframes are the
/// block's.
struct TextSelectionRows: View {
    /// What the first selected letter sets apart from the block.
    let style: TextStyle
    /// How it is set, the block's settings filling in.
    let letter: TextLayout.LetterStyle
    /// The block's fill and stroke colors at the playhead.
    let blockFill: [Double]
    let blockStroke: [Double]
    let onChange: ((inout TextStyle) -> Void) -> Void

    var body: some View {
        FontPickerRows(fontName: style.fontName ?? letter.fontName) { name in onChange { $0.fontName = name } }
        if style.fontName != nil { resetRow("Font") { $0.fontName = nil } }
        number("Size", letter.size, unit: " px", range: 1...10_000, isOwn: style.size != nil) { $0.size = $1 }
        number("Tracking", letter.tracking, unit: "", range: -1000...10_000, isOwn: style.tracking != nil) { $0.tracking = $1 }
        number("Baseline Shift", letter.baselineShift, unit: " px", range: -100_000...100_000, isOwn: style.baselineShift != nil) {
            $0.baselineShift = $1
        }
        number("Vertical Scale", letter.verticalScale, unit: "%", range: 1...10_000, isOwn: style.verticalScale != nil) {
            $0.verticalScale = $1
        }
        number("Horizontal Scale", letter.horizontalScale, unit: "%", range: 1...10_000, isOwn: style.horizontalScale != nil) {
            $0.horizontalScale = $1
        }
        InspectorLabelledRow("Case") {
            Picker("Case", selection: Binding(get: { letter.textCase }, set: { picked in onChange { $0.textCase = picked } })) {
                ForEach(TextCase.allCases) { Text($0.name).tag($0) }
            }
        }
        if style.textCase != nil { resetRow("Case") { $0.textCase = nil } }
        InspectorLabelledRow("Position") {
            Picker("Position", selection: Binding(
                get: { style.position ?? .normal },
                set: { picked in onChange { $0.position = picked == .normal ? nil : picked } }
            )) {
                ForEach(TextPosition.allCases) { Text($0.name).tag($0) }
            }
        }
        .help("Superscript or subscript: the font's own where it has them, else smaller and raised or lowered")
        checkbox("Underline", letter.underline) { $0.underline = $1 }
        checkbox("Strikethrough", letter.strikethrough) { $0.strikethrough = $1 }
        color("Fill", style.fill ?? blockFill, isOwn: style.fill != nil) { $0.fill = $1 }
        color("Stroke", style.stroke ?? blockStroke, isOwn: style.stroke != nil) { $0.stroke = $1 }
    }

    /// A number the letters can have their own of.
    private func number(
        _ name: String, _ value: Double, unit: String, range: ClosedRange<Double>, isOwn: Bool,
        set: @escaping (inout TextStyle, Double?) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 18, height: 1)
            Text(name)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
                .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
            NumericField(value: value, unit: unit, dragStep: 1, dragRange: range, accessibilityName: "Selected letters' \(name.lowercased())") { picked in
                onChange { set(&$0, picked.clamped(between: range.lowerBound, and: range.upperBound)) }
            }
            .opacity(isOwn ? 1 : 0.6)
            Spacer(minLength: 4)
            if isOwn { resetButton(name) { set(&$0, nil) } }
        }
        .font(Design.Typeface.label)
        .help(isOwn ? "The selected letters' own \(name.lowercased())" : "The block's \(name.lowercased()); change it to give the selected letters their own")
    }

    private func checkbox(_ name: String, _ isOn: Bool, set: @escaping (inout TextStyle, Bool) -> Void) -> some View {
        Toggle(name, isOn: Binding(get: { isOn }, set: { on in onChange { set(&$0, on) } }))
            .toggleStyle(.checkbox)
            .font(Design.Typeface.label)
            .foregroundStyle(Design.textSecondary)
            .padding(.leading, 22)
    }

    /// A color the letters can have their own of, for the block's fill or
    /// stroke while it has one.
    private func color(_ name: String, _ rgba: [Double], isOwn: Bool, set: @escaping (inout TextStyle, [Double]?) -> Void) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 18, height: 1)
            Text(name)
                .foregroundStyle(Design.textSecondary)
                .frame(width: InspectorControlRow.nameWidth, alignment: .leading)
            ColorPicker(name, selection: Binding(
                get: {
                    let c = rgba.map { CGFloat($0) }
                    return c.count == 4 ? CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3]) : CGColor(gray: 1, alpha: 1)
                },
                set: { picked in
                    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                          let srgb = picked.converted(to: space, intent: .defaultIntent, options: nil),
                          let parts = srgb.components, parts.count >= 4
                    else { return }
                    let values = parts.prefix(4).map { Double($0).clamped(between: 0, and: 1) }
                    onChange { set(&$0, values) }
                }
            ), supportsOpacity: true)
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Selected letters' \(name.lowercased())")
            Spacer(minLength: 4)
            if isOwn { resetButton(name) { set(&$0, nil) } }
        }
        .font(Design.Typeface.label)
    }

    /// A row giving the letters the block's `name` back.
    private func resetRow(_ name: String, clear: @escaping (inout TextStyle) -> Void) -> some View {
        HStack {
            Spacer()
            Button("Use the Block's \(name)") { onChange(clear) }
                .buttonStyle(.link)
                .font(Design.Typeface.label)
        }
    }

    private func resetButton(_ name: String, clear: @escaping (inout TextStyle) -> Void) -> some View {
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
