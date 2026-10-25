import AVFoundation
import Foundation

/// What AVFoundation opens for a media file: the file itself, or for a
/// Matroska file, which AVFoundation can't read, its reference movie (see
/// docs/matroska.md). Everything that reads footage opens it through here;
/// the clip's own URL stays the file's, for its identity, stamp and
/// replacement.
enum MediaFile {
    /// Asks for exact timing. Without it, a seek in a FLAC or MP3 file
    /// lands up to seconds from the time asked for while reporting that
    /// time, so playing from anywhere but the start is heard out of step
    /// with the playhead, and its duration may be an estimate.
    static var options: [String: Any] { [AVURLAssetPreferPreciseDurationAndTimingKey: true] }

    static func readableURL(for url: URL) -> URL {
        MatroskaMedia.referenceMovie(for: url) ?? url
    }

    static func asset(at url: URL) -> AVURLAsset {
        AVURLAsset(url: readableURL(for: url), options: options)
    }

    /// The size of an asset's pictures as shown, rotation applied, read
    /// from its file; nil for sound, and for a file that can't be read.
    static func pictureSize(of media: MediaClip) async -> CGSize? {
        guard media.kind.hasPictures, let url = media.url else { return nil }
        if media.kind == .image { return MediaImporter.stillSize(at: url) }
        guard let info = try? await MediaTrackCache.shared.info(for: readableURL(for: url)), info.video != nil else { return nil }
        let size = info.orientedSize
        return size.width > 0 && size.height > 0 ? size : nil
    }
}
