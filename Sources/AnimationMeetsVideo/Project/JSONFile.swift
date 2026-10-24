import Foundation

/// Reading and writing the JSON files the app keeps: projects, presets,
/// effect package manifests and the records beside a project's media.
enum JSONFile {
    /// The `formatVersion` a file gives, or nil when it gives none or isn't
    /// JSON.
    static func formatVersion(of data: Data) -> Int? {
        (try? JSONDecoder().decode(ProjectFileHeader.self, from: data))?.formatVersion
    }

    /// Why a file of `version` can't be read, for one that gives another
    /// version or none: "The preset has format version 2; this app reads
    /// version 1." Nil when it gives `version`.
    static func versionMismatch(in data: Data, expecting version: Int, noun: String) -> String? {
        let found = formatVersion(of: data)
        guard found != version else { return nil }
        return "The \(noun) has format version \(found.map(String.init) ?? "none"); this app reads version \(version)."
    }

    /// Checks `data` against `shape` (`StrictJSON`) and then decodes it.
    /// A problem either finds is thrown as `failure` makes it of the
    /// problem's sentence.
    static func decode<Value: Decodable>(
        _ type: Value.Type, from data: Data, shape: JSONShape, failure: (String) -> Error
    ) throws -> Value {
        do {
            try StrictJSON.validate(data, against: shape)
            return try JSONDecoder().decode(type, from: data)
        } catch let problem as JSONShapeError {
            throw failure(problem.sentence)
        } catch let problem as DecodingError {
            throw failure(problem.sentenceForProject)
        }
    }

    /// `value` as the app writes its files: indented, keys sorted so the
    /// same value always gives the same text, slashes unescaped, and a
    /// newline at the end.
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
