import AVFoundation
import CoreMedia
import Foundation

enum ProResPreset: String, CaseIterable, Identifiable {
    case proRes422 = "ProRes 422"
    case proRes4444 = "ProRes 4444"

    var id: Self { self }

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
    case incompatiblePreset
    case noExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: "The timeline has no clips to export."
        case .cyclicTimeline: "This timeline embeds itself, directly or indirectly."
        case .incompatiblePreset: "The selected ProRes preset can't export this timeline."
        case .noExportSession: "Could not create an export session."
        case .exportFailed(let reason): reason
        }
    }
}

/// A composition plus the video-compositing instructions needed to stack
/// its layers — shared by both the live preview player and file export, so
/// what you see while editing is exactly what gets rendered out.
struct ComposedTimeline {
    var composition: AVMutableComposition
    var videoComposition: AVMutableVideoComposition?
}

/// Track metadata for one media file, loaded once and reused across the many
/// rebuilds an editing session triggers.
private struct MediaTrackInfo: @unchecked Sendable {
    let asset: AVURLAsset
    let video: AVAssetTrack?
    let audio: AVAssetTrack?
    let videoRange: CMTimeRange
    let audioRange: CMTimeRange
    /// The track's preferredTransform shifted so the rotated frame's origin
    /// is (0, 0), and the size of the frame after rotation.
    let orientedTransform: CGAffineTransform
    let orientedSize: CGSize
}

private actor MediaTrackCache {
    static let shared = MediaTrackCache()
    private var entries: [URL: MediaTrackInfo] = [:]

    func forget(_ url: URL) {
        entries[url] = nil
    }

    func info(for url: URL) async throws -> MediaTrackInfo {
        if let cached = entries[url] { return cached }

        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first

        var videoRange = CMTimeRange.invalid
        var audioRange = CMTimeRange.invalid
        var transform = CGAffineTransform.identity
        var size = CGSize.zero
        if let video {
            videoRange = try await video.load(.timeRange)
            let natural = try await video.load(.naturalSize)
            let preferred = try await video.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: natural).applying(preferred)
            transform = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            size = rect.size
        }
        if let audio {
            audioRange = try await audio.load(.timeRange)
        }

        let info = MediaTrackInfo(
            asset: asset,
            video: video,
            audio: audio,
            videoRange: videoRange,
            audioRange: audioRange,
            orientedTransform: transform,
            orientedSize: size
        )
        entries[url] = info
        return info
    }
}

/// One piece of media placed at an absolute time in the root timeline, with
/// the transform that fits it into the root's render space.
private struct Placement {
    let info: MediaTrackInfo
    let sourceRange: CMTimeRange
    let start: CMTime
    let transform: CGAffineTransform
}

/// An ordered run of non-overlapping placements that share composition
/// tracks. Nested timelines are flattened into extra layers of the root.
private struct FlatLayer {
    var placements: [Placement] = []
}

private struct VideoSegment {
    let timeRange: CMTimeRange
    let transform: CGAffineTransform
}

private struct VideoLayer {
    let track: AVMutableCompositionTrack
    let segments: [VideoSegment]
}

enum CompositionExporter {
    /// Drops what was read from the file at `url`, for when it was replaced
    /// or changed on disk.
    static func forgetCachedMedia(at url: URL) async {
        await MediaTrackCache.shared.forget(url)
    }

