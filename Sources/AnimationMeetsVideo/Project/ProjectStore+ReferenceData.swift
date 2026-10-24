import CoreMedia
import Foundation

extension ProjectStore {
    static let changeScoreFileName = "signature.bin"

    static func referenceFolder(for assetID: UUID, in packageURL: URL) -> URL {
        packageURL
            .appending(path: referenceFolderName, directoryHint: .isDirectory)
            .appending(path: assetID.uuidString, directoryHint: .isDirectory)
    }

    static func writeChangeScores(_ track: ChangeScoreTrack, for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try track.encoded().write(to: folder.appending(path: changeScoreFileName), options: .atomic)
    }

    /// Nil when the asset was never analyzed or the file can't be read; the
    /// scores are recomputable, so a damaged file just means analyzing again.
    static func readChangeScores(for assetID: UUID, in packageURL: URL) -> ChangeScoreTrack? {
        let url = referenceFolder(for: assetID, in: packageURL).appending(path: changeScoreFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ChangeScoreTrack(decoding: data)
    }

    /// Deletes an asset's saved change scores, for an explicit re-detect.
    static func removeChangeScores(for assetID: UUID, in packageURL: URL) throws {
        let url = referenceFolder(for: assetID, in: packageURL).appending(path: changeScoreFileName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    static let referenceMetadataFileName = "reference.json"
    static let audioEnvelopeFileName = "audio.bin"

    static func writeReference(_ reference: AssetReference, for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONFile.encode(reference.metadata).write(to: folder.appending(path: referenceMetadataFileName), options: .atomic)
        if let envelope = reference.audioEnvelope {
            try envelope.encoded().write(to: folder.appending(path: audioEnvelopeFileName), options: .atomic)
        }
    }

    /// Deletes what was captured of the original: its metadata, audio
    /// envelope, pictures and scores. The change scores of the file the
    /// asset uses now stay, since scene detection uses them. This can't be
    /// undone; `save` calls it for every asset marked `referenceForgotten`.
    static func forgetReference(for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        let fileManager = FileManager.default
        for name in [referenceMetadataFileName, audioEnvelopeFileName, thumbnailFolderName] {
            let url = folder.appending(path: name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        try invalidate(.originalScores, for: assetID, in: packageURL)
    }

    /// Nil when there is no usable metadata snapshot. A missing or damaged
    /// envelope only costs the audio match, so it is dropped on its own.
    static func readReference(for assetID: UUID, in packageURL: URL) -> AssetReference? {
        let folder = referenceFolder(for: assetID, in: packageURL)
        guard let data = try? Data(contentsOf: folder.appending(path: referenceMetadataFileName)),
              let metadata = try? JSONDecoder().decode(AssetMetadataSnapshot.self, from: data)
        else {
            return nil
        }
        let envelope = (try? Data(contentsOf: folder.appending(path: audioEnvelopeFileName)))
            .flatMap { try? AudioEnvelope(decoding: $0) }
        return AssetReference(metadata: metadata, audioEnvelope: envelope)
    }

    static let beatFileName = "beats.bin"

    static func writeBeats(_ track: BeatTrack, for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try track.encoded().write(to: folder.appending(path: beatFileName), options: .atomic)
    }

    /// Nil when the asset's audio was never analyzed or the file can't be
    /// read; beats are recomputable, so a damaged file just means analyzing again.
    static func readBeats(for assetID: UUID, in packageURL: URL) -> BeatTrack? {
        let url = referenceFolder(for: assetID, in: packageURL).appending(path: beatFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? BeatTrack(decoding: data)
    }

    static let thumbnailFolderName = "thumbs"

    /// Writes the pictures to a scratch folder and renames it into place, so
    /// a folder that exists is always complete.
    static func writeThumbnails(_ thumbnails: ReferenceThumbnails, for assetID: UUID, in packageURL: URL) throws {
        let fileManager = FileManager.default
        let folder = referenceFolder(for: assetID, in: packageURL)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let final = folder.appending(path: thumbnailFolderName, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: final.path) else { return }

        let scratch = folder.appending(path: "\(thumbnailFolderName).partial", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: scratch)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        for frame in thumbnails.frames {
            try frame.jpeg.write(to: scratch.appending(path: thumbnailFileName(for: frame.time)))
        }
        try fileManager.moveItem(at: scratch, to: final)
    }

    static func hasThumbnails(for assetID: UUID, in packageURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = referenceFolder(for: assetID, in: packageURL).appending(path: thumbnailFolderName).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The saved pictures, in time order. Empty if none were saved.
    static func readThumbnails(for assetID: UUID, in packageURL: URL) -> ReferenceThumbnails {
        let folder = referenceFolder(for: assetID, in: packageURL).appending(path: thumbnailFolderName)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var frames: [ReferenceFrame] = []
        for name in names {
            guard let time = thumbnailTime(fromFileName: name),
                  let data = try? Data(contentsOf: folder.appending(path: name))
            else {
                continue
            }
            frames.append(ReferenceFrame(time: time, jpeg: data))
        }
        frames.sort { CMTimeCompare($0.time, $1.time) < 0 }
        return ReferenceThumbnails(frames: frames)
    }

    static func thumbnailFileName(for time: CMTime) -> String {
        "\(time.value)_\(time.timescale).jpg"
    }

    static func thumbnailTime(fromFileName name: String) -> CMTime? {
        guard name.hasSuffix(".jpg") else { return nil }
        let parts = name.dropLast(4).split(separator: "_")
        guard parts.count == 2, let value = Int64(parts[0]), let scale = Int32(parts[1]), scale > 0 else { return nil }
        return CMTime(value: value, timescale: scale)
    }

    /// Copies each asset's saved reference data, scores, beats and pictures
    /// from one package to another. Files already at the destination are
    /// kept. The original's data may exist nowhere else, so it must follow
    /// the project to a new package.
    static func copyReferenceData(for assetIDs: [UUID], from source: URL, to destination: URL) throws {
        let same = source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !same else { return }
        let fileManager = FileManager.default
        for id in assetIDs {
            let from = referenceFolder(for: id, in: source)
            guard let names = try? fileManager.contentsOfDirectory(atPath: from.path) else { continue }
            let to = referenceFolder(for: id, in: destination)
            try fileManager.createDirectory(at: to, withIntermediateDirectories: true)
            for name in names where !name.hasSuffix(".partial") {
                let target = to.appending(path: name)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                try fileManager.copyItem(at: from.appending(path: name), to: target)
            }
        }
    }
}
