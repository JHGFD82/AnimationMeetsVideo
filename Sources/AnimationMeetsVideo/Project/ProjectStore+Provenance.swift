import Foundation

extension ProjectStore {
    static let provenanceFileName = "provenance.json"

    private static func resultFileName(_ kind: AnalysisKind) -> String {
        switch kind {
        case .scores: changeScoreFileName
        case .beats: beatFileName
        case .originalScores: originalScoresFileName
        }
    }

    /// The records for an asset's results; empty if there are none or the file
    /// can't be read, in which case the results count as unrecorded.
    static func readProvenance(for assetID: UUID, in packageURL: URL) -> [AnalysisKind: AnalysisProvenance] {
        let url = referenceFolder(for: assetID, in: packageURL).appending(path: provenanceFileName)
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: AnalysisProvenance].self, from: data)
        else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            AnalysisKind(rawValue: key).map { ($0, value) }
        })
    }

    private static func writeProvenance(_ records: [AnalysisKind: AnalysisProvenance], for assetID: UUID, in packageURL: URL) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let raw = Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) })
        try encoder.encode(raw).write(to: folder.appending(path: provenanceFileName), options: .atomic)
    }

    /// Records what the result file now in the folder was computed from. The
    /// result is written first, so a failure in between leaves a record that
    /// does not match it, which is rejected rather than trusted.
    private static func recordProvenance(
        _ kind: AnalysisKind, resultData: Data, source: FileStamp?, for assetID: UUID, in packageURL: URL
    ) throws {
        var records = readProvenance(for: assetID, in: packageURL)
        let current = AnalysisProvenance.current(for: kind)
        records[kind] = AnalysisProvenance(
            source: source, settings: current.settings, algorithm: current.algorithm,
            digest: AnalysisProvenance.digest(of: resultData)
        )
        try writeProvenance(records, for: assetID, in: packageURL)
    }

    /// Writes scores together with the record of the file they came from.
    static func writeChangeScores(_ track: ChangeScoreTrack, for assetID: UUID, in packageURL: URL, source: FileStamp?) throws {
        try writeChangeScores(track, for: assetID, in: packageURL)
        let data = try track.encoded()
        try recordProvenance(.scores, resultData: data, source: source, for: assetID, in: packageURL)
    }

    /// Writes beats together with the record of the file they came from.
    static func writeBeats(_ track: BeatTrack, for assetID: UUID, in packageURL: URL, source: FileStamp?) throws {
        try writeBeats(track, for: assetID, in: packageURL)
        let data = try track.encoded()
        try recordProvenance(.beats, resultData: data, source: source, for: assetID, in: packageURL)
    }

    /// Retires a saved result so it can't be used again. The file is deleted;
    /// if that fails, the record is marked invalidated instead, and the
    /// result is rejected even though its file remains. Throws only when
    /// neither could be done, in which case the result may come back.
    static func invalidate(_ kind: AnalysisKind, for assetID: UUID, in packageURL: URL) throws {
        let fileManager = FileManager.default
        let url = referenceFolder(for: assetID, in: packageURL).appending(path: resultFileName(kind))
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch let deleteError {
            var records = readProvenance(for: assetID, in: packageURL)
            if var record = records[kind] {
                record.invalidated = true
                records[kind] = record
            } else {
                // Nothing recorded: such a result is already rejected, but say so.
                let current = AnalysisProvenance.current(for: kind)
                records[kind] = AnalysisProvenance(
                    source: nil, settings: current.settings, algorithm: current.algorithm, digest: "", invalidated: true
                )
            }
            do {
                try writeProvenance(records, for: assetID, in: packageURL)
            } catch {
                throw ProvenanceError.couldNotRetire(deleteError.localizedDescription)
            }
        }
    }

    /// Checks a saved result against the file the asset has now, `identity`.
    private static func verified<Value>(
        _ kind: AnalysisKind, for assetID: UUID, in packageURL: URL, identity: FileStamp?,
        decode: (Data) throws -> Value
    ) -> CachedResult<Value> {
        let url = referenceFolder(for: assetID, in: packageURL).appending(path: resultFileName(kind))
        guard let data = try? Data(contentsOf: url) else { return .absent }
        guard let record = readProvenance(for: assetID, in: packageURL)[kind] else { return .rejected(.noProvenance) }
        if record.invalidated { return .rejected(.invalidated) }
        let current = AnalysisProvenance.current(for: kind)
        if !AnalysisProvenance.accepts(algorithm: record.algorithm, for: kind) { return .rejected(.differentAlgorithm) }
        if record.settings != current.settings { return .rejected(.differentSettings) }
        if record.digest != AnalysisProvenance.digest(of: data) { return .rejected(.damaged) }
        guard let source = record.source, let identity else { return .rejected(.unverifiable) }
        if source != identity { return .rejected(.differentFile) }
        guard let value = try? decode(data) else { return .rejected(.damaged) }
        return .valid(value, source: source)
    }

    static func readVerifiedChangeScores(for assetID: UUID, in packageURL: URL, identity: FileStamp?) -> CachedResult<ChangeScoreTrack> {
        verified(.scores, for: assetID, in: packageURL, identity: identity) { try ChangeScoreTrack(decoding: $0) }
    }

    static let originalScoresFileName = "original-signature.bin"

    /// Writes the original footage's scores, with a record naming the
    /// original file they came from. Only for an asset whose file still is
    /// the original.
    static func writeOriginalScores(_ track: ChangeScoreTrack, for assetID: UUID, in packageURL: URL, source: FileStamp?) throws {
        let folder = referenceFolder(for: assetID, in: packageURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try track.encoded().write(to: folder.appending(path: originalScoresFileName), options: .atomic)
        try recordProvenance(.originalScores, resultData: track.encoded(), source: source, for: assetID, in: packageURL)
    }

    /// The original's saved scores, if their record is intact and, where the
    /// original's metadata snapshot is saved, names the same file as it.
    /// Unlike current-file results they are not compared with the file the
    /// asset uses now: they describe the original, whatever replaced it.
    static func readVerifiedOriginalScores(for assetID: UUID, in packageURL: URL) -> CachedResult<ChangeScoreTrack> {
        let record = readProvenance(for: assetID, in: packageURL)[.originalScores]
        if let source = record?.source, let snapshot = readReference(for: assetID, in: packageURL)?.metadata,
           snapshot.byteCount != source.byteCount || snapshot.modified != source.modified {
            return .rejected(.differentFile)
        }
        return verified(.originalScores, for: assetID, in: packageURL, identity: record?.source) { try ChangeScoreTrack(decoding: $0) }
    }

    static func readVerifiedBeats(for assetID: UUID, in packageURL: URL, identity: FileStamp?) -> CachedResult<BeatTrack> {
        verified(.beats, for: assetID, in: packageURL, identity: identity) { try BeatTrack(decoding: $0) }
    }
}

enum ProvenanceError: LocalizedError {
    case couldNotRetire(String)

    var errorDescription: String? {
        switch self {
        case .couldNotRetire(let reason):
            "Couldn't remove outdated analysis from the project, and couldn't mark it unusable: \(reason)"
        }
    }
}

extension FileStamp {
    init(byteCount: Int64, modified: Double?) {
        self.byteCount = byteCount
        self.modified = modified
    }
}
