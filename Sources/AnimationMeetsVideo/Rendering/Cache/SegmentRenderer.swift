import AVFoundation
import Foundation

/// Renders one segment of a timeline into the render cache as ProRes,
/// drawn by the same compositor as export.
enum SegmentRenderer {
    /// `composed` is the timeline built for export. Cancelling the calling
    /// task stops the render and deletes the partial file.
    static func render(
        _ segment: RenderSegment,
        from composed: ComposedTimeline,
        into cache: RenderCache,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let source = composed.composition.mutableCopy() as? AVMutableComposition else {
            throw CompositionError.noExportSession
        }
        // Renders hold pictures only; sound always plays from the sources.
        for track in source.tracks(withMediaType: .audio) {
            source.removeTrack(track)
        }
        guard let session = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetAppleProRes422LPCM) else {
            throw CompositionError.noExportSession
        }
        session.videoComposition = composed.videoComposition
        session.timeRange = segment.range

        let partial = try cache.partialURL(for: segment.key)
        try? FileManager.default.removeItem(at: partial)
        let states = session.states(updateInterval: 0.2)
        let progressTask = Task {
            for await state in states {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        do {
            try await session.export(to: partial, as: .mov)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw CompositionError.exportFailed(error.localizedDescription)
        }
        try cache.finish(segment.key)
    }
}
