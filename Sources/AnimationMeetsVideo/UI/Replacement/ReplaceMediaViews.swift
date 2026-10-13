import AppKit
import CoreMedia
import SwiftUI

// MARK: - Menu

/// Context-menu items for replacing an asset's file.
struct ReplaceMediaMenuItems: View {
    let clip: MediaClip
    @Binding var project: EditingProject
    let analysis: AssetAnalysis
    let controller: MediaReplacementController
    /// Where the project is saved, or nil before its first save.
    let packageURL: URL?

    private var allClips: [MediaClip] { project.clips }
    private var references: [UUID: AssetReference] { analysis.references }

    private func makeContext() -> MediaReplacementController.Context {
        .init(project: $project, analysis: analysis, packageURL: packageURL)
    }

    var body: some View {
        if controller.missingMedia.contains(clip.id) {
            Button("File Is Missing") {}
                .disabled(true)
        }
        if controller.changedMedia.contains(clip.id) {
            Button("File Changed — Check Sync…") {
                controller.review(assetID: clip.id, context: makeContext())
            }
        }
        Button("Replace Media…") { replaceOne() }
        Button("Replace Media from Folder…") { replaceFromFolder() }
        Button("Forget Original…") { forgetOriginal() }
            .disabled(clip.referenceForgotten)
        if !clip.previousPaths.isEmpty {
            Menu("Use Earlier File") {
                ForEach(Array(clip.previousPaths.reversed()), id: \.self) { path in
                    Button(path) {
                        controller.useEarlierFile(assetID: clip.id, path: path, context: makeContext())
                    }
                    .disabled(!FileManager.default.fileExists(atPath: path))
                }
            }
        }
    }

    private func forgetOriginal() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Forget the original of \u{201C}\(clip.name)\u{201D}?"
        alert.informativeText = "When you next save the project, this deletes the saved pictures, sound and details of the original file. Without them the app can no longer compare a replacement with the original or suggest how to line it up, and once saved they can't be brought back. Clips and trims are not affected."
        alert.addButton(withTitle: "Forget Original")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        project.markReferenceForgotten(forAsset: clip.id)
    }

    private func replaceOne() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the file to use for \u{201C}\(clip.name)\u{201D}."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.start([.init(assetID: clip.id, url: url)], context: makeContext())
    }

    private func replaceFromFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose a folder. Files are matched to the project's media by name."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var found: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        if let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                found.append(url)
            }
        }

        let assets = allClips.compactMap { asset -> (id: UUID, fileNames: [String])? in
            var names: [String] = []
            if let current = asset.url?.lastPathComponent { names.append(current) }
            if !asset.referenceForgotten, let original = references[asset.id]?.metadata.fileName, !names.contains(original) {
                names.append(original)
            }
            return names.isEmpty ? nil : (asset.id, names)
        }
        let currentPaths = Set(allClips.compactMap { $0.url?.path })
        let matches = BulkReplacementMatcher.matches(for: assets, among: found)
            .filter { !currentPaths.contains($0.url.path) }
        guard !matches.isEmpty else {
            controller.notice = .init(
                title: "No Matching Files",
                message: "No file in that folder matches the name of any media in the project."
            )
            return
        }
        controller.start(matches.map { .init(assetID: $0.assetID, url: $0.url) }, context: makeContext())
    }
}

// MARK: - Sheet

