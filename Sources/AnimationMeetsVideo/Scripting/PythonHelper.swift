import Darwin
import Foundation

/// The helper as the runners see it, so tests can stand a fake in.
protocol ScriptHelper: Sendable {
    /// Runs `request`, answering the calls it makes with `answer` and
    /// handing what it prints to `output`, and gives how it ended. Runs
    /// one at a time: a second waits for the first.
    func run(
        _ request: HelperRequest,
        output: @escaping @Sendable (ScriptOutput) -> Void,
        answer: @escaping @Sendable (HelperCall) async -> HelperReply
    ) async throws -> ScriptRunEnd

    /// Stops the run under way, if there is one: `KeyboardInterrupt` is
    /// raised in it, and a second later the process is ended.
    func stop() async

    /// Asks the helper which Python it is running on, starting it if need
    /// be.
    func ping() async throws -> HelperPong
}

/// The helper's answer to a ping.
struct HelperPong: Equatable, Sendable {
    var version: PythonVersion?
    var executable: String
}

/// The app's two helpers (see docs/python-scripting.md, "A helper
/// process"): one for scripts and the console, with the person's rights,
/// and one for expressions. Each is started the first time something
/// needs it, never at launch, and kept until the app quits.
enum PythonHelpers {
    static let scripts = PythonHelper()
    /// Confined (`HelperConfinement`): an expression is arithmetic.
    static let expressions = PythonHelper(confined: true)
}

