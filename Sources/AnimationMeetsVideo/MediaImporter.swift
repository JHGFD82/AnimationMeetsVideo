import AVFoundation
import CoreMedia
import Foundation

enum MediaImportError: LocalizedError {
    case noTracks

    var errorDescription: String? {
        switch self {
        case .noTracks: "The file has no readable audio or video tracks."
        }
    }
}

enum MediaImporter {
    static func importClip(at url: URL) async throws -> MediaClip {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)

        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }

        guard let referenceTrack = videoTracks.first ?? audioTracks.first else {
            throw MediaImportError.noTracks
        }

        let kind: MediaKind = videoTracks.isEmpty ? .audio : .video

        var codecName = "Unknown"
        var colorSpace: ProjectColorSpace = .rec709
        if let formatDescription = try await referenceTrack.load(.formatDescriptions).first {
            codecName = Self.codecName(for: formatDescription)
            if kind == .video {
                colorSpace = Self.colorSpace(for: formatDescription)
            }
        }

        var frameRate: Double = 0
        if let videoTrack = videoTracks.first {
            frameRate = Double(try await videoTrack.load(.nominalFrameRate))
        }

        return MediaClip(
            name: url.deletingPathExtension().lastPathComponent,
            kind: kind,
            url: url,
            duration: duration,
            frameRate: frameRate,
            colorSpace: colorSpace,
            codecName: codecName,
            hasAudio: !audioTracks.isEmpty
        )
    }

    static func codecName(for formatDescription: CMFormatDescription) -> String {
        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        switch subType {
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: return "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422LT: return "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy: return "ProRes 422 Proxy"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kCMVideoCodecType_H264: return "H.264"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatMPEG4AAC: return "AAC"
        default: return fourCharString(subType)
        }
    }

    private static func colorSpace(for formatDescription: CMFormatDescription) -> ProjectColorSpace {
        guard let transferFunction = CMFormatDescriptionGetExtension(
            formatDescription,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String else {
            return .rec709
        }

        switch transferFunction {
        case String(kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ):
            return .rec2020PQ
        case String(kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG):
            return .rec2020HLG
        default:
            return .rec709
        }
    }

    private static func fourCharString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "Unknown"
    }
}