struct ReplaceMediaSheet: View {
    let session: ReplacementSession
    let controller: MediaReplacementController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch session.phase {
            case .analyzing:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: session.progress)
                    Text("Reading the new file and comparing it with the original…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { controller.cancel(session) }
                        .keyboardShortcut(.cancelAction)
                }
            case .failed(let message):
                Text("The file couldn't be read: \(message)")
                    .foregroundStyle(.red)
                HStack {
                    Spacer()
                    Button("Close") { controller.cancel(session) }
                        .keyboardShortcut(.defaultAction)
                }
            case .ready(let analysis):
                ReplaceMediaDetails(session: session, analysis: analysis, controller: controller)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            if session.isReview {
                Text("\u{201C}\(session.assetName)\u{201D} changed on disk").font(.headline)
                Text("Check that it still lines up with the original.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Replace \u{201C}\(session.assetName)\u{201D}").font(.headline)
                Text("with \(session.candidate.lastPathComponent)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct ReplaceMediaDetails: View {
    let session: ReplacementSession
    let analysis: ReplacementAnalysis
    let controller: MediaReplacementController

    @State private var original: NSImage?
    @State private var replacement: NSImage?

    private var missing: [CMTimeRange] { analysis.missingRanges(forOffset: session.offset) }

    private var losses: [MediaComparison.Blocker] {
        analysis.report.blockers.filter {
            switch $0 {
            case .lostVideo, .lostAudio: true
            case .missingRanges: false
            }
        }
    }

    private var canReplace: Bool {
        session.acceptedConfirmations.count == analysis.report.confirmations.count
            && (losses.isEmpty || session.acceptedLoss)
            && missing.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !analysis.hasReference {
                Label(
                    "The original's reference data isn't available, so the new file can't be compared with it. Check the alignment yourself.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }

            if !analysis.report.adjustments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(analysis.report.adjustments, id: \.self) { note in
                        Label(note, systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(Array(analysis.report.confirmations.enumerated()), id: \.offset) { index, confirmation in
                Toggle(isOn: Binding(
                    get: { session.acceptedConfirmations.contains(index) },
                    set: { if $0 { session.acceptedConfirmations.insert(index) } else { session.acceptedConfirmations.remove(index) } }
                )) {
                    Text(Self.describe(confirmation)).font(.callout)
                }
            }

            if !losses.isEmpty {
                Toggle(isOn: Bindable(session).acceptedLoss) {
                    Text(Self.describe(losses)).font(.callout)
                }
            }

            Divider()
            syncSection

            HStack {
                Spacer()
                Button("Cancel") { controller.cancel(session) }
                    .keyboardShortcut(.cancelAction)
                Button(session.isReview ? "Accept" : "Replace") { controller.confirm(session) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canReplace)
            }
        }
    }

    // MARK: Sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alignment").font(.subheadline.weight(.semibold))
            Text(suggestionText)
                .font(.callout)
                .foregroundStyle(.secondary)

            if analysis.replacement.kind == .video {
                HStack(alignment: .top, spacing: 12) {
                    picture(original, caption: originalCaption)
                    picture(replacement, caption: "New file at \(Self.format(session.probeSeconds + session.offset.seconds, signed: false))")
                }
                Slider(
                    value: Bindable(session).probeSeconds,
                    in: 0...max(session.originalDuration.seconds, 0.1)
                )
            }

            HStack(spacing: 8) {
                Text("Offset").font(.callout)
                Button("\u{2212}1 s") { nudge(seconds: -1) }
                Button("\u{2212}1 frame") { nudge(by: session.frameDuration, sign: -1) }
                Text(Self.format(session.offset.seconds, signed: true))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 80)
                Button("+1 frame") { nudge(by: session.frameDuration, sign: 1) }
                Button("+1 s") { nudge(seconds: 1) }
                Spacer()
                Button("Use Suggested") {
                    if let suggestion = analysis.suggestion { session.offset = suggestion.offset }
                }
                .disabled(analysis.suggestion == nil)
                Button("Zero") { session.offset = .zero }
            }

            if !missing.isEmpty {
                Label(
                    "At this offset the new file doesn't cover \(Self.describe(ranges: missing)) that the project uses.",
                    systemImage: "xmark.octagon"
                )
                .font(.callout)
                .foregroundStyle(.red)
            }
        }
        .task(id: pictureKey) { await loadPictures() }
    }

    private var pictureKey: String {
        "\(session.probeSeconds)|\(session.offset.value)/\(session.offset.timescale)"
    }

    private var originalCaption: String {
        guard let frame = nearestOriginalFrame else { return "Original (no saved picture)" }
        return "Original at \(Self.format(frame.time.seconds, signed: false))"
    }

    private var nearestOriginalFrame: ReferenceFrame? {
        session.pictures?.nearestFrame(toSeconds: session.probeSeconds)
    }

    private var suggestionText: String {
        guard let suggestion = analysis.suggestion else {
            return "No match could be found automatically. Compare the two pictures and set the offset by hand."
        }
        let how = suggestion.method == .audio ? "the audio" : "the scene cuts"
        let shift = suggestion.offset.seconds
        let where_ = abs(shift) < 0.0005 ? "at the same time" : "\(Self.format(abs(shift), signed: false)) \(shift > 0 ? "later" : "earlier")"
        let sure = suggestion.isConfident ? "" : " This match is weak, so check it."
        return "Matched by \(how): the same moments are \(where_) in the new file.\(sure)"
    }

    private func picture(_ image: NSImage?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadPictures() async {
        if let frame = nearestOriginalFrame, let image = NSImage(data: frame.jpeg) {
            original = image
        } else {
            original = nil
        }
        let time = CMTimeAdd(CMTime(seconds: session.probeSeconds, preferredTimescale: 600), session.offset)
        replacement = time.seconds >= 0
            ? await SceneThumbnailStore.image(url: session.candidate, time: time)
            : nil
    }

    private func nudge(seconds: Double) {
        session.offset = CMTimeAdd(session.offset, CMTime(seconds: seconds, preferredTimescale: 60_000))
    }

    private func nudge(by step: CMTime, sign: Int32) {
        session.offset = CMTimeAdd(session.offset, CMTimeMultiply(step, multiplier: sign))
    }

    // MARK: Wording

    static func format(_ seconds: Double, signed: Bool) -> String {
        String(format: signed ? "%+.3f s" : "%.2f s", seconds)
    }

    static func describe(_ confirmation: MediaComparison.Confirmation) -> String {
        switch confirmation {
        case .aspectRatio(let old, let new):
            "The shape of the picture changes (\(String(format: "%.2f", old)) to \(String(format: "%.2f", new))). It will be fitted inside the old frame with bars or cropping. This is OK."
        case .dynamicRange(let oldIsHDR, _):
            oldIsHDR
                ? "The original was HDR and the new file is SDR, so the look will change. This is OK."
                : "The original was SDR and the new file is HDR, so the look will change. This is OK."
        case .untaggedColor:
            "The new file doesn't say what color space it uses, so the app has to guess. This is OK."
        }
    }

    static func describe(_ losses: [MediaComparison.Blocker]) -> String {
        let lostVideo = losses.contains(.lostVideo)
        let lostAudio = losses.contains(.lostAudio)
        switch (lostVideo, lostAudio) {
        case (true, true): return "The new file has no picture and no sound, which the original had. Replace anyway."
        case (true, false): return "The new file has no picture, which the original had. Replace anyway."
        default: return "The new file has no sound, which the original had. Replace anyway."
        }
    }

    static func describe(ranges: [CMTimeRange]) -> String {
        let shown = ranges.prefix(3).map { "\(format($0.start.seconds, signed: false))–\(format($0.end.seconds, signed: false))" }
        return shown.joined(separator: ", ") + (ranges.count > 3 ? " and more" : "")
    }
}

extension ReferenceThumbnails {
    /// The saved picture closest in time to `seconds`.
    func nearestFrame(toSeconds seconds: Double) -> ReferenceFrame? {
        frames.min { abs($0.time.seconds - seconds) < abs($1.time.seconds - seconds) }
    }
}

// MARK: - Window attachments

extension View {
    /// Presents the replacement dialog and the batch summary.
    func mediaReplacementDialogs(
        project: Binding<EditingProject>,
        controller: MediaReplacementController
    ) -> some View {
        modifier(MediaReplacementDialogs(controller: controller, project: project))
    }
}

private struct MediaReplacementDialogs: ViewModifier {
    let controller: MediaReplacementController
    @Binding var project: EditingProject

    func body(content: Content) -> some View {
        content
            .onPeriodicCheck(every: .seconds(5)) {
                await controller.checkForChanges { project }
            }
            // Only the controller closes the sheet. A nil written back here
            // can arrive after the controller has moved on to the next file,
            // so it is ignored; a sheet closed by any other route cancels
            // its own session, which does nothing once that session is over.
            .sheet(item: Binding(
                get: { controller.session },
                set: { _ in }
            ), onDismiss: { controller.sheetDidDismiss() }) { session in
                ReplaceMediaSheet(session: session, controller: controller)
                    .interactiveDismissDisabled()
                    .onAppear { controller.sheetDidAppear() }
                    .onDisappear { controller.cancel(session) }
            }
            .alert(
                controller.notice?.title ?? "",
                isPresented: Binding(
                    get: { controller.notice != nil },
                    set: { if !$0 { controller.notice = nil } }
                )
            ) {
                Button("OK") { controller.notice = nil }
            } message: {
                Text(controller.notice?.message ?? "")
            }
    }
}