/// Python run as a child process and talked to over pipes, rather than
/// linked into the app: a loop that never ends or a call stuck in C is
/// ended by ending the process, a crash is the helper's own, and any
/// Python 3.11 or later can stand in.
///
/// Stop sends `SIGINT`, which Python raises as `KeyboardInterrupt`, and a
/// second later, if the run hasn't ended, ends the process; the next run
/// starts a new one. So does a run that outlasts its time limit.
actor PythonHelper: ScriptHelper {
    private let findInterpreter: @Sendable () -> PythonInterpreter?
    private let host: URL?
    /// Whether it runs in the sandbox, as the expressions' helper does.
    let confined: Bool
    private var connection: HelperConnection?
    private var nextID = 0
    /// The run under way, and the runs that ended by Stop or by the limit.
    private var activeRun: Int?
    private var stoppedRun: Int?
    private var timedOutRun: Int?
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// How long after Stop the process is ended, if the run hasn't.
    static let stopGrace: Duration = .seconds(1)

    init(
        interpreter: @escaping @Sendable () -> PythonInterpreter? = { PythonRuntime.interpreter() },
        host: URL? = PythonRuntime.hostScript,
        confined: Bool = false
    ) {
        findInterpreter = interpreter
        self.host = host
        self.confined = confined
    }

    func run(
        _ request: HelperRequest,
        output: @escaping @Sendable (ScriptOutput) -> Void,
        answer: @escaping @Sendable (HelperCall) async -> HelperReply
    ) async throws -> ScriptRunEnd {
        await enter()
        defer { leave() }
        let connection = try connect()
        nextID += 1
        let id = nextID
        activeRun = id
        defer { activeRun = nil }
        var timer: Task<Void, Never>?
        if let limit = request.timeLimit {
            timer = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                await self?.timeOut(id)
            }
        }
        defer { timer?.cancel() }

        // Its result may carry what it asked for and no more; nothing
        // sent outside a run may carry anything (F57).
        connection.reader.allowPayload(upTo: request.largestResult)
        defer { connection.reader.allowPayload(upTo: 0) }

        do {
            try connection.send(HelperFrame(header: request.header(id: id), payload: request.payload))
            while true {
                let frame = try await connection.reader.next()
                switch frame.type {
                case "call":
                    guard let callID = frame.header["id"]?.int, let call = HelperCall(frame.header) else {
                        throw ScriptHelperError.brokenStream("a call without a method")
                    }
                    let reply = await answer(call)
                    try connection.send(HelperFrame(header: reply.header(id: callID)))
                case "output":
                    let stream = frame.header["stream"]?.string.flatMap(ScriptOutput.Stream.init) ?? .stdout
                    output(ScriptOutput(stream: stream, text: frame.header["text"]?.string ?? ""))
                case "result" where frame.header["run"]?.int == id:
                    if request.kind == .expression { return .samples(Self.floats(frame.payload)) }
                    return .finished(display: frame.header["display"]?.string)
                case "error" where frame.header["run"]?.int == id:
                    if timedOutRun == id, let limit = request.timeLimit { throw ScriptHelperError.tookTooLong(limit) }
                    return .failed(ScriptFailure(frame.header))
                default:
                    // A pong or the end of a run that was given up on.
                    continue
                }
            }
        } catch ScriptHelperError.tookTooLong(let limit) {
            // Stopped in time: the helper is fine and runs the next one.
            throw ScriptHelperError.tookTooLong(limit)
        } catch {
            // Whatever went wrong, this helper's stream can't be trusted:
            // the next run starts a new one.
            drop(connection)
            if timedOutRun == id, let limit = request.timeLimit { throw ScriptHelperError.tookTooLong(limit) }
            if stoppedRun == id { return .failed(ScriptFailure(exception: "KeyboardInterrupt", message: "Stopped.")) }
            throw error
        }
    }

    func stop() {
        guard let id = activeRun, let connection else { return }
        stoppedRun = id
        connection.interrupt()
        Task { [weak self] in
            try? await Task.sleep(for: Self.stopGrace)
            await self?.end(ifStillRunning: id)
        }
    }

    func ping() async throws -> HelperPong {
        await enter()
        defer { leave() }
        let connection = try connect()
        nextID += 1
        let id = nextID
        do {
            try connection.send(HelperFrame(header: ["type": "ping", "id": .number(Double(id))]))
            while true {
                let frame = try await connection.reader.next()
                guard frame.type == "pong", frame.header["id"]?.int == id else { continue }
                return HelperPong(
                    version: frame.header["version"]?.string.flatMap(PythonVersion.init),
                    executable: frame.header["executable"]?.string ?? connection.interpreter.executable.path
                )
            }
        } catch {
            drop(connection)
            throw error
        }
    }

    /// Raw little-endian float64s as numbers.
    static func floats(_ data: Data) -> [Double] {
        stride(from: 0, to: data.count - data.count % 8, by: 8).map { offset in
            var bits: UInt64 = 0
            for (shift, byte) in data[data.startIndex + offset..<data.startIndex + offset + 8].enumerated() {
                bits |= UInt64(byte) << (8 * UInt64(shift))
            }
            return Double(bitPattern: bits)
        }
    }

    /// Numbers as raw little-endian float64s.
    static func payload(_ numbers: [Double]) -> Data {
        var data = Data(capacity: numbers.count * 8)
        for number in numbers {
            withUnsafeBytes(of: number.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Ends the helper, if it is running; the next run starts a new one.
    func shutDown() {
        if let connection { drop(connection) }
    }

    // MARK: - The process

    /// The helper, started on the interpreter as it is now set: one
    /// running on another is ended first.
    private func connect() throws -> HelperConnection {
        guard let interpreter = findInterpreter() else { throw ScriptHelperError.noPython }
        if let connection, connection.isAlive, connection.interpreter == interpreter { return connection }
        if let connection { drop(connection) }
        guard let host else { throw ScriptHelperError.couldNotStart("the app's helper code is missing") }
        let started = try HelperConnection(interpreter: interpreter, host: host, confined: confined)
        connection = started
        return started
    }

    private func drop(_ dropped: HelperConnection) {
        dropped.terminate()
        if connection === dropped { connection = nil }
    }

    private func timeOut(_ id: Int) {
        guard activeRun == id else { return }
        timedOutRun = id
        stop()
    }

    private func end(ifStillRunning id: Int) {
        guard activeRun == id, let connection else { return }
        drop(connection)
    }

    // MARK: - One at a time

    private func enter() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func leave() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// One helper process and its pipes.
final class HelperConnection: @unchecked Sendable {
    let interpreter: PythonInterpreter
    let reader: HelperFrameReader
    private let process = Process()
    private let input: FileHandle
    private let writing = NSLock()

    init(interpreter: PythonInterpreter, host: URL, confined: Bool = false) throws {
        // A write to a helper that has gone would end the app.
        signal(SIGPIPE, SIG_IGN)
        self.interpreter = interpreter
        reader = HelperFrameReader(limits: confined ? .expressions : .scripts)
        let toHelper = Pipe(), fromHelper = Pipe(), errors = Pipe()
        input = toHelper.fileHandleForWriting
        if confined {
            // Never run unconfined in its place: without the sandbox,
            // expressions don't run at all.
            guard HelperConfinement.isAvailable else {
                throw ScriptHelperError.couldNotStart("this Mac can't confine expressions (sandbox-exec is missing)")
            }
            let command = HelperConfinement.command(interpreter: interpreter.executable, host: host)
            process.executableURL = command.executable
            process.arguments = command.arguments
        } else {
            process.executableURL = interpreter.executable
            process.arguments = PythonRuntime.helperArguments(host: host)
        }
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = errors
        // Nothing of the app's own environment that would change how
        // Python starts (it ignores PYTHON* under -E), and a working
        // directory that is always there. Confined, it is the helper's own
        // code, which the sandbox lets it read: the temporary folder isn't,
        // so os.getcwd(), and so os.path.abspath of a relative path,
        // failed with "Operation not permitted".
        process.currentDirectoryURL = confined
            ? host.deletingLastPathComponent().deletingLastPathComponent()
            : URL(filePath: NSTemporaryDirectory())

        let reader = reader
        fromHelper.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.take(data)
            }
        }
        let errorText = HelperErrorText()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errorText.append(data) }
        }
        let errorOutput = errors.fileHandleForReading
        let sandboxed = confined
        process.terminationHandler = { ended in
            // What it wrote just before it ended may not have been read
            // yet: read the rest first, or the reason comes back empty.
            errorOutput.readabilityHandler = nil
            errorText.append(errorOutput.readDataToEndOfFile())
            let how = ended.terminationReason == .uncaughtSignal
                ? "it was stopped by signal \(ended.terminationStatus)"
                : "exit status \(ended.terminationStatus)"
            let place = sandboxed ? " in its sandbox" : ""
            let text = errorText.text
            reader.finish(ScriptHelperError.ended(text.isEmpty ? "\(how)\(place)" : "\(text) (\(how)\(place))"))
        }
        do {
            try process.run()
        } catch {
            throw ScriptHelperError.couldNotStart(error.localizedDescription)
        }
    }

    var isAlive: Bool { process.isRunning }

    func send(_ frame: HelperFrame) throws {
        let data = try frame.encoded()
        writing.lock()
        defer { writing.unlock() }
        do {
            try input.write(contentsOf: data)
        } catch {
            throw ScriptHelperError.ended("its input was closed")
        }
    }

    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    func terminate() {
        try? input.close()
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

/// How much the app holds of what a helper sends before taking its stream
/// for broken and ending it (code-review-notes.md, F57). The memory a
/// helper can make the app hold is at most `mostBuffered` and one header,
/// plus the result its run asked for.
struct HelperLimits: Sendable, Equatable {
    /// The longest header of one frame.
    var largestHeader: Int
    /// The most bytes of frames read but not yet taken by a run, and of
    /// the frame still arriving, beside the run's own result.
    var mostBuffered: Int
    /// The most such frames.
    var mostUnread = 10_000

    /// A script's: its calls can carry a timeline's worth of edits.
    static let scripts = HelperLimits(largestHeader: HelperFrame.largestHeader, mostBuffered: 256 * 1024 * 1024)
    /// An expression's, which sends small calls, its output (a megabyte at
    /// most from the helper's own code), an error and one result whose
    /// payload the run sets. Code it runs can write to the pipe itself, so
    /// these hold whatever it sends.
    static let expressions = HelperLimits(largestHeader: 1024 * 1024, mostBuffered: 8 * 1024 * 1024)
}

/// The frames the helper has written, waited for one at a time.
final class HelperFrameReader: @unchecked Sendable {
    let limits: HelperLimits
    private let lock = NSLock()
    private var decoder = HelperFrame.Decoder()
    private var frames: [(frame: HelperFrame, size: Int)] = []
    /// What `frames` hold, as sent.
    private var queuedBytes = 0
    /// The payload the run under way may be sent, as its result; none
    /// outside a run.
    private var allowedPayload = 0
    private var waiter: CheckedContinuation<HelperFrame, Error>?
    private var ending: Error?
    /// Whether what it sent broke a limit or the format: what follows is
    /// dropped, not read from the middle of a frame.
    private var broken = false

    init(limits: HelperLimits = .scripts) {
        self.limits = limits
        decoder.largestHeader = limits.largestHeader
        decoder.largestPayload = 0
    }

    /// Lets the frames that follow carry a payload of up to `bytes`, the
    /// result the run about to start asked for; 0 when it ends. A frame
    /// with more is a broken stream from its header on, before its payload
    /// is waited for.
    func allowPayload(upTo bytes: Int) {
        lock.lock()
        allowedPayload = min(max(bytes, 0), HelperFrame.largestPayload)
        decoder.largestPayload = allowedPayload
        lock.unlock()
    }

    /// Takes bytes read from the helper's output.
    func take(_ data: Data) {
        lock.lock()
        do {
            guard !broken else { throw ScriptHelperError.brokenStream("bytes after the stream broke") }
            for read in try decoder.takeSized(data) {
                frames.append(read)
                queuedBytes += read.size
            }
            // Frames nothing reads, as from a thread an earlier run left
            // sending, end the stream rather than pile up without limit,
            // counted and by their bytes (code-review-notes.md, F57).
            if frames.count > limits.mostUnread {
                throw ScriptHelperError.brokenStream("more than \(limits.mostUnread) messages no run read")
            }
            if queuedBytes + decoder.buffered > limits.mostBuffered + allowedPayload {
                throw ScriptHelperError.brokenStream("more than \(limits.mostBuffered) bytes of messages no run read")
            }
        } catch {
            // Its frames are let go of at once: the helper is ended, and a
            // run reading on is told why.
            broken = true
            frames.removeAll()
            queuedBytes = 0
            decoder = HelperFrame.Decoder()
            ending = ending ?? error
        }
        let ready = deliver()
        lock.unlock()
        ready?()
    }

    /// No more frames will come: the waiting read, and every one after the
    /// frames already read, throw `error`.
    func finish(_ error: Error) {
        lock.lock()
        ending = ending ?? error
        let ready = deliver()
        lock.unlock()
        ready?()
    }

    /// The next frame, waiting for it to arrive.
    func next() async throws -> HelperFrame {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiter = continuation
            let ready = deliver()
            lock.unlock()
            ready?()
        }
    }

    /// Hands the waiting read its frame or the stream's end, to be done
    /// once the lock is let go.
    private func deliver() -> (() -> Void)? {
        guard let waiter else { return nil }
        if !frames.isEmpty {
            let (frame, size) = frames.removeFirst()
            queuedBytes -= size
            self.waiter = nil
            return { waiter.resume(returning: frame) }
        }
        if let ending {
            self.waiter = nil
            return { waiter.resume(throwing: ending) }
        }
        return nil
    }
}

/// What the helper wrote to its own standard error before it took that
/// over, or as it crashed: the reason it ended, when it ends early.
private final class HelperErrorText: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ more: Data) {
        lock.lock()
        defer { lock.unlock() }
        // Enough to say why; a flood is cut off.
        if data.count < 16_384 { data.append(more.prefix(16_384 - data.count)) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
