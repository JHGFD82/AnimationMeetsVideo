import CoreGraphics
import CoreMedia
import SwiftUI

/// The controls of `kinds` an effect has, in that order, as inspector rows.
/// One deleted in the effects panel isn't shown.
struct InspectorControls: View {
    let effect: Effect
    let kinds: [ControlKind]
    let playhead: PlayheadTime
    /// Whether the rows have the stopwatch and keyframe buttons: only for
    /// an effect that exists to animate (a Text Animator). Everything else
    /// is keyframed in the effects panel.
    var keyframing = false
    let onEdit: ((inout Effect) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    var body: some View {
        ForEach(kinds.compactMap { effect.control($0) }) { control in
            InspectorControlRow(
                control: control, playhead: playhead, keyframing: keyframing,
                onEdit: { change in onEdit { $0.changeControl(control.kind, change) } },
                onSeek: onSeek
            )
        }
    }
}

/// One control of an effect in the inspector, drawn as Illustrator's
/// panels draw their settings:
///
/// - numbers: the name, then each component's value at the playhead in a
///   field (click to type, drag to change), with a link for a size's
///   axes;
/// - a color: a checkbox that turns it on or off, a color well and its
///   opacity;
/// - a choice: icon buttons where there are icons for it (alignment, case,
///   a stroke's edge, join and cap; `InspectorGlyphs`), the nine points of
///   a box for an anchor, a checkbox for an on-or-off setting, else a menu.
///
/// The inspector doesn't keyframe: a number that isn't animated is set
/// outright, and one that is (in the effects panel) shows its value at the
/// playhead read-only, with a badge saying to change it there. A row with
/// `keyframing` on, for an effect that exists to animate, has the
/// stopwatch and keyframe buttons instead, and edits land at the playhead.
///
/// `layout` `.cell` draws a lone number as a field with its icon and no
/// name, and a choice without its name, for a grid of them.
struct InspectorControlRow: View {
    enum Layout {
        case row, cell
    }

    let control: EffectControl
    /// The playhead in the clip's source time, snapped to a frame.
    let playhead: PlayheadTime
    var keyframing = false
    var layout = Layout.row
    let onEdit: ((inout EffectControl) -> Void) -> Void
    /// Moves the playhead to a time in the clip's source time.
    let onSeek: (CMTime) -> Void

    /// The width of a row's name.
    static let nameWidth: CGFloat = 92

    private var kind: ControlKind { control.kind }
    private var lowercaseName: String { kind.name.lowercased() }
    /// Whether the value is fixed here: animated, in a row that doesn't
    /// keyframe.
    private var isReadOnly: Bool { control.isAnimated && !keyframing }

    var body: some View {
        Group {
            if kind.isChoice {
                choiceRow
            } else {
                numberRow
            }
        }
        .font(Design.Typeface.label)
    }

    // MARK: Choices

    @ViewBuilder
    private var choiceRow: some View {
        let picked = control.choice ?? kind.defaultChoice ?? ""
        let set: (String) -> Void = { choice in onEdit { $0.choice = choice } }
        if Set(kind.choiceOptions.map(\.id)) == Set(OnOff.allCases.map(\.rawValue)) {
            Toggle(kind.name, isOn: Binding(
                get: { picked == OnOff.on.rawValue },
                set: { isOn in set((isOn ? OnOff.on : .off).rawValue) }
            ))
            .toggleStyle(.checkbox)
            .foregroundStyle(Design.textSecondary)
            .disabled(!control.enabled)
        } else {
            labelled {
                if let segments = InspectorGlyphs.segments(kind) {
                    PanelSegmentedPicker(name: kind.name, segments: segments, selection: picked, fills: true, onPick: set)
                } else if kind == .textAnchor {
                    PanelPointGrid(
                        name: kind.name, points: TextAnchor.allCases.map { ($0.rawValue, $0.name) }, selection: picked, onPick: set
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    PanelMenuField(
                        glyph: layout == .cell ? InspectorGlyphs.field(kind) : nil, name: kind.name,
                        options: kind.choiceOptions.map { ($0.id, $0.name) }, selection: picked, onPick: set
                    )
                }
            }
            .disabled(!control.enabled)
        }
    }

    // MARK: Numbers

    private var numberRow: some View {
        let time = playhead.shown(animated: control.isAnimated)
        let values = control.values(at: time)
        return labelled {
            if kind.isColor {
                colorFields(values)
            } else {
                HStack(spacing: 4) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        field(index, value, count: values.count)
                        if index == 0, values.count == 2, kind.isLinkable { linkButton }
                    }
                }
                .disabled(!control.enabled)
            }
        }
    }

