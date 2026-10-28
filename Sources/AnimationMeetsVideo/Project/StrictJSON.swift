import Foundation

/// What a JSON value in a project file must look like. Loading checks the
/// whole file against one of these before decoding it, so anything it
/// doesn't recognize is reported with where it is instead of being skipped.
indirect enum JSONShape: Sendable {
    case string
    case number
    case integer
    case bool
    case uuid
    /// Exact rational seconds such as `"5s"` or `"1001/24000s"`.
    case time
    /// One of a fixed set of strings; `noun` names it in messages
    /// ("blend mode").
    case choice([String], noun: String)
    /// A list of numbers; `count` fixes its length.
    case numbers(count: Int?)
    case array(JSONShape)
    case object(JSONObjectShape)
    /// An object whose other keys depend on the string at `key`.
    case tagged(key: String, noun: String, [String: JSONObjectShape])
    /// As `tagged`, with tags it doesn't list that `others` accepts
    /// checked against its shape instead of refused.
    case taggedOr(key: String, noun: String, [String: JSONObjectShape], others: JSONOtherTags)
    /// A number, or a list of numbers.
    case numberOrNumbers
    /// Anything.
    case any
}

struct JSONObjectShape: Sendable {
    struct Field: Sendable {
        var name: String
        var shape: JSONShape
        var required: Bool

        static func required(_ name: String, _ shape: JSONShape) -> Field { Field(name: name, shape: shape, required: true) }
        static func optional(_ name: String, _ shape: JSONShape) -> Field { Field(name: name, shape: shape, required: false) }
    }

    var fields: [Field]
    /// Groups of keys of which at least one must be present.
    var oneOf: [[String]] = []
    /// Whether keys it doesn't list are allowed, for a part of a file kept
    /// as it is without being understood.
    var allowsOtherKeys = false
}

/// The tags a `taggedOr` shape takes besides the ones it lists.
struct JSONOtherTags: Sendable {
    var accepts: @Sendable (String) -> Bool
    var shape: JSONObjectShape
}

/// A problem found in a project file, and where.
struct JSONShapeError: Error, Equatable {
    var message: String
    var path: String

    /// "Unknown key "transform" at timelines[0].layers[2]."
    var sentence: String {
        let place = path.isEmpty ? "the top level of the file" : path
        return "\(message) at \(place)."
    }
}

enum StrictJSON {
    /// Parses `data` and checks it against `shape`. Throws the first
    /// problem found; keys are visited in sorted order so the same file
    /// always reports the same one.
    static func validate(_ data: Data, against shape: JSONShape) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONShapeError(message: "The file isn't valid JSON (\(error.localizedDescription))", path: "")
        }
        try check(value, against: shape, path: "")
    }

    /// Checks a value already parsed against `shape`, as `validate` checks
    /// `data` once parsed.
    static func validate(_ value: Any, against shape: JSONShape) throws {
        try check(value, against: shape, path: "")
    }

    static func check(_ value: Any, against shape: JSONShape, path: String) throws {
        switch shape {
        case .any:
            return
        case .string:
            guard value is String else { throw expected("text", path) }
        case .number:
            guard isNumber(value) else { throw expected("a number", path) }
        case .integer:
            guard let number = value as? NSNumber, !isBool(value), number.doubleValue == number.doubleValue.rounded() else {
                throw expected("a whole number", path)
            }
        case .bool:
            guard isBool(value) else { throw expected("true or false", path) }
        case .uuid:
            guard let text = value as? String, UUID(uuidString: text) != nil else { throw expected("an ID", path) }
        case .time:
            guard let text = value as? String, isTime(text) else {
                let shown = (value as? String).map { "\"\($0)\" isn't a valid time" } ?? "Expected a time"
                throw JSONShapeError(message: shown + ", written as rational seconds such as 1001/24000s or 5s", path: path)
            }
        case .choice(let options, let noun):
            guard let text = value as? String else { throw expected("text", path) }
            guard options.contains(text) else { throw JSONShapeError(message: "Unknown \(noun) \"\(text)\"", path: path) }
        case .numbers(let count):
            guard let list = value as? [Any], list.allSatisfy(isNumber), count.map({ list.count == $0 }) ?? true else {
                throw expected(count.map { "a list of \($0) numbers" } ?? "a list of numbers", path)
            }
        case .numberOrNumbers:
            if isNumber(value) { return }
            guard let list = value as? [Any], list.allSatisfy(isNumber) else { throw expected("a number or a list of numbers", path) }
        case .array(let element):
            guard let list = value as? [Any] else { throw expected("a list", path) }
            for (index, item) in list.enumerated() {
                try check(item, against: element, path: "\(path)[\(index)]")
            }
        case .object(let object):
            guard let dictionary = value as? [String: Any] else { throw expected("an object", path) }
            try check(dictionary, against: object, path: path)
        case .tagged(let key, let noun, let variants):
            guard let dictionary = value as? [String: Any] else { throw expected("an object", path) }
            guard let tag = dictionary[key] else { throw JSONShapeError(message: "Missing \"\(key)\"", path: path) }
            guard let name = tag as? String else { throw expected("text", join(path, key)) }
            guard let object = variants[name] else {
                throw JSONShapeError(message: "Unknown \(noun) \"\(name)\"", path: join(path, key))
            }
            try check(dictionary, against: object, path: path)
        case .taggedOr(let key, let noun, let variants, let others):
            guard let dictionary = value as? [String: Any] else { throw expected("an object", path) }
            guard let tag = dictionary[key] else { throw JSONShapeError(message: "Missing \"\(key)\"", path: path) }
            guard let name = tag as? String else { throw expected("text", join(path, key)) }
            if let object = variants[name] {
                try check(dictionary, against: object, path: path)
            } else if others.accepts(name) {
                try check(dictionary, against: others.shape, path: path)
            } else {
                throw JSONShapeError(message: "Unknown \(noun) \"\(name)\"", path: join(path, key))
            }
        }
    }

    private static func check(_ dictionary: [String: Any], against object: JSONObjectShape, path: String) throws {
        let known = Set(object.fields.map(\.name))
        for key in dictionary.keys.sorted() where !known.contains(key) && !object.allowsOtherKeys {
            throw JSONShapeError(message: "Unknown key \"\(key)\"", path: path)
        }
        for field in object.fields where field.required && dictionary[field.name] == nil {
            throw JSONShapeError(message: "Missing \"\(field.name)\"", path: path)
        }
        for group in object.oneOf where !group.contains(where: { dictionary[$0] != nil }) {
            let names = group.map { "\"\($0)\"" }.joined(separator: " or ")
            throw JSONShapeError(message: "Missing \(names)", path: path)
        }
        for field in object.fields {
            if let child = dictionary[field.name] {
                try check(child, against: field.shape, path: join(path, field.name))
            }
        }
    }

    static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    private static func expected(_ what: String, _ path: String) -> JSONShapeError {
        JSONShapeError(message: "Expected \(what)", path: path)
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isNumber(_ value: Any) -> Bool {
        value is NSNumber && !isBool(value)
    }

    private static func isTime(_ text: String) -> Bool {
        guard text.hasSuffix("s") else { return false }
        let parts = text.dropLast().split(separator: "/", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return Int64(parts[0]) != nil
        case 2: return Int64(parts[0]) != nil && (Int32(parts[1]).map { $0 > 0 } ?? false)
        default: return false
        }
    }
}
