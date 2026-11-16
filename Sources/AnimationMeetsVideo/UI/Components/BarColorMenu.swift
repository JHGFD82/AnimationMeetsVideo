import SwiftUI

/// The Color submenu on every bar's right-click menu: a clip's (all the
/// clips picked with it), a section's, the loop region's, and a layer's
/// header (all its clips). Default gives the bar its tone back, the 64
/// swatches (`BarColor.presetRows`) give it theirs, and Other… opens the
/// Mac's color picker (`BarColorPanel`). See docs/bar-colors.md, "The
/// Color menu".
///
/// The swatches are a palette `Picker` per row of eight. Not yet looked at
/// on screen: if the rows don't draw as a tidy grid in a context menu, the
/// fallback is an `NSMenuItem` whose view is the grid, keeping these
/// inputs, so the call sites don't change.
struct BarColorMenu: View {
    /// The bar's own color; nil for its default.
    let current: BarColor?
    /// The bars it colors differ (a layer's clips): neither Default nor
    /// a swatch is marked.
    var isMixed = false
    let onSet: (BarColor?) -> Void
    let onPickOther: () -> Void

    var body: some View {
        Menu("Color") {
            Toggle("Default", isOn: Binding(
                get: { !isMixed && current == nil },
                set: { if $0 { onSet(nil) } }
            ))
            Divider()
            ForEach(BarColor.presetRows.indices, id: \.self) { row in
                Picker("Colors, row \(row + 1)", selection: Binding<BarColor?>(
                    get: { isMixed ? nil : current },
                    set: { if let color = $0 { onSet(color) } }
                )) {
                    ForEach(BarColor.presetRows[row]) { preset in
                        swatch(preset)
                            .tag(Optional(preset.color))
                    }
                }
                .pickerStyle(.palette)
                .paletteSelectionEffect(.custom)
                .labelsHidden()
            }
            Divider()
            Button("Other…", action: onPickOther)
        }
    }

    /// A tinted dot, checked while it is the bar's color: the selection is
    /// drawn here (`.custom`), the same however the menu is drawn.
    private func swatch(_ preset: BarColor.Preset) -> some View {
        let isPicked = !isMixed && current == preset.color
        return Image(systemName: isPicked ? "checkmark.circle.fill" : "circle.fill")
            .foregroundStyle(Design.color(preset.color))
            .help(preset.name)
            .accessibilityLabel(preset.name)
            .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
