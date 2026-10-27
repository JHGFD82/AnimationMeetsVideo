import AVFoundation
import CoreMedia
import Foundation

import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

enum ProResPreset: String, CaseIterable, Identifiable {
    case proRes422 = "ProRes 422"
    case proRes4444 = "ProRes 4444"

    var id: Self { self }

    /// Whether exports in this format may use the render cache, whose
    /// renders are ProRes 422.
    var reusesRenders: Bool { self == .proRes422 }

    var avPresetName: String {
        switch self {
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        case .proRes4444: AVAssetExportPresetAppleProRes4444LPCM
        }
    }
}

enum CompositionError: LocalizedError {
    case emptyTimeline
    case cyclicTimeline
    /// A clip's file isn't there; carries the asset's name.
    case missingMedia(String)
    /// Text is set in a font this Mac doesn't have; carries its name.
    case missingFont(String)
    case incompatiblePreset
    case noExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: "The timeline has no clips to export."
        case .cyclicTimeline: "This timeline embeds itself, directly or indirectly."
        case .missingMedia(let name): "\u{201C}\(name)\u{201D} is missing, so the timeline can't be exported. Put the file back, or replace it from the Clips list in the browser."
        case .missingFont(let name): "The font \u{201C}\(name)\u{201D} isn't installed, so text set in it can't be exported as it was designed. Install the font, or pick another in the inspector."
        case .incompatiblePreset: "The selected ProRes preset can't export this timeline."
        case .noExportSession: "Could not create an export session."
        case .exportFailed(let reason): reason
        }
    }
}

enum CompositionExporter {
    /// Set while building for the viewer: a clip whose file is missing is
    /// left out, as a gap, so the rest of the timeline can still be
    /// watched. Export and background renders stop on it instead
    /// (`CompositionError.missingMedia`), so a gap is never written out.
    @TaskLocal static var skipsMissingMedia = false

    /// Drops what was read from the file at `url`, for when it was replaced
    /// or changed on disk.
    static func forgetCachedMedia(at url: URL) async {
        await MediaTrackCache.shared.forget(url)
        await StillImages.shared.forget(url)
    }

