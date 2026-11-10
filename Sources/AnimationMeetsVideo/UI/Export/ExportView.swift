import AppKit
import SwiftUI

/// The Export window's content (see `ExportWindow`): what to export as and
/// how its sound is delivered, what blocks it, the export under way and
/// those queued behind it, and how they ended.
struct ExportView: View {
    @Bindable var export: ExportWindow
    @AppStorage(Preferences.exportLoudness) private var loudness = LoudnessTarget.asMixed
    @AppStorage(Preferences.exportAudioTracks) private var audioTracks = ExportAudioTracks.mix

    var body: some View {
        // The menus are for the next export; one under way or queued keeps
        // the format and sound it was asked for in.
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
            if export.isRunning {
                queue
            }
            if export.pasteChangeCount > 0 {
                pasteChangesNote
            }
            ForEach(export.outcomes) { ended in
                Self.outcomeRow(ended, showsTimeline: export.outcomes.count > 1)
            }
        } actions: {
            if export.isRunning {
                Button("Stop Export\u{2026}") { export.confirmAndCancel() }
            }
            Button("Close") { export.close() }
                .keyboardShortcut(.cancelAction)
            Button("Export…") { export.onExport() }
                .keyboardShortcut(.defaultAction)
                .help(export.isRunning
                      ? "Add the timeline to the queue, to export once those before it are done"
                      : "Export the timeline")
        }
        .preferredColorScheme(.dark)
        .tint(Design.accent)
    }

    /// The export under way, with its progress, and those waiting behind
    /// it, each of which can be taken out.
    @ViewBuilder private var queue: some View {
        if let current = export.current {
            SheetSection {
                ProgressView(value: export.progress) {
                    Text("Exporting \u{201C}\(current.timelineName)\u{201D} as \(current.format.name)\u{2026}")
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityValue("\(Int((export.progress * 100).rounded())) percent")
                Text(current.destination.lastPathComponent)
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if !export.queue.isEmpty {
            SheetSection("Queue") {
                ForEach(export.queue) { job in
                    HStack(alignment: .center, spacing: Design.Space.group) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\u{201C}\(job.timelineName)\u{201D} as \(job.format.name)")
                                .font(Design.Typeface.body)
                                .foregroundStyle(Design.textPrimary)
                            Text(job.destination.lastPathComponent)
                                .font(Design.Typeface.label)
                                .foregroundStyle(Design.textSecondary)
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: Design.Space.step)
                        Button {
                            export.remove(job.id)
                        } label: {
                            Image(systemName: Design.Symbol.remove)
                        }
                        .buttonStyle(.icon)
                        .help("Remove from the queue")
                        .accessibilityLabel("Remove \u{201C}\(job.timelineName)\u{201D} from the queue")
                    }
                }
            }
        }
    }

    /// Pasted changes that block exporting the timeline shown.
    private var pasteChangesNote: some View {
        let count = export.pasteChangeCount
        return HStack(alignment: .firstTextBaseline, spacing: Design.Space.group) {
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
    }

    /// How one export ended; `showsTimeline` names its timeline, when
    /// several ended.
    @ViewBuilder private static func outcomeRow(_ ended: ExportWindow.Ended, showsTimeline: Bool) -> some View {
        let prefix = showsTimeline ? "\u{201C}\(ended.timelineName)\u{201D}: " : ""
        switch ended.outcome {
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
                    .accessibilityLabel("Show \u{201C}\(url.lastPathComponent)\u{201D} in Finder")
                }
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.group) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(Design.statusDanger)
                    .accessibilityHidden(true)
                Text("\(prefix)Export failed. \(message)")
                    .font(Design.Typeface.body)
                    .foregroundStyle(Design.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