    /// One component's field, its icon the control's (`InspectorGlyphs`)
    /// in a grid, else its component's name when it has more than one.
    private func field(_ index: Int, _ value: Double, count: Int) -> some View {
        let componentGlyph: PanelGlyph? = count > 1 ? .text(shortName(index)) : nil
        let glyph = layout == .cell ? InspectorGlyphs.field(kind) ?? componentGlyph : componentGlyph
        let name = count > 1 ? "\(kind.name) \(componentName(index))" : kind.name
        return PanelField(glyph: glyph, name: name) {
            NumericField(
                value: value, unit: kind.unit(ofComponent: index), fractionDigits: kind.dragStep(ofComponent: index) < 1 ? 2 : 1,
                label: kind == .leading ? { $0 == 0 ? "Auto" : kind.label($0) } : nil,
                dragStep: kind.dragStep(ofComponent: index), dragRange: kind.range(ofComponent: index),
                accessibilityName: isReadOnly ? "\(name), animated" : name
            ) { newValue in
                let at = playhead.current
                onEdit { $0.setComponent(index, to: newValue, at: at) }
            }
            .disabled(isReadOnly)
            .opacity(isReadOnly ? 0.7 : 1)
        } accessory: {
            if index == count - 1 { animatedAccessory }
        }
        .help(name)
    }

    @ViewBuilder
    private var animatedAccessory: some View {
        if isReadOnly { AnimatedInEffectsBadge(name: lowercaseName) }
    }

    private var linkButton: some View {
        Button {
            onEdit { $0.linked.toggle() }
        } label: {
            Image(systemName: "link")
                .font(Design.Typeface.micro)
                .foregroundStyle(control.linked ? Design.textPrimary : Design.textTertiary)
                .frame(width: 14, height: Design.PanelControl.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(control.linked ? "Width and height change together" : "Width and height change separately")
        .accessibilityLabel("Link width and height")
        .accessibilityValue(control.linked ? "on" : "off")
    }

    /// A color's checkbox, which leaves it out when off, its well and its
    /// opacity.
    @ViewBuilder
    private func colorFields(_ values: [Double]) -> some View {
        HStack(spacing: 6) {
            Toggle("Use \(lowercaseName)", isOn: Binding(get: { control.enabled }, set: { on in onEdit { $0.enabled = on } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(control.enabled ? "Turn off to leave the \(lowercaseName) out" : "Turn on to draw the \(lowercaseName)")
            HeldColorWell(name: kind.name, selection: Binding(
                get: {
                    let rgba = values.map { CGFloat($0) }
                    guard rgba.count == 4 else { return CGColor(gray: 1, alpha: 1) }
                    return CGColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
                },
                set: { picked in
                    // Read as sRGB, which is how the components are drawn.
                    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                          let srgb = picked.converted(to: space, intent: .defaultIntent, options: nil),
                          let parts = srgb.components, parts.count >= 4
                    else { return }
                    let values = parts.prefix(4).map { kind.clamped(Double($0)) }
                    let at = playhead.current
                    onEdit { $0.number.set(ComponentValue(values: values), at: at) }
                }
            ))
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel(isReadOnly ? "\(kind.name), animated" : kind.name)
            .disabled(!control.enabled || isReadOnly)
            if values.count == 4 {
                Text("\(Int((values[3] * 100).rounded()))%")
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textTertiary)
                    .help("Opacity, set in the color well")
                    .accessibilityLabel("\(kind.name) opacity")
            }
            Spacer(minLength: 0)
            animatedAccessory
        }
    }

    // MARK: Layout

    /// The control after its name (and the stopwatch while keyframing),
    /// and the keyframe buttons; in a cell, the control alone.
    @ViewBuilder
    private func labelled(@ViewBuilder _ content: () -> some View) -> some View {
        if layout == .cell {
            content()
        } else {
            HStack(spacing: 4) {
                if keyframing {
                    if kind.isChoice {
                        Color.clear.frame(width: 18, height: 1)
                    } else {
                        AnimateToggle(name: lowercaseName, isAnimated: control.isAnimated) {
                            let at = playhead.current
                            onEdit { $0.number.setAnimated(!$0.number.isAnimated, at: at) }
                        }
                    }
                }
                name
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if keyframing, control.isAnimated {
                    KeyframeNavigator(
                        name: lowercaseName, keyframeTimes: control.number.keyframes.map(\.time),
                        time: playhead.shown(animated: true), onSeek: onSeek,
                        onToggle: {
                            let at = playhead.current
                            onEdit { $0.number.toggleKeyframe(at: at) }
                        }
                    )
                }
            }
        }
    }

    /// What one component is called ("Width", "Gap").
    private func componentName(_ index: Int) -> String {
        kind.componentNames.indices.contains(index) ? kind.componentNames[index] : kind.name
    }

    /// A component's name as a field's icon: as it is when short ("Δx"),
    /// else its initial ("W").
    private func shortName(_ index: Int) -> String {
        let name = componentName(index)
        return name.count <= 2 ? name : String(name.prefix(1))
    }

    private var name: some View {
        Text(kind.name)
            .foregroundStyle(Design.textSecondary)
            .lineLimit(1)
            .frame(width: Self.nameWidth, alignment: .leading)
    }
}

/// Marks a value the inspector shows but doesn't set: it is animated, so
/// it changes with its keyframes, in the effects panel.
struct AnimatedInEffectsBadge: View {
    /// The value's name, lowercase: "size".
    let name: String

    var body: some View {
        Image(systemName: "diamond.fill")
            .font(Design.Typeface.glyphTiny)
            .foregroundStyle(Design.keyframe)
            .help("The \(name) is animated: change it with its keyframes in the Effects panel")
            .accessibilityLabel("Animated; change its keyframes in the Effects panel")
    }
}
