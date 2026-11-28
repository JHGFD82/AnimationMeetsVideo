import AVFoundation
import Foundation

/// What the Export button makes: a ProRes movie, or the sound alone as WAV
/// files, the whole mix or one per layer.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case proRes422
    case proRes4444
    case wavMix
    case wavStems

    var id: Self { self }

    var name: String {
        switch self {
        case .proRes422: ProResPreset.proRes422.rawValue
        case .proRes4444: ProResPreset.proRes4444.rawValue
        case .wavMix: "WAV Mix"
        case .wavStems: "WAV Stems"
        }
    }

    /// The movie preset, for a movie.
    var movie: ProResPreset? {
        switch self {
        case .proRes422: .proRes422
        case .proRes4444: .proRes4444
        case .wavMix, .wavStems: nil
        }
    }

    /// The extension the save panel gives the file; nil for stems, which
    /// are saved in a folder.
    var fileExtension: String? {
        switch self {
        case .proRes422, .proRes4444: "mov"
        case .wavMix: "wav"
        case .wavStems: nil
        }
    }
}

/// The sound tracks a movie export has: the mix alone, or the mix and then
/// a stereo track for each layer with sound, for a mixer to rework.
enum ExportAudioTracks: String, CaseIterable, Identifiable, Sendable {
    case mix
    case mixAndStems

    var id: Self { self }

    var name: String {
        switch self {
        case .mix: "Mix"
        case .mixAndStems: "Mix and Stems"
        }
    }
}

