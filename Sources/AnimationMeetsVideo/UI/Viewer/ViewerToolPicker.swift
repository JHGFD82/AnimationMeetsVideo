import SwiftUI

/// The viewer's tools in its rail, built as `TimelineToolPicker` is: Arrow
/// and Pen (P). Beside them, while the pen is picked, Shape | Mask, which
/// says what a new path becomes, and the well of the path color (see
/// docs/pen-tool.md, "Picking the pen").
struct ViewerToolPicker: View {
    let state: ViewerCanvasState

    @AppStorage(Preferences.penColor) private var penColor = Preferences.defaultPenColor

    var body: some View {
        HStack(spacing: Design.Space.close) {
            Picker("Tool", selection: Binding(get: { state.tool }, set: { state.pick($0) })) {
                ForEach(ViewerTool.allCases) { tool in
                    Image(systemName: tool.systemImage)
                        .help(tool.help)
                        .accessibilityLabel(tool.name)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(state.tool.help)
            .accessibilityLabel("Viewer Tool")
            .accessibilityValue(state.tool.name)
            if state.tool == .pen {
                Picker("New Path", selection: Binding(get: { state.pen.mode }, set: { state.pen.mode = $0 })) {
                    ForEach(PenState.Mode.allCases) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("What a new path becomes: a shape on its own layer, or a mask on the selected clip")
                .accessibilityLabel("New Path")
                .accessibilityValue(state.pen.mode.name)
                PenColorWell(hex: $penColor)
            }
        }
    }
}

/// The path color's well: a swatch that opens the 64 colors bars have and
/// the Mac's color picker (`BarColorPanel`). Remembered per Mac.
private struct PenColorWell: View {
    @Binding var hex: String

    private var color: BarColor { BarColor(hex: hex) ?? BarColor(hex: Preferences.defaultPenColor)! }

    var body: some View {
        Menu {
            Button("Magenta (Default)") { hex = Preferences.defaultPenColor }
            Divider()
            ForEach(BarColor.presetRows.indices, id: \.self) { row in
                Picker("Colors, row \(row + 1)", selection: Binding<BarColor?>(
                    get: { color },
                    set: { if let picked = $0 { hex = picked.hex } }
                )) {
                    ForEach(BarColor.presetRows[row]) { preset in
                        Image(nsImage: ColorSwatch.image(preset.color, checked: preset.color == color))
                            .help(preset.name)
                            .accessibilityLabel(preset.name)
                            .tag(Optional(preset.color))
                    }
                }
                .pickerStyle(.palette)
                .paletteSelectionEffect(.custom)
                .labelsHidden()
            }
            Divider()
            Button("Other…") {
                BarColorPanel.shared.show(current: color) { picked in hex = picked.hex }
            }
        } label: {
            // Its own picture: a menu button draws a symbol as a template.
            Image(nsImage: ColorSwatch.image(color, side: 16))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The color paths are drawn in over the picture")
        .accessibilityLabel("Path Color")
        .accessibilityValue(color.name)
    }
}
