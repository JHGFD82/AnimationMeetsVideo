import AVFoundation
import Foundation

/// What AVFoundation opens for a media file: the file itself, or for a
/// Matroska file, which AVFoundation can't read, its reference movie (see
/// docs/matroska.md). Everything that reads footage opens it through here;
/// the clip's own URL stays the file's, for its identity, stamp and
/// replacement.
enum MediaFile {
    static func readableURL(for url: URL) -> URL {
        MatroskaMedia.referenceMovie(for: url) ?? url
    }

    static func asset(at url: URL) -> AVURLAsset {
        AVURLAsset(url: readableURL(for: url))
    }
}
