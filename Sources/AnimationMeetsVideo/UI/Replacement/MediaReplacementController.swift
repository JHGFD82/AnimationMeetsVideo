import CoreMedia
import Observation
import SwiftUI

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
    /// Assets whose file has gone missing or can't be read since it was opened.
    private(set) var missingMedia: Set<UUID> = []

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

    /// Notes assets already known to be missing, as when opening found them
    /// gone, so the file check doesn't report them again.
    func markMissing(_ ids: [UUID]) {
        missingMedia.formUnion(ids)
    }

    /// One asset's file as found on disk; a nil stamp means it is missing
    /// or can't be read.
    struct FileReading: Sendable {
        var path: String
        var stamp: FileStamp?
    }

    /// Reads the stamp of every asset's file. It runs away from the main
    /// thread, since each read can block for seconds on a network volume
    /// that is asleep or gone.
    nonisolated static func readFiles(of project: EditingProject) async -> [UUID: FileReading] {
        let files = project.clips.compactMap { clip in clip.url.map { (clip.id, $0) } }
        return await Task.detached(priority: .utility) {
            var readings: [UUID: FileReading] = [:]
            for (id, url) in files {
                readings[id] = FileReading(path: url.path, stamp: FileStamp(url: url))
            }
            return readings
        }.value
    }

    /// Reads the files and applies the result to `project` as it is then.
    func checkForChanges(in project: () -> EditingProject) async {
        let readings = await Self.readFiles(of: project())
        apply(readings, to: project())
    }

    /// Flags assets whose file no longer matches what was last accepted for
    /// them, and unflags those that match again. A newly changed file also
    /// leaves the caches, so nothing keeps reading the old contents. A file
    /// that has gone is reported once; it can't be checked for sync, so it
    /// isn't flagged as changed until it is back. Readings of a path the
    /// asset no longer uses are ignored.
    func apply(_ readings: [UUID: FileReading], to project: EditingProject) {
        var newlyChanged: [MediaClip] = []
        var newlyMissing: [MediaClip] = []
        for clip in project.clips {
            guard let url = clip.url, let reading = readings[clip.id], reading.path == url.path else { continue }
            guard let current = reading.stamp else {
                changedMedia.remove(clip.id)
                if missingMedia.insert(clip.id).inserted { newlyMissing.append(clip) }
                continue
            }
            missingMedia.remove(clip.id)
            guard let accepted = clip.acceptedStamp else { continue }
            if current == accepted {
                changedMedia.remove(clip.id)
            } else if changedMedia.insert(clip.id).inserted {
                newlyChanged.append(clip)
            }
        }

        if !newlyChanged.isEmpty {
            let urls = newlyChanged.compactMap(\.url)
            Task {
                for url in urls { await CompositionExporter.forgetCachedMedia(at: url) }
                SceneThumbnailStore.invalidate()
                WaveformCache.shared.invalidateAll()
            }
        }
        guard !newlyChanged.isEmpty || !newlyMissing.isEmpty, notice == nil, pendingNotice == nil, session == nil else { return }
        var parts: [String] = []
        if !newlyChanged.isEmpty {
            let names = newlyChanged.map(\.name).joined(separator: "\n")
            parts.append("These files changed outside the app:\n\n\(names)\n\nControl-click one in the Clips list and choose \u{201C}File Changed — Check Sync…\u{201D} to line it up.")
        }
        if !newlyMissing.isEmpty {
            let names = newlyMissing.map(\.name).joined(separator: "\n")
            parts.append("These files are missing or can't be read:\n\n\(names)\n\nPut them back, or Control-click one in the Clips list and choose \u{201C}Replace Media…\u{201D}.")
        }
        post(Notice(
            title: newlyChanged.isEmpty ? "Media Missing" : (newlyMissing.isEmpty ? "Media Changed on Disk" : "Media Changed or Missing"),
            message: parts.joined(separator: "\n\n")
        ))
    }

    /// Forgets everything, for a different project.
    func reset() {
        task?.cancel()
        task = nil
        session = nil
        queue = []
        context = nil
        changedMedia = []
        missingMedia = []
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
    /// The rest of a batch is cancelled with it, and the summary lists
    /// every file that wasn't replaced.
    func cancel(_ session: ReplacementSession) {
        guard self.session?.id == session.id else { return }
        task?.cancel()
        skipped.append(session.assetName)
        let project = context?.project.wrappedValue
        skipped += queue.map { project?.mediaClip(id: $0.assetID)?.name ?? $0.url.lastPathComponent }
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
        WaveformCache.shared.invalidateAll()
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
