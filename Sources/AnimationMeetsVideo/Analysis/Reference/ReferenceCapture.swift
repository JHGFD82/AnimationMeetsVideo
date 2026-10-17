import AVFoundation
import CoreMedia
import Foundation

/// Reads the reference data for an asset's original file: a metadata snapshot
/// and the audio envelope. Done at import, because it's the only chance to
/// look at the original.
enum ReferenceCapture {
    /// Audio is read at this rate; 100 windows a second of 80 samples each.
    private static let sampleRate = 8000

    static func capture(url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AssetReference {
        let work = Task.detached(priority: .utility) { () -> AssetReference in
            let metadata = try await metadata(for: url)
            let envelope = metadata.hasAudio ? try await audioEnvelope(url: url, progress: progress) : nil
            return AssetReference(metadata: metadata, audioEnvelope: envelope)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func metadata(for url: URL) async throws -> AssetMetadataSnapshot {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        guard let primary = videoTrack ?? audioTrack else { throw MediaImportError.noTracks }

        var width = 0, height = 0
        var frameRate = 0.0
        var primaries: String?, transfer: String?, matrix: String?
        if let videoTrack {
            let size = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let shown = size.applying(transform)
            width = Int(abs(shown.width).rounded())
            height = Int(abs(shown.height).rounded())
            frameRate = Double(try await videoTrack.load(.nominalFrameRate))
            if let description = try await videoTrack.load(.formatDescriptions).first {
                primaries = colorTag(description, kCMFormatDescriptionExtension_ColorPrimaries)
                transfer = colorTag(description, kCMFormatDescriptionExtension_TransferFunction)
                matrix = colorTag(description, kCMFormatDescriptionExtension_YCbCrMatrix)
            }
        }

        var sampleRate: Double?
        if let audioTrack, let description = try await audioTrack.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            sampleRate = basic.pointee.mSampleRate
        }

        var codecName = "Unknown"
        if let description = try await primary.load(.formatDescriptions).first {
            codecName = MediaImporter.codecName(for: description)
        }

        let stamp = FileStamp(url: url)
        return AssetMetadataSnapshot(
            fileName: url.lastPathComponent,
            originalPath: url.path,
            byteCount: stamp?.byteCount ?? 0,
            modified: stamp?.modified,
            isVideo: videoTrack != nil,
            durationValue: duration.value,
            durationTimescale: duration.timescale,
            frameRate: frameRate,
            width: width,
            height: height,
            codecName: codecName,
            colorPrimaries: primaries,
            colorTransfer: transfer,
            colorMatrix: matrix,
            audioSampleRate: sampleRate,
            capturedAt: Date().timeIntervalSince1970
        )
    }

    private static func colorTag(_ description: CMFormatDescription, _ key: CFString) -> String? {
        CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
    }

    /// Loudness over time of all the file's audio mixed together; nil if the
    /// file has no audio.
    static func audioEnvelope(url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> AudioEnvelope? {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let duration = try await asset.load(.duration).seconds

        let handedOver = HandedOver(value: tracks)
        return try await SampleReading.run { isCancelled in
            let tracks = handedOver.value
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { throw FrameScorer.ScoringError.readerFailed("unsupported audio format") }
            reader.add(output)
            guard reader.startReading() else {
                throw FrameScorer.ScoringError.readerFailed(reader.error?.localizedDescription ?? "unknown error", underlying: reader.error)
            }

            let perWindow = sampleRate / AudioEnvelope.windowsPerSecond
            var levels: [UInt8] = []
            var startWindow: Int64?
            var energy = 0.0
            var inWindow = 0
            var lastReported = -1.0
            var samples: [Int16] = []

            while let buffer = output.copyNextSampleBuffer() {
                if isCancelled() {
                    reader.cancelReading()
                    throw CancellationError()
                }
                let presentation = CMSampleBufferGetPresentationTimeStamp(buffer)
                if startWindow == nil {
                    let firstSample = Int64((presentation.seconds * Double(sampleRate)).rounded())
                    startWindow = firstSample / Int64(perWindow)
                    inWindow = Int(firstSample - (startWindow ?? 0) * Int64(perWindow))
                }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Int16>.size
                if samples.count < count { samples = [Int16](repeating: 0, count: count) }
                let status = samples.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Int16>.size, destination: $0.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { continue }

                for index in 0..<count {
                    let value = Double(samples[index]) / 32768
                    energy += value * value
                    inWindow += 1
                    if inWindow == perWindow {
                        levels.append(AudioEnvelope.level(forRMS: (energy / Double(perWindow)).squareRoot()))
                        energy = 0
                        inWindow = 0
                    }
                }

                if duration > 0 {
                    let fraction = min(presentation.seconds / duration, 1)
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
            if reader.status == .failed {
                throw FrameScorer.ScoringError.readerFailed(reader.error?.localizedDescription ?? "unknown error", underlying: reader.error)
            }
            if inWindow > 0 {
                levels.append(AudioEnvelope.level(forRMS: (energy / Double(perWindow)).squareRoot()))
            }
            progress(1)
            return AudioEnvelope(startWindow: startWindow ?? 0, levels: levels)
        }
    }
}
