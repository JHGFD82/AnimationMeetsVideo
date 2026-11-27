import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import IOKit.ps

/// The viewer copies a build may draw from instead of the original files
/// (`CompositionExporter.buildComposedTimeline`): by original file, the
/// stretches of it each copy holds.
struct ViewerCopyIndex: Equatable, Sendable {
    struct Copy: Equatable, Sendable {
        /// The original file's times it holds.
        var range: CMTimeRange
        var url: URL
        /// The original's time of the copy's first frame, which is at 0 in
        /// the copy: a frame's time in the copy is its time in the original
        /// less this.
        var offset: CMTime
    }

    var copies: [URL: [Copy]] = [:]

    /// A copy of `original` holding all of `range`, if there is one.
    func copy(of original: URL, covering range: CMTimeRange) -> Copy? {
        copies[original.standardizedFileURL]?.first { $0.range.containsTimeRange(range) }
    }

    var isEmpty: Bool { copies.isEmpty }
}

/// ProRes copies of the H.264 and HEVC footage a project's timelines use,
/// for the viewer to scrub and play smoothly (docs/rendering.md, "ProRes
/// viewer copies"): long-GOP footage decodes a frame only from the
/// keyframe before it, ProRes frame by frame.
///
/// - **What is copied**: the stretch of each file a clip uses, plus
///   `handleSeconds` either side, merged where they meet, at the file's
///   own size and frame times, ProRes 422 (422 HQ for footage deeper than
///   8 bits or HDR), in `Cache/ViewerCopies/` in the package.
/// - **Exact timing**: a copy keeps every frame's time as it is in the
///   original, less the time of its first frame (the writer starts the
///   movie at its first frame), which it records; it is only used once
///   the frame times read back from it, plus that, are those that were
///   written, which were the original's.
/// - **When**: one at a time, in the background, never while playing, on
///   battery, in Low Power Mode or with the Mac hot; playing stops the one
///   being made, to start again later.
/// - **Disposable**: a copy no clip uses any more, or of a file replaced
///   since (its size or date changed), is deleted; `deleteAll` deletes
///   them all.
/// - Only for the viewer: export never reads them.
@MainActor
@Observable
final class ViewerCopies {
    /// Seconds of footage copied past each end of what a clip uses, so a
    /// small trim doesn't need a new copy.
    nonisolated static let handleSeconds = 3.0

    /// Bumped whenever the copies the viewer may use change, so it builds
    /// again.
    private(set) var version = 0
    private(set) var bytesOnDisk: Int64 = 0
    /// The file being copied and how far along, 0...1.
    private(set) var making: (name: String, progress: Double)?

    /// The copies the viewer may use now: none while the project has them
    /// off.
    @ObservationIgnored private(set) var index = ViewerCopyIndex()

    /// The package the copies are kept in; nil stops everything.
    @ObservationIgnored var packageURL: URL? {
        didSet {
            guard packageURL != oldValue else { return }
            job?.cancel()
            if let oldValue { Self.release(oldValue, by: self) }
            if let packageURL { Self.claim(packageURL, by: self) }
            records = packageURL.map { Self.readRecords(in: $0) } ?? []
            refresh()
        }
    }

    /// Posted to have the copies of the package whose URL is the object
    /// deleted, by the manager making them (Project Settings' Delete
    /// Copies, which has no manager of its own).
    static let deleteRequested = Notification.Name("AnimationMeetsVideo.viewerCopiesDeleteRequested")

    /// The manager making each package's copies: the first to take it. A
    /// second window on the same project only reads what that one makes,
    /// so two never write one index.
    private static var owners: [URL: ObjectIdentifier] = [:]

    private static func claim(_ package: URL, by copies: ViewerCopies) {
        let key = package.standardizedFileURL
        if owners[key] == nil { owners[key] = ObjectIdentifier(copies) }
    }

    private static func release(_ package: URL, by copies: ViewerCopies) {
        let key = package.standardizedFileURL
        if owners[key] == ObjectIdentifier(copies) { owners[key] = nil }
    }

    /// Whether this manager makes and deletes its package's copies.
    private var isOwner: Bool {
        packageURL.map { Self.owners[$0.standardizedFileURL] == ObjectIdentifier(self) } ?? false
    }

    @ObservationIgnored private var deleteObserver: (any NSObjectProtocol)?

