import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// A movie of one black frame, for compositions whose pictures are all
/// stills: a composition is as long as its tracks' media, and the player
/// draws only a composition with a video track, so the frame is stretched
/// under the stills on a track no instruction shows (see
/// docs/graphic-layers.md, "How a still is drawn"). Written once to the
/// Caches folder, next to the stereo copies and the silence.
enum BlankFrame {
    static var url: URL { StereoProxies.folder.appending(path: "black-frame.mov") }

    /// The movie, written first if it isn't there. Keep the asset while its
    /// track is used: a track whose asset is gone can't be inserted from.
    static func asset() async throws -> AVURLAsset {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: StereoProxies.folder, withIntermediateDirectories: true)
            // Written under a name of its own and moved into place, so two
            // builds at once never read a half-written movie.
            let partial = StereoProxies.folder.appending(path: "black-frame-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: partial) }
            var failure: String?
            // The encoder now and then fails for reasons of its own.
            for attempt in 1...3 {
                try? FileManager.default.removeItem(at: partial)
                failure = try await write(to: partial)
                if failure == nil { break }
                try await Task.sleep(for: .milliseconds(100 * attempt))
            }
            if let failure { throw CompositionError.exportFailed("Couldn't write a black frame: \(failure)") }
            try? FileManager.default.moveItem(at: partial, to: url)
        }
        return AVURLAsset(url: url)
    }

    /// Nil when written, otherwise what went wrong.
    private static func write(to destination: URL) async throws -> String? {
        let side = 64
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { return writer.error?.localizedDescription ?? "couldn't start" }
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return "no pixel buffer" }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            // Black, opaque: BGRA zeros with alpha at 255.
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<side {
                for x in 0..<side {
                    let offset = y * stride + x * 4
                    bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0; bytes[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var waited = 0
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || waited > 1000 { return writer.error?.localizedDescription ?? "never ready" }
            try await Task.sleep(for: .milliseconds(2))
            waited += 1
        }
        adaptor.append(buffer, withPresentationTime: .zero)
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 24))
        await writer.finishWriting()
        return writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
    }
}
