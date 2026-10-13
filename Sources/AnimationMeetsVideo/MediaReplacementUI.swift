import AppKit
import AVFoundation
import CoreMedia
import Observation
import SwiftUI

// MARK: - Session

/// One replacement in progress: a file being compared with an asset's
/// original and the choices the person is making about it.
@MainActor
@Observable
final class ReplacementSession: Identifiable {
    enum Phase {
        case analyzing
        case ready(ReplacementAnalysis)
        case failed(String)
    }

    let id = UUID()
    let assetID: UUID
    let assetName: String
    let candidate: URL
    /// True when the file is the one already in place, which changed on disk.
    let isReview: Bool
    let originalDuration: CMTime
    let frameRate: Double

    var phase: Phase = .analyzing
    var progress = 0.0
    var offset: CMTime = .zero
    var acceptedConfirmations: Set<Int> = []
    var acceptedLoss = false
    /// A moment in the original, in seconds, shown on both sides to check the sync.
    var probeSeconds = 0.0
    var pictures: ReferenceThumbnails?
    var isApplying = false

    init(asset: MediaClip, candidate: URL, isReview: Bool) {
        assetID = asset.id
        assetName = asset.name
        self.candidate = candidate
        self.isReview = isReview
        originalDuration = asset.duration
        frameRate = asset.frameRate > 0 ? asset.frameRate : 24
    }

    var frameDuration: CMTime { CMTime(seconds: 1 / frameRate, preferredTimescale: 60_000) }
}

// MARK: - Controller

@MainActor
@Observable
final class MediaReplacementController {
    struct Context {
        var project: Binding<EditingProject>
        var analysis: AssetAnalysis
        var packageURL: URL?
    }

    struct Request: Equatable {
        var assetID: UUID
        var url: URL
    }

    struct Notice {
        var title: String
        var message: String
    }

    private(set) var session: ReplacementSession?
    var notice: Notice?
    /// Assets whose file was swapped outside the app and still needs a sync check.
    private(set) var changedMedia: Set<UUID> = []

    @ObservationIgnored private var queue: [Request] = []
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requested = 0
    @ObservationIgnored private var replaced = 0
    @ObservationIgnored private var skipped: [String] = []
    /// True from when the sheet appears until it has finished closing.
    @ObservationIgnored private var isSheetShown = false
    /// A notice held back until the sheet has closed: macOS drops an alert
    /// presented while a sheet on the same window is still closing.
    @ObservationIgnored private var pendingNotice: Notice?

    func markChanged(_ ids: [UUID]) {
        changedMedia.formUnion(ids)
    }

    /// Flags assets whose file no longer matches what was last accepted for
    /// them, and unflags those that match again. A newly changed file also
    /// leaves the caches, so nothing keeps reading the old contents.
    func checkForChanges(in project: EditingProject) {
        var newlyChanged: [MediaClip] = []
        for clip in project.clips {
            guard let url = clip.url, let accepted = clip.acceptedStamp, let current = FileStamp(url: url) else { continue }
            if current == accepted {
                changedMedia.remove(clip.id)
            } else if changedMedia.insert(clip.id).inserted {
                newlyChanged.append(clip)
            }
        }
        guard !newlyChanged.isEmpty else { return }

        let urls = newlyChanged.compactMap(\.url)
        Task {
            for url in urls { await CompositionExporter.forgetCachedMedia(at: url) }
            SceneThumbnailStore.invalidate()
        }
        if notice == nil, pendingNotice == nil, session == nil {
            let names = newlyChanged.map(\.name).joined(separator: "\n")
            post(Notice(
                title: "Media Changed on Disk",
                message: "These files changed outside the app:\n\n\(names)\n\nControl-click one in the Clips list and choose \u{201C}File Changed — Check Sync…\u{201D} to line it up."
            ))
        }
    }

    /// Forgets everything, for a different project.
    func reset() {
        task?.cancel()
        task = nil
        session = nil
        queue = []
        context = nil
        changedMedia = []
        notice = nil
        pendingNotice = nil
    }

    func sheetDidAppear() {
        isSheetShown = true
    }

    /// Shows a notice that was waiting for the sheet to close.
    func sheetDidDismiss() {
        isSheetShown = false
        if let pendingNotice {
            notice = pendingNotice
            self.pendingNotice = nil
        }
    }

    private func post(_ notice: Notice) {
        if isSheetShown {
            pendingNotice = notice
        } else {
            self.notice = notice
        }
    }

    /// Compares each file with its asset and replaces those that need no
    /// questions; the rest open the sync dialog one at a time.
    func start(_ requests: [Request], context: Context) {
        guard session == nil, !requests.isEmpty else { return }
        self.context = context
        queue = requests
        requested = requests.count
        replaced = 0
        skipped = []
        processNext()
    }

    /// Checks sync for the file already in place, after it changed on disk.
    func review(assetID: UUID, context: Context) {
        guard session == nil, let url = context.project.wrappedValue.mediaClip(id: assetID)?.url else { return }
        self.context = context
        queue = [Request(assetID: assetID, url: url)]
        requested = 1
        replaced = 0
        skipped = []
        processNext(isReview: true)
    }