    init() {
        deleteObserver = NotificationCenter.default.addObserver(forName: Self.deleteRequested, object: nil, queue: .main) { [weak self] note in
            let package = (note.object as? URL)?.standardizedFileURL
            MainActor.assumeIsolated {
                guard let self, self.isOwner, package == self.packageURL?.standardizedFileURL else { return }
                self.deleteAll()
            }
        }
    }

    isolated deinit {
        if let packageURL { Self.release(packageURL, by: self) }
        if let deleteObserver { NotificationCenter.default.removeObserver(deleteObserver) }
    }

    /// How much the copies in `packageURL` take on disk.
    nonisolated static func bytes(in packageURL: URL) -> Int64 {
        let folder = folder(in: packageURL)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// A stretch of a file a copy should hold.
    struct Wanted: Equatable {
        var original: URL
        var name: String
        var range: CMTimeRange
    }

    /// A copy made, as the index file keeps it.
    struct Record: Codable, Equatable {
        var file: String
        var original: String
        var stamp: FileStamp
        var start: Double
        var end: Double
        var timescale: Int32
        /// The original's time of the copy's first frame, exactly.
        var offsetValue: Int64
        var offsetTimescale: Int32

        var offset: CMTime { CMTime(value: offsetValue, timescale: offsetTimescale) }

        /// Whether it names a file of the folder itself and times that fit.
        var isSound: Bool {
            let plainName = !file.isEmpty && file != "." && file != ".." && !file.contains("/") && !file.hasPrefix(".")
            func fits(_ seconds: Double) -> Bool {
                seconds.isFinite && abs(seconds * Double(timescale)) < Double(1 << 52)
            }
            return plainName && timescale > 0 && offsetTimescale > 0 && fits(start) && fits(end) && start <= end
        }

        var range: CMTimeRange {
            CMTimeRange(
                start: CMTime(value: CMTimeValue((start * Double(timescale)).rounded()), timescale: timescale),
                end: CMTime(value: CMTimeValue((end * Double(timescale)).rounded()), timescale: timescale)
            )
        }
    }

    @ObservationIgnored private var records: [Record] = []
    @ObservationIgnored private var wanted: [Wanted] = []
    @ObservationIgnored private var isOn = false
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var job: Task<Void, Never>?
    /// Whether copying waits for mains power, Low Power Mode off and a
    /// cool Mac; off for tests.
    @ObservationIgnored var waitsForFreeMachine = true

    /// Takes what `project` uses and whether it has copies on: deletes the
    /// copies no longer wanted and starts making the missing ones.
    func update(project: EditingProject) {
        isOn = project.makesViewerCopies
        wanted = isOn ? Self.stretches(in: project) : []
        refresh()
    }

    /// Playing stops the copy being made; pausing lets copying go on.
    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if playing { job?.cancel() } else { startIfNeeded() }
    }

    /// Deletes every copy; with copies on they are made again.
    func deleteAll() {
        job?.cancel()
        guard let packageURL, isOwner else { return }
        try? FileManager.default.removeItem(at: Self.folder(in: packageURL))
        records = []
        refresh()
    }

    // MARK: Keeping

    /// Drops the copies whose file is gone or replaced, or that hold no
    /// stretch wanted; rebuilds the index; and starts copying what is
    /// missing.
    private func refresh() {
        guard let packageURL else {
            setIndex(ViewerCopyIndex())
            return
        }
        let folder = Self.folder(in: packageURL)
        // Another window's manager makes this package's copies: take what
        // it has made, and touch nothing.
        guard isOwner else {
            records = Self.readRecords(in: packageURL)
            publish(records, in: folder)
            return
        }
        var kept: [Record] = []
        for record in records {
            let original = URL(fileURLWithPath: record.original)
            let current = FileStamp(url: original)
            let used = wanted.contains { $0.original.path == record.original && $0.range.intersection(record.range).duration > .zero }
            let exists = FileManager.default.fileExists(atPath: folder.appending(path: record.file).path)
            // Turned off, the copies stay, unused, until turned on again
            // or deleted; on, one no clip uses goes.
            if exists, current == record.stamp, used || !isOn {
                kept.append(record)
            } else {
                try? FileManager.default.removeItem(at: folder.appending(path: record.file))
            }
        }
        if kept != records {
            records = kept
            Self.writeRecords(kept, in: packageURL)
        }
        publish(kept, in: folder)
        startIfNeeded()
    }

