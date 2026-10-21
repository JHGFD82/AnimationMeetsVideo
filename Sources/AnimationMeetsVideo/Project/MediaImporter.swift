import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaImportError: LocalizedError {
    case noTracks
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .noTracks: "The file has no readable audio or video tracks."
        case .unreadableImage: "The picture in the file can't be read."
        }
    }
}

enum MediaImporter {
    /// Reads the file at `url`. A Matroska file is read through its
    /// reference movie, made first in `packageURL`'s cache, or for a project
    /// not yet saved (nil), in a temporary folder (see docs/matroska.md).
    /// `progress` is told how far that has got, 0...1, from any thread;
    /// other files take a moment and don't report.
    static func importClip(
        at url: URL, packageURL: URL?, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> MediaClip {
        if isImage(url) { return try importStill(at: url) }
        let readable = MatroskaMedia.isMatroska(url)
            ? try MatroskaMedia.prepare(url, in: MatroskaMedia.folder(in: packageURL), progress: progress)
            : url
        let asset = AVURLAsset(url: readable, options: MediaFile.options)
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
            hasAudio: !audioTracks.isEmpty,
            acceptedStamp: FileStamp(url: url)
        )
    }

    /// Whether the file is a picture, by its type: from its extension, or
    /// without one, from the file. A movie whose type also counts as an
    /// image (none common does) is read as a movie.
    static func isImage(_ url: URL) -> Bool {
        let named = url.pathExtension.isEmpty ? nil : UTType(filenameExtension: url.pathExtension)
        guard let type = named ?? (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .movie)
    }

    /// A still, read with ImageIO without decoding its pixels: its type
    /// names the codec, and a picture with a gain map or an HDR profile is
    /// HDR (see docs/graphic-layers.md).
    static func importStill(at url: URL) throws -> MediaClip {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0
        else {
            throw MediaImportError.unreadableImage
        }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        return MediaClip(
            name: url.deletingPathExtension().lastPathComponent,
            kind: .image,
            url: url,
            duration: MediaClip.stillLength,
            frameRate: 0,
            colorSpace: stillColorSpace(source),
            codecName: type?.preferredFilenameExtension?.uppercased() ?? "Image",
            acceptedStamp: FileStamp(url: url)
        )
    }

    /// A still's size in pixels as it is shown, its orientation applied.
    static func stillSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // Orientations 5 to 8 turn the picture a quarter.
        let turned = (properties[kCGImagePropertyOrientation] as? Int).map { $0 >= 5 } ?? false
        return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    private static func stillColorSpace(_ source: CGImageSource) -> ProjectColorSpace {
        for kind in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap]
        where CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kind) != nil {
            return .rec2020PQ
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let space = image.colorSpace, CGColorSpaceUsesITUR_2100TF(space)
        else {
            return .rec709
        }
        let name = space.name.map { $0 as String } ?? ""
        return name.contains("HLG") ? .rec2020HLG : .rec2020PQ
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