    /// With `forPreview` the viewer may draw at a reduced size, so every
    /// stretch is drawn by the compositor, which has `meter` hear how long
    /// each frame took. Segments already rendered into `cache` play from
    /// there.
    static func buildComposedTimeline(
        for project: EditingProject,
        timelineID: UUID,
        forPreview: Bool = false,
        meter: RenderMeter? = nil,
        options: DrawingOptions? = nil,
        cache: RenderCache? = nil
    ) async throws -> ComposedTimeline {
        // Slivers of gap between clips (a retimed clip's end can't be found
        // closer than a few microseconds) would draw black frames.
        // Disabled clips play as gaps, so the timeline keeps its length
        // when one is at the end.
        let length = project.timeline(id: timelineID)?.duration ?? .zero
        var project = project
        for index in project.timelines.indices {
            project.timelines[index] = project.timelines[index].withoutDisabledClips().closingSlivers()
        }
        guard let timeline = project.timeline(id: timelineID), !timeline.layers.isEmpty else {
            throw CompositionError.emptyTimeline
        }
        // As with missing media, the viewer draws a substitute and export
        // stops, so a substitute font is never written out.
        if !forPreview, let font = project.missingFonts(in: timelineID).first {
            throw CompositionError.missingFont(font)
        }

        // A build no longer wanted (the viewer moved to another timeline)
        // stops at each stage rather than finishing for nothing.
        try Task.checkCancellation()
        // Matte wipes' maps are read before drawing starts.
        await MatteMaps.shared.load(for: project)
        try Task.checkCancellation()
        let window = CMTimeRange(start: .zero, duration: length)
        var hosts: [TrackHost] = []
        let nodes = try await $skipsMissingMedia.withValue(forPreview) {
            try await flatten(
                project: project,
                timelineID: timelineID,
                visiting: [],
                window: window,
                offset: .zero,
                outerVolume: [],
                rootClipID: nil,
                hosts: &hosts
            )
        }

        let composition = AVMutableComposition()
        var audioTracks: [ComposedAudioTrack] = []
        /// A stretch of some source's picture, to fill time after the last clip.
        var filler: (track: AVAssetTrack, range: CMTimeRange)?
        let mix = MixCurves.of(project)
        /// Where the last sound ends, as placed, before any is moved earlier.
        var soundEnd = CMTime.zero
        /// Clips and layers with a pan; mono sound played through any of
        /// them plays from a stereo copy, which can be panned.
        let panned = Set(mix.pan.keys)

        for host in hosts {
            try Task.checkCancellation()
            var videoTrack: AVMutableCompositionTrack?
            var audioTrack: AVMutableCompositionTrack?
            let pans = host.volume.contains { $0.fade == nil && panned.contains($0.id) }
            // The sound effects it plays through hold it back; it starts
            // that much earlier, so it is heard where it was placed.
            let latency = host.volume.filter { $0.fade == nil }
                .flatMap { mix.effects[$0.id] ?? [] }
                .reduce(0) { $0 + AudioEffectUnit.latency(of: $1.kind) }
            let ahead = CMTime(seconds: latency, preferredTimescale: 96_000)

            for placement in host.placements {
                let info = placement.info
                var audioInfo = info
                if pans, placement.includesAudio, info.audioChannels == 1 {
                    do {
                        if let stereo = try await StereoProxies.stereo(for: info) { audioInfo = stereo }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Without its copy the sound plays centered.
                    }
                }
                if let sourceVideo = info.video, placement.includesVideo {
                    var playing: CMTimeRange?
                    for piece in placement.pieces {
                        guard let (file, at, length) = piece.within(info.videoRange) else { continue }
                        if videoTrack == nil {
                            videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        try videoTrack?.insertTimeRange(file, of: sourceVideo, at: at)
                        // Retimed footage plays faster or slower than it was
                        // shot.
                        if length != file.duration {
                            videoTrack?.scaleTimeRange(CMTimeRange(start: at, duration: file.duration), toDuration: length)
                        }
                        if filler == nil { filler = (sourceVideo, file) }
                        if playing == nil { placement.drawSourceStart = file.start }
                        let played = CMTimeRange(start: at, duration: length)
                        playing = playing.map { $0.union(played) } ?? played
                    }
                    if let playing {
                        placement.trackID = videoTrack?.trackID ?? kCMPersistentTrackID_Invalid
                        placement.drawRange = playing
                    }
                }
                if let sourceAudio = audioInfo.audio, placement.includesAudio {
                    for piece in placement.pieces {
                        guard let placed = piece.within(audioInfo.audioRange) else { continue }
                        soundEnd = CMTimeMaximum(soundEnd, CMTimeAdd(placed.at, placed.length))
                        guard let (file, at, length) = Self.moved(placed, earlierBy: ahead) else { continue }
                        if audioTrack == nil {
                            audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        try audioTrack?.insertTimeRange(file, of: sourceAudio, at: at)
                        if length != file.duration {
                            audioTrack?.scaleTimeRange(CMTimeRange(start: at, duration: file.duration), toDuration: length)
                        }
                    }
                }
            }

            if let audioTrack {
                audioTracks.append(ComposedAudioTrack(track: audioTrack, stages: host.volume, pitch: host.pitch, latency: latency))
            }
        }

        let tree = nodes.compactMap { $0.frozen() }
        // Stills have no track, so with no footage there is nothing to give
        // the composition pictures or a length: a black frame stands in.
        var blank: AVURLAsset?
        if filler == nil, !tree.isEmpty {
            blank = try await BlankFrame.asset()
            if let blank, let track = try await blank.loadTracks(withMediaType: .video).first {
                filler = (track, try await track.load(.timeRange))
            }
        }
        guard composition.duration > .zero || blank != nil else {
            throw CompositionError.emptyTimeline
        }
        // Sound moved earlier for its effects' delay mustn't end the
        // composition early, or what the effects still hold is never heard.
        if composition.duration < soundEnd {
            try await padSound(of: composition, to: soundEnd)
        }
        // Sections and disabled clips can run past the last clip. A
        // composition ends with its last media (an empty edit at the end
        // doesn't count), so a frame of some source is stretched over the
        // rest on a track of its own. No
        // instruction shows that track, so the stretch plays as black. The
        // black frame for stills covers everything, so there is always a
        // video track to draw, however long the sound runs.
        if composition.duration < length || blank != nil, let filler,
           let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let gap = blank != nil
                ? CMTimeRange(start: .zero, end: CMTimeMaximum(composition.duration, length))
                : CMTimeRange(start: composition.duration, end: length)
            let piece = CMTimeRange(start: filler.range.start, duration: CMTimeMinimum(filler.range.duration, frameDuration(for: timeline.frameRate)))
            try withExtendedLifetime(blank) {
                try track.insertTimeRange(piece, of: filler.track, at: gap.start)
            }
            track.scaleTimeRange(CMTimeRange(start: gap.start, duration: piece.duration), toDuration: gap.duration)
        }
        guard composition.duration > .zero else {
            throw CompositionError.emptyTimeline
        }

        try Task.checkCancellation()
        var plan = planRanges(
            tree: tree, overallDuration: composition.duration, allowsPassthrough: !forPreview,
            frameSize: timeline.frameSize, frameRate: timeline.frameRate, colorSpace: timeline.colorSpace,
            canvasMargin: project.canvasMargin
        )
        let canvasMargin = project.canvasMargin
        var cachedKeys: Set<String> = []
        let unrenderedPlan = plan
        if let cache {
            cachedKeys = try await substituteCachedRanges(
                &plan, from: cache, into: composition, frame: frameDuration(for: timeline.frameRate)
            )
        }

        try Task.checkCancellation()
        let videoComposition = Self.buildVideoComposition(
            plan: plan,
            hasPictures: !tree.isEmpty,
            renderSize: timeline.frameSize,
            frameRate: timeline.frameRate,
            colorSpace: timeline.colorSpace,
            forPreview: forPreview,
            canvasMargin: canvasMargin,
            meter: meter,
            options: options,
            background: timeline.previewBackground
        )
        // The same timeline drawing every stretch from its clips, which the
        // composition still holds the tracks of, for a drag to follow
        // without swapping the item (see `PlaybackModel.playWithoutRenders`).
        let unrendered = cachedKeys.isEmpty ? nil : Self.buildVideoComposition(
            plan: unrenderedPlan,
            hasPictures: !tree.isEmpty,
            renderSize: timeline.frameSize,
            frameRate: timeline.frameRate,
            colorSpace: timeline.colorSpace,
            forPreview: forPreview,
            canvasMargin: canvasMargin,
            meter: meter,
            options: options,
            background: timeline.previewBackground
        )
        return ComposedTimeline(
            composition: composition, videoComposition: videoComposition,
            segments: plan.map(\.segment), cachedKeys: cachedKeys, audioTracks: audioTracks,
            unrenderedVideoComposition: unrendered
        )
    }

    /// Fills a composition's sound out to `end` with silence on a track of
    /// its own: an empty stretch at the end doesn't count toward its length,
    /// but silence does, and the other tracks' taps run on through it.
    static func padSound(of composition: AVMutableComposition, to end: CMTime) async throws {
        // 16-bit: silence needs no more.
        let silence = StereoProxies.folder.appending(path: "silence-16.caf")
        if !FileManager.default.fileExists(atPath: silence.path) {
            try FileManager.default.createDirectory(at: StereoProxies.folder, withIntermediateDirectories: true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)
            else { return }
            buffer.frameLength = 48_000
            for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: 48_000) }
            let partial = StereoProxies.folder.appending(path: "silence-\(UUID().uuidString).caf")
            try AVAudioFile(forWriting: partial, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)
            try? FileManager.default.moveItem(at: partial, to: silence)
            try? FileManager.default.removeItem(at: partial)
        }
        // Kept while its track is used: a track whose asset is gone can't
        // be inserted from.
        let asset = AVURLAsset(url: silence)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }
        var at = composition.duration
        try withExtendedLifetime(asset) {
            while at < end {
                let length = CMTimeMinimum(CMTimeSubtract(end, at), CMTime(value: 1, timescale: 1))
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: at)
                at = CMTimeAdd(at, length)
            }
        }
    }

    /// A stretch of sound placed `earlier` before where it plays, for effects
    /// that hold it back that long. What would fall before the start of the
    /// timeline is left out, in proportion for retimed sound. Nil when none
    /// is left.
    static func moved(
        _ piece: (file: CMTimeRange, at: CMTime, length: CMTime), earlierBy earlier: CMTime
    ) -> (file: CMTimeRange, at: CMTime, length: CMTime)? {
        guard earlier > .zero else { return piece }
        let at = CMTimeSubtract(piece.at, earlier)
        guard at < .zero else { return (piece.file, at, piece.length) }
        let cut = CMTimeMultiplyByFloat64(at, multiplier: -1)
        guard cut < piece.length else { return nil }
        let fileCut = CMTimeMultiplyByFloat64(cut, multiplier: piece.file.duration.seconds / piece.length.seconds)
        return (
            CMTimeRange(start: CMTimeAdd(piece.file.start, fileCut), duration: CMTimeSubtract(piece.file.duration, fileCut)),
            .zero, CMTimeSubtract(piece.length, cut)
        )
    }

    /// Lays `composed`'s sound out as the mix on one track, then a stem for
    /// each layer with sound on a track each, rendered into `scratch`. The
    /// mix is rendered too unless `mixed` (mastered already). Returns the
    /// stems' files; none when the timeline has no sound.
    static func addStems(
        to composed: ComposedTimeline, project: EditingProject, timelineID: UUID, curves: MixCurves, mixed: Bool, in scratch: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [URL] {
        guard !composed.audioTracks.isEmpty else { return [] }
        let length = composed.composition.duration
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        if !mixed {
            let mix = scratch.appending(path: "mix.caf")
            try await LoudnessMastering.render(composed, curves: curves, limiting: false, to: mix) { progress($0 / 3) }
            try await LoudnessMastering.replaceAudio(of: composed.composition, with: mix)
        }
        let stems = try await AudioExport.exportStems(
            project: project, timelineID: timelineID, named: "stem", in: scratch, asWAV: false,
            progress: { progress(1.0 / 3 + $0 * 2 / 3) }
        )
        for stem in stems { try await LoudnessMastering.addAudio(to: composed.composition, from: stem, upTo: length) }
        return stems
    }

    /// Cancelling the calling task cancels the export, deletes the partial
    /// file, and throws `CancellationError`. A ProRes 422 export plays the
    /// stretches already rendered into `cache` from there instead of
    /// compositing them again; renders are ProRes 422 themselves, so a 4444
    /// export always composites from the sources to keep its extra detail.
    /// With a loudness target other than as mixed, the sound is mastered
    /// to it first (`LoudnessMastering`), which takes the first tenth of
    /// the progress. Returns how many rendered segments were reused.
    @discardableResult
    static func export(
        project: EditingProject,
        timelineID: UUID,
        preset: ProResPreset,
        loudness: LoudnessTarget = .asMixed,
        audioTracks: ExportAudioTracks = .mix,
        to url: URL,
        cache: RenderCache? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        onMastered: @escaping @Sendable (LoudnessMastering.Report) -> Void = { _ in }
    ) async throws -> Int {
        let composed = try await buildComposedTimeline(
            for: project, timelineID: timelineID, cache: preset.reusesRenders ? cache : nil
        )
        let curves = MixCurves(MixCurves.of(project))
        let mastered = try await LoudnessMastering.master(
            composed, curves: curves, to: loudness, in: FileManager.default.temporaryDirectory,
            progress: { progress($0 / 10) }
        )
        defer { mastered.map { try? FileManager.default.removeItem(at: $0.file) } }
        if let mastered { onMastered(mastered.report) }
        // Stems go on tracks of their own after the mix, which then has to
        // be a track of its own too, rendered unless it was mastered.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let rendered = audioTracks == .mixAndStems
            ? try await addStems(to: composed, project: project, timelineID: timelineID, curves: curves, mixed: mastered != nil, in: scratch) {
                progress(0.1 + 0.1 * $0)
            }
            : []
        let premixed = mastered != nil || !rendered.isEmpty
        let exportShare = rendered.isEmpty ? (mastered == nil ? 1.0 : 0.9) : 0.8

        let isCompatible = await AVAssetExportSession.compatibility(
            ofExportPreset: preset.avPresetName,
            with: composed.composition,
            outputFileType: .mov
        )
        guard isCompatible else {
            throw CompositionError.incompatiblePreset
        }

        guard let exportSession = AVAssetExportSession(asset: composed.composition, presetName: preset.avPresetName) else {
            throw CompositionError.noExportSession
        }
        exportSession.videoComposition = composed.videoComposition
        // Mastered or rendered sound is already mixed, in tracks of its own.
        exportSession.audioMix = premixed ? nil : composed.audioMix(curves: curves)

        // The save panel already confirmed replacing an existing file, but
        // AVAssetExportSession refuses to write over one.
        try? FileManager.default.removeItem(at: url)

        let states = exportSession.states(updateInterval: 0.2)
        let progressTask = Task {
            for await state in states {
                if case .exporting(let exportProgress) = state {
                    progress(1 - exportShare + exportProgress.fractionCompleted * exportShare)
                }
            }
        }
        defer { progressTask.cancel() }

        do {
            try await exportSession.export(to: url, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw CompositionError.exportFailed(error.localizedDescription)
        }
        return composed.cachedKeys.count
    }
}