    func confirm(_ session: ReplacementSession) {
        guard case .ready(let analysis) = session.phase, let context, !session.isApplying else { return }
        session.isApplying = true
        let offset = session.offset
        Task {
            await apply(analysis, assetID: session.assetID, offset: offset, context: context)
            self.session = nil
            processNext()
        }
    }

    /// Cancels `session` if it is still the current one, so a late call for
    /// a session already finished or replaced by the next does nothing.
    func cancel(_ session: ReplacementSession) {
        guard self.session?.id == session.id else { return }
        task?.cancel()
        skipped.append(session.assetName)
        self.session = nil
        queue.removeAll()
        finish()
    }

    /// Points an asset back at a file it used before. The usual comparison
    /// and sync check still happen.
    func useEarlierFile(assetID: UUID, path: String, context: Context) {
        start([Request(assetID: assetID, url: URL(fileURLWithPath: path))], context: context)
    }

    private func processNext(isReview: Bool = false) {
        guard let context else { return }
        guard !queue.isEmpty else {
            finish()
            return
        }
        let request = queue.removeFirst()
        guard let asset = context.project.wrappedValue.mediaClip(id: request.assetID) else {
            processNext()
            return
        }

        let session = ReplacementSession(asset: asset, candidate: request.url, isReview: isReview)
        self.session = session
        let packageURL = context.packageURL
        // A forgotten original's data stays until the next save, but is no longer used.
        let forgotten = asset.referenceForgotten
        let reference = forgotten ? nil : context.analysis.references[asset.id]
            ?? packageURL.flatMap { ProjectStore.readReference(for: asset.id, in: $0) }
        let scores = context.analysis.tracks[asset.id]
        let used = context.project.wrappedValue.usedRanges(ofMedia: asset.id)

        task = Task {
            do {
                let analysis = try await MediaReplacer.analyze(
                    candidate: request.url, replacing: asset, reference: reference,
                    originalScores: scores, usedRanges: used
                ) { fraction in
                    Task { @MainActor in session.progress = fraction }
                }
                guard !Task.isCancelled, self.session?.id == session.id else { return }

                if analysis.needsNoQuestions {
                    await apply(analysis, assetID: asset.id, offset: analysis.proposedOffset, context: context)
                    self.session = nil
                    processNext()
                    return
                }

                session.offset = analysis.proposedOffset
                session.probeSeconds = used.map(\.start.seconds).min() ?? 0
                if forgotten {
                    session.pictures = nil
                } else if let packageURL {
                    let saved = context.analysis.unsavedThumbnails[asset.id]
                        ?? ProjectStore.readThumbnails(for: asset.id, in: packageURL)
                    session.pictures = saved.frames.isEmpty ? nil : saved
                } else {
                    session.pictures = context.analysis.unsavedThumbnails[asset.id]
                }
                session.phase = .ready(analysis)
            } catch is CancellationError {
                return
            } catch {
                guard self.session?.id == session.id else { return }
                session.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ analysis: ReplacementAnalysis, assetID: UUID, offset: CMTime, context: Context) async {
        let oldURL = context.project.wrappedValue.mediaClip(id: assetID)?.url
        if let oldURL { await CompositionExporter.forgetCachedMedia(at: oldURL) }
        if let newURL = analysis.replacement.url { await CompositionExporter.forgetCachedMedia(at: newURL) }
        SceneThumbnailStore.invalidate()
        context.project.wrappedValue.replaceMedia(id: assetID, with: analysis.replacement, offset: offset)
        changedMedia.remove(assetID)
        replaced += 1
    }

    private func finish() {
        let wasBatch = requested > 1
        session = nil
        queue = []
        guard wasBatch else { return }
        var message = "Replaced \(replaced) of \(requested)."
        if !skipped.isEmpty {
            message += "\n\nNot replaced:\n" + skipped.joined(separator: "\n")
        }
        post(Notice(title: "Media Replaced", message: message))
    }
}

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
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    controller.checkForChanges(in: project)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                controller.checkForChanges(in: project)
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

// MARK: - Composition key

/// Everything that affects the rendered composition. Layer renames and
/// timeline names are stripped so they don't swap the player item and
/// interrupt playback; a replaced file or a new alignment is included so
/// they do.
struct CompositionKey: Equatable {
    struct Media: Equatable {
        var id: UUID
        var path: String?
        var offset: CMTime
        var stamp: FileStamp?
    }

    var timelines: [Timeline]
    var media: [Media]

    init(project: EditingProject) {
        timelines = project.timelines.map { timeline in
            var copy = timeline
            copy.name = ""
            for index in copy.layers.indices {
                copy.layers[index].customName = nil
            }
            return copy
        }
        media = project.clips.map {
            Media(id: $0.id, path: $0.url?.path, offset: $0.alignmentOffset, stamp: $0.acceptedStamp)
        }
    }
}
