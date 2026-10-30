import AppKit
import SwiftUI

/// The Export window's content (see `ExportWindow`): what to export as and
/// how its sound is delivered, what blocks it, its progress and how it
/// ended.
struct ExportView: View {
    @Bindable var export: ExportWindow
    @AppStorage(Preferences.exportLoudness) private var loudness = LoudnessTarget.asMixed
    @AppStorage(Preferences.exportAudioTracks) private var audioTracks = ExportAudioTracks.mix

    var body: some View {
        SheetFrame(
            title: "Export",
            subtitle: export.timelineName.isEmpty ? nil : "The timeline \u{201C}\(export.timelineName)\u{201D}, as it plays."
        ) {
            SheetSection {
                SheetRow("Format") {
                    Picker("Format", selection: $export.format) {
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
                    .fixedSize()
                }
                SheetNote(Self.note(for: export.format))
            }
            SheetSection("Sound") {
                SheetRow("Loudness") {
                    Picker("Loudness", selection: $loudness) {
                        ForEach(LoudnessTarget.allCases) { target in
                            Text("\(target.name), \(target.detail)").tag(target)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(export.format == .wavStems)
                }
                SheetRow("Movie tracks") {
                    Picker("Movie sound tracks", selection: $audioTracks) {
                        ForEach(ExportAudioTracks.allCases) { tracks in
                            Text(tracks.name).tag(tracks)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(export.format.movie == nil)
                }
                SheetNote(soundNote)
            }
            .disabled(export.isRunning)
            status
        } actions: {
            if export.isRunning {
                Button("Stop Export\u{2026}") { export.confirmAndCancel() }
                Button("Close") { export.close() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Close") { export.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export.onExport() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Design.accent)
    }

    /// What blocks the export, how far along it is, or how it ended.
    @ViewBuilder private var status: some View {
        if export.isRunning {
            SheetSection {
                ProgressView(value: export.progress) {
                    Text("Exporting\u{2026}")
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textSecondary)
                }
                .accessibilityValue("\(Int((export.progress * 100).rounded())) percent")
            }
        } else if export.pasteChangeCount > 0 {
            let count = export.pasteChangeCount
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.group) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Design.statusWarning)
                    .accessibilityHidden(true)
                Text("\(count) pasted effect change\(count == 1 ? "" : "s") to resolve before exporting.")
                    .font(Design.Typeface.body)
                    .foregroundStyle(Design.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Design.Space.step)
                Button("Review\u{2026}") { export.onReviewPasteChanges() }
            }
        } else if let outcome = export.outcome {
            switch outcome {
            case .finished(let url, let report):
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.group) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Design.statusDone)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Design.Space.step) {
                        Text(Self.finishedMessage(url: url, report: report))
                            .font(Design.Typeface.body)
                            .foregroundStyle(Design.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.group) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(Design.statusDanger)
                        .accessibilityHidden(true)
                    Text("Export failed. \(message)")
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var soundNote: String {
        switch export.format {
        case .wavStems: "Stems aren't mastered, so together they add up to the mix as mixed."
        case .wavMix: "Peaks are held under −1 dBFS when a loudness is set."
        case .proRes422, .proRes4444:
            "Peaks are held under −1 dBFS when a loudness is set. Mix and Stems adds a track for each layer with sound after the mix, unmastered."
        }
    }

    static func note(for format: ExportFormat) -> String {
        switch format {
        case .proRes422: "Reuses the stretches already rendered in the background."
        case .proRes4444: "Composites everything from the sources."
        case .wavMix: "The sound alone, as one stereo file."
        case .wavStems: "A file for each layer with sound, in a new folder."
        }
    }

    static func finishedMessage(url: URL, report: String?) -> String {
        let saved = "\u{201C}\(url.lastPathComponent)\u{201D} was saved."
        guard let report else { return saved }
        return "\(saved)\n\n\(report)"
    }
}
