import SwiftUI

/// The timeline's tools as a segmented control in its header. Redrawn only
/// when the tool changes (the header marks it `.equatable()`): a segmented
/// control is costly to lay out, and the timeline redraws on every edit.
struct TimelineToolPicker: View, Equatable {
    /// The tool when the timeline drew, which the comparison uses: the
    /// binding always reads the current one.
    let current: TimelineTool
    @Binding var tool: TimelineTool

    var body: some View {
        Picker("Tool", selection: $tool) {
            ForEach(TimelineTool.allCases) { tool in
                Image(systemName: tool.systemImage)
                    .help(tool.help)
                    .accessibilityLabel(tool.name)
                    .tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(current.help)
    }

    nonisolated static func == (lhs: TimelineToolPicker, rhs: TimelineToolPicker) -> Bool {
        MainActor.assumeIsolated { lhs.current == rhs.current }
    }
}
