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

/// A layer's transform as seen from the root timeline: one nesting level of
/// a placement's animation.
struct TransformStage {
    var transform: LayerTransform
    /// Center of the frame of the timeline the layer is in.
    var center: CGPoint
    /// Root time minus that timeline's time.
    var shift: CMTime
    /// Fits that timeline's frame into the frame of the next stage out
    /// (identity at the root).
    var toOuter: CGAffineTransform
}

/// Where a placement is drawn and how opaque it is at each root time: its
/// own fit, then each enclosing layer's transform from innermost out.
struct PlacementAnimation {
    /// Orients and fits the media into the frame of its own timeline.
    var base: CGAffineTransform
    var stages: [TransformStage]

    func transform(at time: CMTime) -> CGAffineTransform {
        stages.reduce(base) { result, stage in
            result
                .concatenating(stage.transform.affineTransform(at: CMTimeSubtract(time, stage.shift), center: stage.center))
                .concatenating(stage.toOuter)
        }
    }

    func opacity(at time: CMTime) -> Float {
        Float(stages.reduce(1.0) { $0 * $1.transform.opacityFraction(at: CMTimeSubtract(time, $1.shift)) })
    }

    /// Root-time ranges where some stage is between keyframes, in order and
    /// not overlapping. Outside them the transform and opacity are constant.
    var animatedRanges: [CMTimeRange] {
        let ranges = stages.flatMap { stage in
            stage.transform.animatedRanges.map { range in
                CMTimeRange(start: CMTimeAdd(range.lowerBound, stage.shift), end: CMTimeAdd(range.upperBound, stage.shift))
            }
        }
        var merged: [CMTimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = CMTimeRange(start: last.start, end: CMTimeMaximum(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// One piece of media placed at an absolute time in the root timeline, with
/// the animation that places it in the root's render space.
private struct Placement {
    let info: MediaTrackInfo
    let sourceRange: CMTimeRange
    let start: CMTime
    let animation: PlacementAnimation
    /// Which of the file's streams to use; detached audio and its picture
    /// each play only one.
    let includesVideo: Bool
    let includesAudio: Bool
}

/// An ordered run of non-overlapping placements that share composition
/// tracks. Nested timelines are flattened into extra layers of the root.
private struct FlatLayer {
    var placements: [Placement] = []
}

private struct VideoSegment {
    let timeRange: CMTimeRange
    let animation: PlacementAnimation
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
            outer: [],
            toOuter: .identity
        )

        let composition = AVMutableComposition()
        var videoLayers: [VideoLayer] = []

        for flat in flatLayers {
            var videoTrack: AVMutableCompositionTrack?
            var audioTrack: AVMutableCompositionTrack?
            var segments: [VideoSegment] = []

            for placement in flat.placements {
                let info = placement.info
                if let sourceVideo = info.video, placement.includesVideo {
                    let range = placement.sourceRange.intersection(info.videoRange)
                    if range.isValid, range.duration > .zero {
                        if videoTrack == nil {
                            videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        let at = CMTimeAdd(placement.start, CMTimeSubtract(range.start, placement.sourceRange.start))
                        try videoTrack?.insertTimeRange(range, of: sourceVideo, at: at)
                        segments.append(VideoSegment(timeRange: CMTimeRange(start: at, duration: range.duration), animation: placement.animation))
                    }
                }
                if let sourceAudio = info.audio, placement.includesAudio {
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
    /// `offset` maps this timeline's time to root time, `outer` holds the
    /// transforms of the layers this timeline is nested in (innermost
    /// first), and `toOuter` fits this timeline's frame into the frame of
    /// the innermost of them.
    private static func flatten(
        project: EditingProject,
        timelineID: UUID,
        visiting: Set<UUID>,
        window: CMTimeRange,
        offset: CMTime,
        outer: [TransformStage],
        toOuter: CGAffineTransform
    ) async throws -> [FlatLayer] {
        guard !visiting.contains(timelineID) else {
            throw CompositionError.cyclicTimeline
        }
        guard let timeline = project.timeline(id: timelineID) else { return [] }
        var visiting = visiting
        visiting.insert(timelineID)

        let center = CGPoint(x: timeline.frameSize.width / 2, y: timeline.frameSize.height / 2)
        var result: [FlatLayer] = []
        for layer in timeline.layers {
            let stages = [TransformStage(transform: layer.transform, center: center, shift: offset, toOuter: toOuter)] + outer
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
                    let base = info.orientedTransform
                        .concatenating(fitTransform(from: info.orientedSize, to: timeline.frameSize))
                    own.placements.append(Placement(
                        info: info,
                        sourceRange: wanted,
                        start: CMTimeAdd(visible.start, offset),
                        animation: PlacementAnimation(base: base, stages: stages),
                        includesVideo: clip.streams != .audio,
                        includesAudio: clip.streams != .video
                    ))
                case .timeline(let nestedID):
                    guard let nested = project.timeline(id: nestedID) else { continue }
                    // Nested time = this timeline's time - clip.startOffset + clip.trimStart.
                    let shift = CMTimeSubtract(clip.startOffset, clip.trimStart)
                    let nestedWindow = CMTimeRange(start: CMTimeSubtract(visible.start, shift), duration: visible.duration)
                    nestedLayers += try await flatten(
                        project: project,
                        timelineID: nestedID,
                        visiting: visiting,
                        window: nestedWindow,
                        offset: CMTimeAdd(offset, shift),
                        outer: stages,
                        toOuter: fitTransform(from: nested.frameSize, to: timeline.frameSize)
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

        let frame = frameDuration(for: frameRate)
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
                applyAnimation(segment.animation, to: layerInstruction, in: CMTimeRange(start: start, end: end), frame: frame)
                return layerInstruction
            }
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frame
        videoComposition.instructions = instructions
        return videoComposition
    }

    private static func frameDuration(for frameRate: Double) -> CMTime {
        Timeline.frameDuration(for: frameRate)
    }

    /// Sets the transform and opacity at the start of `range`, then again on
    /// every frame where a keyframed stage is changing. The built-in
    /// compositor holds each value until the next one, so the result is
    /// exact at every rendered frame. Matrix ramps aren't used because they
    /// blend matrix entries, which shrinks a layer midway through a turn.
    static func applyAnimation(
        _ animation: PlacementAnimation,
        to instruction: AVMutableVideoCompositionLayerInstruction,
        in range: CMTimeRange,
        frame: CMTime
    ) {
        var lastTransform = animation.transform(at: range.start)
        var lastOpacity = animation.opacity(at: range.start)
        instruction.setTransform(lastTransform, at: range.start)
        instruction.setOpacity(lastOpacity, at: range.start)
        guard frame.seconds > 0 else { return }

        var lastSet = range.start
        for animated in animation.animatedRanges {
            // One frame past the last keyframe, so the final value lands.
            let span = CMTimeRange(start: animated.start, end: CMTimeAdd(animated.end, frame)).intersection(range)
            guard span.isValid, span.duration > .zero else { continue }
            var index = Int64((span.start.seconds / frame.seconds).rounded(.up))
            while true {
                let time = CMTime(value: index * frame.value, timescale: frame.timescale)
                guard time < span.end else { break }
                index += 1
                guard time > lastSet else { continue }
                lastSet = time
                let transform = animation.transform(at: time)
                let opacity = animation.opacity(at: time)
                if transform != lastTransform {
                    instruction.setTransform(transform, at: time)
                    lastTransform = transform
                }
                if opacity != lastOpacity {
                    instruction.setOpacity(opacity, at: time)
                    lastOpacity = opacity
                }
            }
        }
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
