import Foundation

// The messages between the app and its Python helper (see
// docs/python-scripting.md, "The protocol"). A frame is a four-byte
// little-endian length, that many bytes of a JSON header, and after it,
// when the header has `bytes`, that many bytes of payload: raw
// little-endian float64s, for tables. The helper's side is
// Resources/Python/amv_host/protocol.py.

/// One frame: its header and the payload after it.
struct HelperFrame: Equatable, Sendable {
    var header: JSONValue
    var payload = Data()

    /// The `type` its header gives.
    var type: String { header["type"]?.string ?? "" }

    /// The frame as written to the pipe.
    func encoded() throws -> Data {
        var header = header
        if !payload.isEmpty { header["bytes"] = .number(Double(payload.count)) }
        let json = try JSONEncoder().encode(header)
        var data = Data(capacity: 4 + json.count + payload.count)
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(payload)
        return data
    }

    /// Past this a header is taken to be a broken stream, not a message.
    static let largestHeader = 64 * 1024 * 1024

    /// Reads frames from bytes as they arrive, which can cut a frame
    /// anywhere.
    struct Decoder {
        private var buffer = Data()

        /// Takes in bytes read and gives every frame they complete.
        mutating func take(_ bytes: Data) throws -> [HelperFrame] {
            buffer.append(bytes)
            var frames: [HelperFrame] = []
            while let frame = try nextFrame() { frames.append(frame) }
            return frames
        }

        private mutating func nextFrame() throws -> HelperFrame? {
            guard buffer.count >= 4 else { return nil }
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            guard length <= HelperFrame.largestHeader else { throw ScriptHelperError.brokenStream("a header of \(length) bytes") }
            guard buffer.count >= 4 + length else { return nil }
            let header = try JSONDecoder().decode(JSONValue.self, from: buffer[start + 4..<start + 4 + length])
            let size = header["bytes"]?.int ?? 0
            guard size >= 0 else { throw ScriptHelperError.brokenStream("a payload of \(size) bytes") }
            guard buffer.count >= 4 + length + size else { return nil }
            let payload = Data(buffer[start + 4 + length..<start + 4 + length + size])
            buffer = Data(buffer[(start + 4 + length + size)...])
            return HelperFrame(header: header, payload: payload)
        }
    }
}

/// What the app asks the helper to run.
struct HelperRequest: Sendable {
    enum Kind: String, Sendable {
        /// A script's text, run in a namespace of its own.
        case script
        /// One console line, run in the console's namespace.
        case line
    }

    var kind: Kind
    var code: String
    /// For a script: its file, which tracebacks name.
    var path: URL?
    /// The timeline shown, the clips selected and the playhead, for
    /// `amv.timeline`, `amv.selection` and `amv.playhead`.
    var context: JSONValue = .object([:])
    /// For a console line: start the console's names afresh.
    var freshConsole = false
    /// How long it may run before it is stopped; nil for as long as it
    /// takes (a script, which the person can stop).
    var timeLimit: Duration?

    func header(id: Int) -> JSONValue {
        var header: [String: JSONValue] = [
            "type": .string(kind.rawValue), "id": .number(Double(id)), "code": .string(code), "context": context,
        ]
        if let path {
            header["path"] = .string(path.path)
            header["folder"] = .string(path.deletingLastPathComponent().path)
        }
        if freshConsole { header["fresh"] = .bool(true) }
        return .object(header)
    }
}

/// A read or a change the running code asks the app for.
struct HelperCall: Sendable {
    var method: String
    var arguments: [String: JSONValue]

    init(method: String, arguments: [String: JSONValue] = [:]) {
        self.method = method
        self.arguments = arguments
    }

    init?(_ header: JSONValue) {
        guard let method = header["method"]?.string else { return nil }
        self.method = method
        arguments = header["args"]?.object ?? [:]
    }

    subscript(_ name: String) -> JSONValue? { arguments[name] }
}

/// The app's answer to a call: a value, or an error the helper raises at
/// the line that called.
enum HelperReply: Equatable, Sendable {
    case value(JSONValue)
    case error(ScriptCallError)

