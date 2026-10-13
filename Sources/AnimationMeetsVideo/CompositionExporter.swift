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

private struct LayerTrackInfo {
    let videoTrack: AVMutableCompositionTrack?
    let clips: [TimelineClip]
}

enum CompositionExporter {
    static func buildComposedTimeline(
        for project: EditingProject,
        timelineID: UUID,
        visiting: Set<UUID> = []
    ) async throws -> ComposedTimeline {
        guard !visiting.contains(timelineID) else {
            throw CompositionError.cyclicTimeline
        }
        guard let timeline = project.timeline(id: timelineID) else {
            throw CompositionError.emptyTimeline
        }
        guard !timeline.layers.isEmpty else {
            throw CompositionError.emptyTimeline
        }

        var visiting = visiting
        visiting.insert(timelineID)

        let composition = AVMutableComposition()

        var layerInfos: [LayerTrackInfo] = []

        // Layers are processed top-to-bottom (array order), matching how
        // they'll later be listed in each video composition instruction.
        for layer in timeline.layers {
            let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var sawVideo = false

            for clip in layer.clips {
                let range = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
                let at = clip.startOffset

                switch clip.source {
                case .media(let mediaID):
                    if let mediaClip = project.mediaClip(id: mediaID), let url = mediaClip.url {
                        let asset = AVURLAsset(url: url)
                        if let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first {
                            try videoTrack?.insertTimeRange(range, of: sourceVideoTrack, at: at)
                            sawVideo = true
                        }
                        if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                            try audioTrack?.insertTimeRange(range, of: sourceAudioTrack, at: at)
                        }
                    }
                case .timeline(let nestedID):
                    let nested = try await buildComposedTimeline(for: project, timelineID: nestedID, visiting: visiting)
                    if let sourceVideoTrack = try await nested.composition.loadTracks(withMediaType: .video).first {
                        try videoTrack?.insertTimeRange(range, of: sourceVideoTrack, at: at)
                        sawVideo = true
                    }
                    if let sourceAudioTrack = try await nested.composition.loadTracks(withMediaType: .audio).first {
                        try audioTrack?.insertTimeRange(range, of: sourceAudioTrack, at: at)
                    }
                }
            }

            layerInfos.append(LayerTrackInfo(videoTrack: sawVideo ? videoTrack : nil, clips: layer.clips))
        }

        let videoComposition = Self.buildVideoComposition(
            layerInfos: layerInfos,
            overallDuration: timeline.duration,
            renderSize: timeline.frameSize,
            frameRate: timeline.frameRate
        )

        return ComposedTimeline(composition: composition, videoComposition: videoComposition)
    }

    /// Builds the per-time-range layer stacking instructions. Clips within a
    /// layer can now start anywhere (independent `startOffset`) and leave
    /// gaps, so breakpoints come from every clip's own start/end across all
    /// layers, and a layer only contributes to a sub-range when one of its
    /// clips actually covers it (top layer first).
    private static func buildVideoComposition(
        layerInfos: [LayerTrackInfo],
        overallDuration: CMTime,
        renderSize: CGSize,
        frameRate: Double
    ) -> AVMutableVideoComposition? {
        let videoLayers = layerInfos.filter { $0.videoTrack != nil }
        guard !videoLayers.isEmpty else { return nil }

        let timescale: CMTimeScale = 600
        var breakpointValues: Set<CMTimeValue> = [0]
        for info in videoLayers {
            for clip in info.clips {
                breakpointValues.insert(clip.startOffset.convertScale(timescale, method: .default).value)
                breakpointValues.insert(clip.endOffset.convertScale(timescale, method: .default).value)
            }
        }
        breakpointValues.insert(overallDuration.convertScale(timescale, method: .default).value)
        let breakpoints = breakpointValues.sorted().map { CMTime(value: $0, timescale: timescale) }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        for index in 0..<(breakpoints.count - 1) {
            let start = breakpoints[index]
            let end = breakpoints[index + 1]
            guard end > start else { continue }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: start, end: end)
            instruction.layerInstructions = videoLayers
                .filter { info in
                    info.clips.contains { $0.startOffset <= start && $0.endOffset >= end }
                }
                .compactMap { info in
                    info.videoTrack.map { AVMutableVideoCompositionLayerInstruction(assetTrack: $0) }
                }
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(max(1, frameRate.rounded())))
        videoComposition.instructions = instructions
        return videoComposition
    }

    static func export(project: EditingProject, timelineID: UUID, preset: ProResPreset, to url: URL) async throws {
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

        do {
            try await exportSession.export(to: url, as: .mov)
        } catch {
            throw CompositionError.exportFailed(error.localizedDescription)
        }
    }
}