    /// Makes `records`, found in `folder`, the copies the viewer may use
    /// (none while off), and counts what they take.
    private func publish(_ records: [Record], in folder: URL) {
        bytesOnDisk = records.reduce(0) { total, record in
            let size = (try? folder.appending(path: record.file).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
        var index = ViewerCopyIndex()
        if isOn {
            for record in records where FileManager.default.fileExists(atPath: folder.appending(path: record.file).path) {
                let original = URL(fileURLWithPath: record.original).standardizedFileURL
                index.copies[original, default: []].append(
                    .init(range: record.range, url: folder.appending(path: record.file), offset: record.offset)
                )
            }
        }
        setIndex(index)
    }

    private func setIndex(_ index: ViewerCopyIndex) {
        guard index != self.index else { return }
        self.index = index
        version += 1
    }

    /// The wanted stretches no kept copy holds.
    private var missing: [Wanted] {
        wanted.filter { want in
            !records.contains { $0.original == want.original.path && $0.range.containsTimeRange(want.range) }
        }
    }

    private func startIfNeeded() {
        guard job == nil, isOn, !isPlaying, isOwner, packageURL != nil, let next = missing.first,
              !waitsForFreeMachine || Self.machineIsFree
        else { return }
        let folder = Self.folder(in: packageURL!)
        let name = "\(UUID().uuidString).mov"
        making = (next.name, 0)
        job = Task { [weak self] in
            let made: Record?
            do {
                guard let stamp = FileStamp(url: next.original) else { throw CancellationError() }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appending(path: name)
                let offset = try await Self.copy(next.original, range: next.range, to: destination) { fraction in
                    Task { @MainActor in self?.making?.progress = fraction }
                }
                let timescale = max(next.range.start.timescale, next.range.end.timescale, 600)
                made = Record(
                    file: name, original: next.original.path, stamp: stamp,
                    start: next.range.start.seconds, end: next.range.end.seconds, timescale: timescale,
                    offsetValue: offset.value, offsetTimescale: offset.timescale
                )
            } catch {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
                made = nil
            }
            guard let self else { return }
            self.job = nil
            self.making = nil
            if let made, self.packageURL != nil {
                // The stretches it now holds make smaller copies of the
                // same file redundant.
                let range = made.range
                self.records.removeAll { record in
                    guard record.original == made.original, range.containsTimeRange(record.range) else { return false }
                    try? FileManager.default.removeItem(at: folder.appending(path: record.file))
                    return true
                }
                self.records.append(made)
                Self.writeRecords(self.records, in: self.packageURL!)
                self.refresh()
            } else if made == nil, !Task.isCancelled {
                // A file that can't be copied isn't tried again until the
                // project changes what it uses.
                self.wanted.removeAll { $0 == next }
                self.startIfNeeded()
            }
        }
    }

    // MARK: What is wanted

    /// The stretches of H.264 and HEVC files the timelines' clips use, with
    /// handles, merged where they meet, by file.
    nonisolated static func stretches(in project: EditingProject) -> [Wanted] {
        var byFile: [URL: (name: String, ranges: [CMTimeRange], duration: CMTime)] = [:]
        for timeline in project.timelines {
            for layer in timeline.layers {
                for clip in layer.clips where clip.streams != .audio {
                    guard case .media(let assetID) = clip.source, let asset = project.mediaClip(id: assetID),
                          asset.kind == .video, let url = asset.url, needsCopy(codec: asset.codecName)
                    else { continue }
                    let start = asset.fileTime(forSourceTime: CMTimeMinimum(clip.trimStart, clip.trimEnd))
                    let end = asset.fileTime(forSourceTime: CMTimeMaximum(clip.trimStart, clip.trimEnd))
                    let handle = CMTime(seconds: handleSeconds, preferredTimescale: 600)
                    let range = CMTimeRange(
                        start: CMTimeMaximum(.zero, CMTimeSubtract(start, handle)),
                        end: CMTimeMinimum(asset.duration, CMTimeAdd(end, handle))
                    )
                    guard range.duration > .zero else { continue }
                    let key = url.standardizedFileURL
                    byFile[key, default: (asset.name, [], asset.duration)].ranges.append(range)
                }
            }
        }
        var wanted: [Wanted] = []
        for (url, entry) in byFile.sorted(by: { $0.key.path < $1.key.path }) {
            for range in merged(entry.ranges) {
                wanted.append(Wanted(original: url, name: entry.name, range: range))
            }
        }
        return wanted
    }

    /// Whether footage in `codec` is worth copying: long-GOP codecs, whose
    /// frames decode only from a keyframe before them.
    nonisolated static func needsCopy(codec: String) -> Bool {
        codec == "H.264" || codec == "HEVC"
    }

    /// `ranges` with those that overlap or meet joined.
    nonisolated static func merged(_ ranges: [CMTimeRange]) -> [CMTimeRange] {
        var result: [CMTimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = CMTimeRange(start: last.start, end: CMTimeMaximum(last.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: Copying

    /// Copies `range` of `original`'s picture to `destination`, ProRes at
    /// the original's size and frame times less the first frame's, which
    /// it returns, then reads the copy back and throws unless its frames,
    /// plus that, are at the times written.
    @discardableResult
    nonisolated static func copy(
        _ original: URL, range: CMTimeRange, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CMTime {
        let asset = MediaFile.asset(at: original)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first
        else { throw CancellationError() }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let deep = isDeep(format)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: deep
                ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = range
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: deep ? AVVideoCodecType.proRes422HQ : AVVideoCodecType.proRes422,
            AVVideoWidthKey: Int(natural.width),
            AVVideoHeightKey: Int(natural.height),
        ]
        if let colors = colorProperties(of: format) { settings[AVVideoColorPropertiesKey] = colors }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        guard writer.canAdd(input) else { throw CancellationError() }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? CancellationError() }
        var written: [CMTime] = []
        let length = max(range.duration.seconds, 1e-6)
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if written.isEmpty { writer.startSession(atSourceTime: time) }
                guard input.append(sample) else { throw writer.error ?? CancellationError() }
                written.append(time)
                progress(min(1, (time.seconds - range.start.seconds) / length))
            }
            guard reader.status == .completed, !written.isEmpty else { throw reader.error ?? CancellationError() }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CancellationError() }
        // Read back: every frame where it was written.
        // Read back: every frame where it was written, its first at 0.
        let offset = written.min() ?? .zero
        let copied = try await frameTimes(of: destination)
        guard copied.count == written.count,
              zip(copied, written.sorted()).allSatisfy({ abs(CMTimeAdd($0, offset).seconds - $1.seconds) < 1e-6 })
        else { throw CancellationError() }
        return offset
    }

    /// The presentation times of the frames of `url`'s picture, in order.
    nonisolated static func frameTimes(of url: URL) async throws -> [CMTime] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CancellationError() }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            times.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        return times.sorted()
    }

    /// Whether the footage is deeper than 8 bits or HDR, for 422 HQ.
    nonisolated private static func isDeep(_ format: CMFormatDescription) -> Bool {
        let depth = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int
        if let depth, depth > 8 { return true }
        let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        return transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }

    /// The footage's color tags, carried over to the copy.
    nonisolated private static func colorProperties(of format: CMFormatDescription) -> [String: String]? {
        func tag(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        guard let primaries = tag(kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = tag(kCMFormatDescriptionExtension_TransferFunction),
              let matrix = tag(kCMFormatDescriptionExtension_YCbCrMatrix)
        else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }

    // MARK: Where they are kept

    nonisolated static func folder(in packageURL: URL) -> URL {
        packageURL.appending(path: "Cache/ViewerCopies", directoryHint: .isDirectory)
    }

    nonisolated private static func indexFile(in packageURL: URL) -> URL {
        folder(in: packageURL).appending(path: "index.json")
    }

    nonisolated private static func readRecords(in packageURL: URL) -> [Record] {
        guard let data = try? Data(contentsOf: indexFile(in: packageURL)) else { return [] }
        // The index is a file in the package anyone can edit, and a copy
        // it names is deleted once unused: a record whose file was
        // "../../.." deleted the folder the project is in, and one whose
        // times didn't fit a CMTime trapped. Only plain names of files in
        // the folder, with times that fit, are taken; the rest are
        // forgotten, as a cache can be.
        let records = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
        return records.filter(\.isSound)
    }

    nonisolated private static func writeRecords(_ records: [Record], in packageURL: URL) {
        let folder = folder(in: packageURL)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: indexFile(in: packageURL), options: .atomic) }
    }

    /// Not on battery, in Low Power Mode or with the Mac hot.
    nonisolated static var machineIsFree: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        guard thermal != .serious, thermal != .critical, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        return !isOnBattery
    }

    nonisolated private static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }
}