/// Exports a timeline's sound as 24-bit WAV files at 48 kHz, read out of
/// the composition through its audio mix as playback hears it. See
/// docs/audio.md, "Exporting sound".
enum AudioExport {
    /// The files' format: 24-bit integers, stereo, 48 kHz.
    static var fileSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: LoudnessMastering.sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 24,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ] }

    /// The whole mix to `url`, mastered to `loudness` (see
    /// `LoudnessMastering`) unless that is as mixed. Returns what mastering
    /// did, when it did.
    @discardableResult
    static func exportMix(
        project: EditingProject, timelineID: UUID, loudness: LoudnessTarget, to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> LoudnessMastering.Report? {
        try ExportDestinations.refuseMediaFile(at: url, in: project)
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: timelineID)
        guard !composed.audioTracks.isEmpty else { throw CompositionError.exportFailed("The timeline has no sound.") }
        let curves = MixCurves(MixCurves.of(project))
        var gain = 0.0
        var limiting = false
        var measured = Loudness.silence
        if let target = loudness.lufs {
            measured = try await LoudnessMastering.measure(composed, curves: curves) { progress($0 / 2) }.integrated
            if measured.isFinite {
                gain = target - measured
                limiting = true
            }
        }
        let share = loudness.lufs == nil ? 1.0 : 0.5
        // Replacing it was confirmed, and no other export saves here (see
        // CompositionExporter.export); what is there stays until this has
        // finished beside it.
        let partial = ExportFile.partial(for: url)
        do {
            let rendered = try await LoudnessMastering.render(
                composed, curves: curves, gain: gain, limiting: limiting, to: partial, fileSettings: fileSettings,
                progress: { progress(1 - share + $0 * share) }
            )
            try ExportFile.finish(partial, at: url)
            return limiting ? LoudnessMastering.Report(measured: measured, gain: gain, rendered: rendered) : nil
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// The file each layer of the timeline with sound would be exported
    /// to in `folder` by `exportStems`, in layer order: named for the
    /// export and the layer, with a number after a name another layer has
    /// taken, told apart without case as the Mac's volumes are by default.
    /// A layer whose sound comes to nothing when exported has a name here
    /// but no file.
    static func stemFiles(
        project: EditingProject, timelineID: UUID, named name: String, in folder: URL, asWAV: Bool = true
    ) -> [(layer: TimelineLayer, url: URL)] {
        guard let timeline = project.timeline(id: timelineID) else { return [] }
        let layers = timeline.layers.filter { project.layerPlaysAudio($0) }
        var used: Set<String> = []
        return layers.enumerated().map { number, layer in
            let base = "\(name) - \(project.displayName(of: layer, in: timeline))"
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            var file = base
            var suffix = number + 1
            while used.contains(file.lowercased()) {
                file = "\(base) \(suffix)"
                suffix += 1
            }
            used.insert(file.lowercased())
            return (layer, folder.appending(path: file + (asWAV ? ".wav" : ".caf")))
        }
    }

    /// The files of `stems` already there, which exporting them would
    /// replace.
    static func existingFiles(among stems: [URL]) -> [URL] {
        stems.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Throws unless every file of `urls` already there is one of
    /// `replacing`, those the person agreed to replace: otherwise a stem
    /// replaces a file of the same name in the folder unasked
    /// (code-review-notes.md, F72).
    private static func refuseUnconfirmedReplacements(of urls: [URL], in folder: URL, replacing: [URL]) throws {
        let agreed = Set(replacing.map { $0.standardizedFileURL.path.lowercased() })
        let unasked = existingFiles(among: urls).filter { !agreed.contains($0.standardizedFileURL.path.lowercased()) }
        guard let first = unasked.first else { return }
        let what = unasked.count == 1
            ? "\u{201C}\(first.lastPathComponent)\u{201D} is"
            : "\u{201C}\(first.lastPathComponent)\u{201D} and \(unasked.count - 1) more of the stems' files are"
        throw CompositionError.exportFailed(
            "\(what) already in \u{201C}\(folder.lastPathComponent)\u{201D}, and nobody agreed to replace them. Export the stems again to be asked, or into another folder."
        )
    }

    /// One file per layer of the timeline that has sound, in `folder`,
    /// each with only that layer playing: its clips, its volume and pan,
    /// and everything in the timelines nested on it. Not mastered, so the
    /// stems add up to the mix. Named as `stemFiles` names them; returns
    /// the files in layer order. A file already in the folder is replaced
    /// only if it is one of `replacing`, which Export… asks about; any
    /// other is refused, before anything is rendered and again before the
    /// stems are put in place, since files can arrive meanwhile. Each is
    /// written beside its place and put there once every stem is done, so
    /// on an error or a stop the stems already in the folder stay as they
    /// were; what it wrote is deleted, and the folder too if it made it
    /// and nothing else is in it.
    @discardableResult
    static func exportStems(
        project: EditingProject, timelineID: UUID, named name: String, in folder: URL, asWAV: Bool = true,
        replacing: [URL] = [],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [URL] {
        guard let index = project.timelines.firstIndex(id: timelineID) else { return [] }
        let stems = stemFiles(project: project, timelineID: timelineID, named: name, in: folder, asWAV: asWAV)
        guard !stems.isEmpty else { throw CompositionError.exportFailed("The timeline has no sound.") }
        try refuseUnconfirmedReplacements(of: stems.map(\.url), in: folder, replacing: replacing)
        let madeFolder = !FileManager.default.fileExists(atPath: folder.path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        var partials: [URL] = []
        do {
            for (number, stem) in stems.enumerated() {
                var solo = project
                solo.timelines[index].layers = [stem.layer]
                let composed = try await CompositionExporter.buildComposedTimeline(for: solo, timelineID: timelineID)
                guard !composed.audioTracks.isEmpty else { continue }
                let url = stem.url
                try ExportDestinations.refuseMediaFile(at: url, in: project)
                let partial = ExportFile.partial(for: url)
                let done = Double(number), count = Double(stems.count)
                partials.append(partial)
                try await LoudnessMastering.render(
                    composed, curves: MixCurves(MixCurves.of(solo)), limiting: false, to: partial, fileSettings: asWAV ? fileSettings : nil,
                    progress: { progress((done + $0) / count) }
                )
                files.append(url)
            }
            // Files can have arrived in the folder while the stems rendered.
            try refuseUnconfirmedReplacements(of: files, in: folder, replacing: replacing)
            for (partial, url) in zip(partials, files) { try ExportFile.finish(partial, at: url) }
        } catch {
            // Only what this export wrote: the folder may be one the person
            // picked, with other files in it. A stem already put in place is
            // whole, and stays.
            for partial in partials { try? FileManager.default.removeItem(at: partial) }
            if madeFolder, (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
            throw error
        }
        return files
    }
}
