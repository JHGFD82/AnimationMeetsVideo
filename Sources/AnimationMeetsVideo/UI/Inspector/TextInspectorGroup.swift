import CoreMedia
import SwiftUI

/// A Text effect's settings in the inspector (see docs/graphic-layers.md,
/// "Text"): its words, typed in place, its font's family and style, and
/// its size, alignment, tracking, line height and wrap width. Those are
/// the effect's own controls, so a number set here at the playhead is a
/// keyframe there once it is animated, as in the effects panel; its fill
/// and stroke stay in the effects panel with the other shapes'.
struct TextInspectorGroup: View {
    let effect: Effect
    /// The group's title: "Text", or the effect's name when the clip has
    /// more than one.
    let title: String
    /// The playhead in the clip's source time, snapped to a frame.
    let playhead: PlayheadTime
    let onEdit: ((inout Effect) -> Void) -> Void
    /// Moves the playhead to a time in the clip's source time.
    let onSeek: (CMTime) -> Void

    /// Read once: listing the Mac's fonts takes a moment.
    private static let families = FontCatalog.families()

    private var content: TextContent { effect.text ?? TextContent() }

    var body: some View {
        InspectorGroup(title) {
            TextEditor(text: Binding(
                get: { content.string },
                set: { string in onEdit { $0.text = TextContent(string: string, fontName: $0.text?.fontName ?? TextContent.defaultFontName) } }
            ))
            .font(Design.Typeface.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: 56, maxHeight: 120)
            .background(Design.Surface.base.color, in: RoundedRectangle(cornerRadius: Design.Radius.control))
            .accessibilityLabel("Text")
            .help("The words the layer draws; Return starts a new line")

            fontPickers
            if !FontCatalog.isInstalled(content.fontName) {
                Text("\u{201C}\(content.fontName)\u{201D} isn't installed on this Mac, so it draws with \(FontCatalog.familyAndStyle(of: content.fontName).family) until it is.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            numberRow(.fontSize)
            alignmentRow
            numberRow(.tracking)
            numberRow(.lineHeight)
            numberRow(.wrapWidth)
        }
    }

    // MARK: Font

    @ViewBuilder
    private var fontPickers: some View {
        let shown = FontCatalog.familyAndStyle(of: content.fontName)
        let styles = FontCatalog.styles(ofFamily: shown.family)
        labelled("Font") {
            Picker("Font", selection: Binding(
                get: { shown.family },
                set: { family in
                    guard let name = FontCatalog.fontName(inFamily: family, like: content.fontName) else { return }
                    setFont(name)
                }
            )) {
                ForEach(Self.families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 170)
        }
        labelled("Style") {
            Picker("Style", selection: Binding(get: { content.fontName }, set: setFont)) {
                // A missing font is kept, under its own name, until another
                // is picked.
                if !styles.contains(where: { $0.fontName == content.fontName }) {
                    Text(content.fontName).tag(content.fontName)
                }
                ForEach(styles) { Text($0.name).tag($0.fontName) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 170)
        }
    }

    private func setFont(_ name: String) {
        onEdit { $0.text = TextContent(string: $0.text?.string ?? "", fontName: name) }
    }

    // MARK: Controls

    /// The alignment choice, as four icons. Hidden once the control is
    /// deleted in the effects panel.
    @ViewBuilder
    private var alignmentRow: some View {
        if let control = effect.control(.textAlign) {
            labelled("Alignment") {
                Picker("Alignment", selection: Binding(
                    get: { control.choice.flatMap(TextAlign.init(rawValue:)) ?? .center },
                    set: { align in onEdit { $0.changeControl(.textAlign) { $0.choice = align.rawValue } } }
                )) {
                    ForEach(TextAlign.allCases) { align in
                        Image(systemName: align.systemImage)
                            .accessibilityLabel(align.name)
                            .help(align.name)
                            .tag(align)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(!control.enabled)
            }
        }
    }

    /// One number of the effect's: a stopwatch that animates it, its value
    /// at the playhead (click to type, drag to change), and once animated
    /// the keyframe buttons. Hidden once the control is deleted.
    @ViewBuilder
    private func numberRow(_ kind: ControlKind) -> some View {
        if let control = effect.control(kind) {
            let name = kind.name.lowercased()
            let time = playhead.shown(animated: control.isAnimated)
            HStack(spacing: 4) {
                AnimateToggle(name: name, isAnimated: control.isAnimated) {
                    let at = playhead.current
                    onEdit { $0.changeControl(kind) { $0.number.setAnimated(!$0.number.isAnimated, at: at) } }
                }
                Text(kind.name)
                    .foregroundStyle(Design.textSecondary)
                    .frame(width: 76, alignment: .leading)
                NumericField(
                    value: control.values(at: time).first ?? 0, unit: kind.unit, fractionDigits: kind.dragStep < 1 ? 1 : 0,
                    dragStep: kind.dragStep, dragRange: kind.range, accessibilityName: kind.name
                ) { value in
                    let at = playhead.current
                    onEdit { $0.changeControl(kind) { $0.setComponent(0, to: value, at: at) } }
                }
                .disabled(!control.enabled)
                Spacer(minLength: 4)
                if control.isAnimated {
                    KeyframeNavigator(
                        name: name, keyframeTimes: control.number.keyframes.map(\.time), time: time, onSeek: onSeek,
                        onToggle: {
                            let at = playhead.current
                            onEdit { $0.changeControl(kind) { $0.number.toggleKeyframe(at: at) } }
                        }
                    )
                }
            }
            .font(Design.Typeface.label)
            .help(help(for: kind))
        }
    }

    private func help(for kind: ControlKind) -> String {
        switch kind {
        case .fontSize: "The font's size in pixels"
        case .tracking: "Space added after each letter, in pixels; below 0 draws them closer"
        case .lineHeight: "The space from one line to the next, as a percentage of the font's own"
        case .wrapWidth: "Where lines wrap, in pixels; 0 keeps each paragraph on one line"
        default: kind.name
        }
    }

    /// A row with `name` on the left and its control on the right, as the
    /// inspector's other settings are laid out.
    private func labelled(_ name: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.step) {
            Text(name)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
            Spacer(minLength: Design.Space.step)
            control()
        }
    }
}
