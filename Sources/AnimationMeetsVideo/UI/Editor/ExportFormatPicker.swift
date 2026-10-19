import SwiftUI

/// The toolbar's menu of export formats. Redrawn only when the format or
/// whether an export is running changes (the toolbar marks it
/// `.equatable()`). The toolbar redraws on every edit, and each update of
/// a menu-style picker left SwiftUI's map of its tags and observation
/// state behind: a long session of edits slowed every later update of the
/// window, about a millisecond for every ninety edits.
struct ExportFormatPicker: View, Equatable {
    /// The format when the toolbar drew, which the comparison uses: the
    /// binding always reads the current one.
    let current: ExportFormat
    @Binding var selection: ExportFormat
    let isExporting: Bool

    var body: some View {
        Picker("Export format", selection: $selection) {
            ForEach(ExportFormat.allCases.filter { $0.movie != nil }) { format in
                Text(format.name).tag(format)
            }
            Divider()
            ForEach(ExportFormat.allCases.filter { $0.movie == nil }) { format in
                Text(format.name).tag(format)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 130)
        .help("ProRes 422 exports reuse the stretches already rendered in the background; ProRes 4444 composites everything from the sources. WAV Mix is the sound alone; WAV Stems is a file for each layer with sound, unmastered.")
        .disabled(isExporting)
    }

    nonisolated static func == (lhs: ExportFormatPicker, rhs: ExportFormatPicker) -> Bool {
        MainActor.assumeIsolated { lhs.current == rhs.current && lhs.isExporting == rhs.isExporting }
    }
}
