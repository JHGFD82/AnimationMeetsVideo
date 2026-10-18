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
    /// `LoudnessMastering`) unless that is as mixed.
    static func exportMix(
        project: EditingProject, timelineID: UUID, loudness: LoudnessTarget, to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: timelineID)
        guard !composed.audioTracks.isEmpty else { throw CompositionError.exportFailed("The timeline has no sound.") }
        let curves = MixCurves(MixCurves.of(project))
        var gain = 0.0
        var limiting = false
        if let target = loudness.lufs {
            let measured = try await LoudnessMastering.measure(composed, curves: curves) { progress($0 / 2) }.integrated
            if measured.isFinite {
                gain = target - measured
                limiting = true
            }
        }
        let share = loudness.lufs == nil ? 1.0 : 0.5
        try? FileManager.default.removeItem(at: url)
        do {
            try await LoudnessMastering.render(
                composed, curves: curves, gain: gain, limiting: limiting, to: url, fileSettings: fileSettings,
                progress: { progress(1 - share + $0 * share) }
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// One file per layer of the timeline that has sound, in `folder`,
    /// each with only that layer playing: its clips, its volume and pan,
    /// and everything in the timelines nested on it. Not mastered, so the
    /// stems add up to the mix. Named for the export and the layer; returns
    /// the files in layer order.
    @discardableResult
    static func exportStems(
        project: EditingProject, timelineID: UUID, named name: String, in folder: URL, asWAV: Bool = true,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [URL] {
        guard let timeline = project.timeline(id: timelineID),
              let index = project.timelines.firstIndex(where: { $0.id == timelineID })
        else { return [] }
        let layers = timeline.layers.filter { project.layerPlaysAudio($0) }
        guard !layers.isEmpty else { throw CompositionError.exportFailed("The timeline has no sound.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var used: Set<String> = []
        var files: [URL] = []
        for (number, layer) in layers.enumerated() {
            var solo = project
            solo.timelines[index].layers = [layer]
            let composed = try await CompositionExporter.buildComposedTimeline(for: solo, timelineID: timelineID)
            guard !composed.audioTracks.isEmpty else { continue }
            var file = "\(name) - \(project.displayName(of: layer, in: timeline))"
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if used.contains(file) { file += " \(number + 1)" }
            used.insert(file)
            let url = folder.appending(path: file + (asWAV ? ".wav" : ".caf"))
            try? FileManager.default.removeItem(at: url)
            let done = Double(number), count = Double(layers.count)
            try await LoudnessMastering.render(
                composed, curves: MixCurves(MixCurves.of(solo)), limiting: false, to: url, fileSettings: asWAV ? fileSettings : nil,
                progress: { progress((done + $0) / count) }
            )
            files.append(url)
        }
        return files
    }
}