    func header(id: Int) -> JSONValue {
        switch self {
        case .value(let value):
            return ["type": "reply", "id": .number(Double(id)), "value": value]
        case .error(let error):
            return ["type": "reply", "id": .number(Double(id)), "error": ["kind": .string(error.kind.rawValue), "message": .string(error.message)]]
        }
    }
}

/// Why a call was refused, raised in Python as the error its kind names.
struct ScriptCallError: Error, Equatable, Sendable {
    enum Kind: String, Sendable {
        /// `amv.Gone`: the thing is no longer in the project.
        case gone
        /// `amv.Refused`: a change the app would refuse by hand.
        case refused
        /// `TypeError` and `ValueError`: the arguments are wrong.
        case type, value
        /// `LookupError`: no such kind of effect, say.
        case lookup
    }

    var kind: Kind
    var message: String

    static func gone(_ message: String) -> Self { Self(kind: .gone, message: message) }
    static func refused(_ message: String) -> Self { Self(kind: .refused, message: message) }
    static func type(_ message: String) -> Self { Self(kind: .type, message: message) }
    static func value(_ message: String) -> Self { Self(kind: .value, message: message) }
    static func lookup(_ message: String) -> Self { Self(kind: .lookup, message: message) }
}

/// Text the running code printed.
struct ScriptOutput: Equatable, Sendable {
    enum Stream: String, Sendable {
        case stdout, stderr
        /// The helper's own note, such as that output past the cap was
        /// dropped.
        case note
    }

    var stream: Stream
    var text: String
}

/// How a run ended.
enum ScriptRunEnd: Equatable, Sendable {
    /// It finished. For a console line, `display` is its last line's
    /// value as the console shows it.
    case finished(display: String?)
    /// It raised.
    case failed(ScriptFailure)
}

/// An exception a run raised: its type and text, the line of the code
/// run it happened at, and the traceback without the helper's frames.
struct ScriptFailure: Equatable, Sendable {
    var exception: String
    var message: String
    var line: Int?
    var traceback: String

    init(exception: String, message: String, line: Int? = nil, traceback: String = "") {
        self.exception = exception
        self.message = message
        self.line = line
        self.traceback = traceback
    }

    init(_ header: JSONValue) {
        exception = header["exception"]?.string ?? "Exception"
        message = header["message"]?.string ?? ""
        line = header["line"]?.int
        traceback = header["traceback"]?.string ?? ""
    }

    /// Whether it was stopped: by Stop, or by the time limit.
    var wasStopped: Bool { exception == "KeyboardInterrupt" }

    /// One sentence for a note: "Line 2: NameError: name 'tim' is not
    /// defined".
    var summary: String {
        let what = message.isEmpty ? exception : "\(exception): \(message)"
        return line.map { "Line \($0): \(what)" } ?? what
    }
}

enum ScriptHelperError: Error, Equatable, LocalizedError {
    /// No interpreter was found: none built in, chosen or named by
    /// `AMV_PYTHON`.
    case noPython
    /// The interpreter couldn't be started.
    case couldNotStart(String)
    /// The helper ended mid-run, with what it wrote to its error stream.
    case ended(String)
    /// It wrote something that isn't a frame.
    case brokenStream(String)
    /// It was stopped by the time limit.
    case tookTooLong(Duration)

    var errorDescription: String? {
        switch self {
        case .noPython: "Python isn't available. Choose one in Settings > Scripting."
        case .couldNotStart(let reason): "Python couldn't be started: \(reason)"
        case .ended(let reason): reason.isEmpty ? "Python ended unexpectedly." : "Python ended unexpectedly: \(reason)"
        case .brokenStream(let what): "Python's helper sent something the app can't read (\(what))."
        case .tookTooLong(let limit): "Took longer than \(limit.components.seconds) seconds, so it was stopped."
        }
    }
}

// MARK: - JSON

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(nilLiteral: ()) { self = .null }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// A whole number, as JSON's numbers carry one.
    var int: Int? {
        guard let number, number.rounded() == number, abs(number) < 9.0e15 else { return nil }
        return Int(number)
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool { self == .null }

    /// A UUID given as its string.
    var uuid: UUID? { string.flatMap(UUID.init(uuidString:)) }

    init(_ id: UUID) { self = .string(id.uuidString) }
    init(_ number: Double) { self = .number(number) }
    init(_ text: String?) { self = text.map(JSONValue.string) ?? .null }
}