    static func buildComposedTimeline(for project: EditingProject, timelineID: UUID) async throws -> ComposedTimeline {
        guard let timeline = project.timeline(id: timelineID), !timeline.layers.isEmpty else {
            throw CompositionError.emptyTimeline
        }

        let window = CMTimeRange(start: .zero, duration: timeline.duration)
        let flatLayers = try await flatten(
            project: project,
            timelineID: timelineID,
            visiting: [],
            window: window,
            offset: .zero,
            fit: .identity
        )

        let composition = AVMutableComposition()
        var videoLayers: [VideoLayer] = []

        for flat in flatLayers {
            var videoTrack: AVMutableCompositionTrack?
            var audioTrack: AVMutableCompositionTrack?
            var segments: [VideoSegment] = []

            for placement in flat.placements {
                let info = placement.info
                if let sourceVideo = info.video {
                    let range = placement.sourceRange.intersection(info.videoRange)
                    if range.isValid, range.duration > .zero {
                        if videoTrack == nil {
                            videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        let at = CMTimeAdd(placement.start, CMTimeSubtract(range.start, placement.sourceRange.start))
                        try videoTrack?.insertTimeRange(range, of: sourceVideo, at: at)
                        segments.append(VideoSegment(timeRange: CMTimeRange(start: at, duration: range.duration), transform: placement.transform))
                    }
                }
                if let sourceAudio = info.audio {
                    let range = placement.sourceRange.intersection(info.audioRange)
                    if range.isValid, range.duration > .zero {
                        if audioTrack == nil {
                            audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        let at = CMTimeAdd(placement.start, CMTimeSubtract(range.start, placement.sourceRange.start))
                        try audioTrack?.insertTimeRange(range, of: sourceAudio, at: at)
                    }
                }
            }

            if let videoTrack {
                videoLayers.append(VideoLayer(track: videoTrack, segments: segments))
            }
        }

        guard composition.duration > .zero else {
            throw CompositionError.emptyTimeline
        }

        let videoComposition = Self.buildVideoComposition(
            layers: videoLayers,
            overallDuration: composition.duration,
            renderSize: timeline.frameSize,
            frameRate: timeline.frameRate
        )
        return ComposedTimeline(composition: composition, videoComposition: videoComposition)
    }

    /// Resolves a timeline (recursively expanding nested timelines) into flat
    /// layers of media placements at absolute root-timeline times, top layer
    /// first. `window` is the visible range in this timeline's own time,
    /// `offset` maps this timeline's time to root time, and `fit` maps this
    /// timeline's render space into the root's.
    private static func flatten(
        project: EditingProject,
        timelineID: UUID,
        visiting: Set<UUID>,
        window: CMTimeRange,
        offset: CMTime,
        fit: CGAffineTransform
    ) async throws -> [FlatLayer] {
        guard !visiting.contains(timelineID) else {
            throw CompositionError.cyclicTimeline
        }
        guard let timeline = project.timeline(id: timelineID) else { return [] }
        var visiting = visiting
        visiting.insert(timelineID)

        var result: [FlatLayer] = []
        for layer in timeline.layers {
            var own = FlatLayer()
            var nestedLayers: [FlatLayer] = []

            for clip in layer.clips.sorted(by: { $0.startOffset < $1.startOffset }) {
                let placed = CMTimeRange(start: clip.startOffset, duration: clip.trimmedDuration)
                let visible = placed.intersection(window)
                guard visible.isValid, visible.duration > .zero else { continue }
                let intoClip = CMTimeSubtract(visible.start, clip.startOffset)

                switch clip.source {
                case .media(let mediaID):
                    guard let media = project.mediaClip(id: mediaID), let url = media.url else { continue }
                    let info = try await MediaTrackCache.shared.info(for: url)
                    let wanted = CMTimeRange(start: media.fileTime(forSourceTime: CMTimeAdd(clip.trimStart, intoClip)), duration: visible.duration)
                    let transform = info.orientedTransform
                        .concatenating(fitTransform(from: info.orientedSize, to: timeline.frameSize))
                        .concatenating(fit)
                    own.placements.append(Placement(
                        info: info,
                        sourceRange: wanted,
                        start: CMTimeAdd(visible.start, offset),
                        transform: transform
                    ))
                case .timeline(let nestedID):
                    guard let nested = project.timeline(id: nestedID) else { continue }
                    // Nested time = this timeline's time - clip.startOffset + clip.trimStart.
                    let shift = CMTimeSubtract(clip.startOffset, clip.trimStart)
                    let nestedWindow = CMTimeRange(start: CMTimeSubtract(visible.start, shift), duration: visible.duration)
                    let childFit = fitTransform(from: nested.frameSize, to: timeline.frameSize).concatenating(fit)
                    nestedLayers += try await flatten(
                        project: project,
                        timelineID: nestedID,
                        visiting: visiting,
                        window: nestedWindow,
                        offset: CMTimeAdd(offset, shift),
                        fit: childFit
                    )
                }
            }

            if !own.placements.isEmpty { result.append(own) }
            result += nestedLayers
        }
        return result
    }

    /// Scales `source` to fit inside `target` (aspect-preserving) and centers it.
    private static func fitTransform(from source: CGSize, to target: CGSize) -> CGAffineTransform {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .identity }
        let scale = min(target.width / source.width, target.height / source.height)
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
            translationX: (target.width - source.width * scale) / 2,
            y: (target.height - source.height * scale) / 2
        ))
    }

    /// Builds the per-time-range layer stacking instructions. Breakpoints come
    /// from every video segment's start/end across all layers, and a layer
    /// only contributes to a sub-range that one of its segments fully covers
    /// (top layer first). Gaps produce empty instructions, which render black.
    private static func buildVideoComposition(
        layers: [VideoLayer],
        overallDuration: CMTime,
        renderSize: CGSize,
        frameRate: Double
    ) -> AVMutableVideoComposition? {
        guard !layers.isEmpty else { return nil }

        var breakpoints: [CMTime] = [.zero]
        for layer in layers {
            for segment in layer.segments {
                breakpoints.append(segment.timeRange.start)
                breakpoints.append(segment.timeRange.end)
            }
        }
        breakpoints = breakpoints.filter { $0 > .zero && $0 < overallDuration }
        breakpoints.append(.zero)
        breakpoints.sort()
        breakpoints.append(overallDuration)

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for index in 0..<(breakpoints.count - 1) {
            let start = breakpoints[index]
            let end = breakpoints[index + 1]
            guard end > start else { continue }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: start, end: end)
            instruction.layerInstructions = layers.compactMap { layer in
                guard let segment = layer.segments.first(where: { $0.timeRange.start <= start && $0.timeRange.end >= end }) else {
                    return nil
                }
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: layer.track)
                layerInstruction.setTransform(segment.transform, at: start)
                return layerInstruction
            }
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration(for: frameRate)
        videoComposition.instructions = instructions
        return videoComposition
    }

    /// Exact frame durations for the NTSC-family rates (23.976, 29.97, 59.94)
    /// rather than rounding them to 24/30/60.
    private static func frameDuration(for frameRate: Double) -> CMTime {
        let clamped = min(max(frameRate, 1), 1000)
        let rounded = clamped.rounded()
        if abs(clamped - rounded * 1000 / 1001) < 0.01 {
            return CMTime(value: 1001, timescale: Int32(rounded) * 1000)
        }
        return CMTime(value: 1, timescale: Int32(rounded))
    }

    /// Cancelling the calling task cancels the export, deletes the partial
    /// file, and throws `CancellationError`.
    static func export(
        project: EditingProject,
        timelineID: UUID,
        preset: ProResPreset,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let composed = try await buildComposedTimeline(for: project, timelineID: timelineID)

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

        // The save panel already confirmed replacing an existing file, but
        // AVAssetExportSession refuses to write over one.
        try? FileManager.default.removeItem(at: url)

        let states = exportSession.states(updateInterval: 0.2)
        let progressTask = Task {
            for await state in states {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
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
    }
}
