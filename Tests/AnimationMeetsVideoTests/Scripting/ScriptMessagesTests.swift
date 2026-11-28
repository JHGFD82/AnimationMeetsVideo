import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ScriptMessagesTests {
    @Test func aFrameIsItsLengthItsHeaderAndItsPayload() throws {
        let frame = HelperFrame(header: ["type": "result", "run": 3], payload: Data([1, 2, 3]))
        let data = try frame.encoded()
        let length = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24
        let header = try JSONDecoder().decode(JSONValue.self, from: data[4..<4 + length])
        #expect(header["bytes"] == 3 && header["type"] == "result")
        #expect(data.suffix(3) == Data([1, 2, 3]))
    }

    @Test func framesAreReadHoweverTheBytesArrive() throws {
        let frames = [
            HelperFrame(header: ["type": "output", "text": "hello"]),
            HelperFrame(header: ["type": "result", "run": 1], payload: Data(repeating: 7, count: 16)),
        ]
        let bytes = try frames.map { try $0.encoded() }.reduce(Data(), +)
        var decoder = HelperFrame.Decoder()
        var read: [HelperFrame] = []
        // One byte at a time: every cut a pipe could make.
        for byte in bytes { read += try decoder.take(Data([byte])) }
        #expect(read.map(\.type) == ["output", "result"])
        #expect(read[1].payload == Data(repeating: 7, count: 16))
        #expect(read[1].header["bytes"] == 16)
    }

    @Test func aHeaderTooLongToBeOneIsABrokenStream() {
        var decoder = HelperFrame.Decoder()
        #expect(throws: ScriptHelperError.self) { try decoder.take(Data([0xFF, 0xFF, 0xFF, 0x7F])) }
    }

    /// A header claiming a payload no message has is a broken stream at
    /// once, not bytes to wait for without end (code-review-notes.md, F57).
    @Test func aPayloadTooLargeToBeOneIsABrokenStream() throws {
        let json = try JSONEncoder().encode(JSONValue.object(["type": "result", "bytes": .number(Double(1 << 40))]))
        var data = Data()
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        var decoder = HelperFrame.Decoder()
        #expect(throws: ScriptHelperError.self) { try decoder.take(data) }
    }

    /// Many frames in one read all come out, and frames nothing reads end
    /// the stream once past the most kept waiting.
    @Test func framesNoRunReadsEndTheStream() async throws {
        let one = try HelperFrame(header: ["type": "output", "text": "x"]).encoded()
        var decoder = HelperFrame.Decoder()
        #expect(try decoder.take(Data(repeating: 0, count: 0) + Array(repeating: one, count: 500).reduce(Data(), +)).count == 500)

        let reader = HelperFrameReader()
        reader.take(Array(repeating: one, count: reader.limits.mostUnread + 1).reduce(Data(), +))
        await #expect(throws: ScriptHelperError.self) { _ = try await reader.next() }
    }

    /// Just a header, as a helper would send before a payload: the frame's
    /// first bytes, with none of what it claims to carry.
    private func header(_ fields: JSONValue) throws -> Data {
        let json = try JSONEncoder().encode(fields)
        var data = Data()
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        return data + json
    }

    /// Outside a run nothing may carry a payload: a header claiming one is
    /// a broken stream before any of it is sent, so nothing is held for it
    /// (code-review-notes.md, F57).
    @Test func aPayloadNoRunAskedForIsABrokenStreamFromItsHeader() async throws {
        let reader = HelperFrameReader(limits: .expressions)
        reader.take(try header(["type": "pong", "id": 1, "bytes": 8]))
        await #expect(throws: ScriptHelperError.self) { _ = try await reader.next() }
    }

    /// A run's result may carry what it asked for, and a header claiming a
    /// byte more is refused before the payload arrives.
    @Test func aResultCarriesAtMostWhatItsRunAskedFor() async throws {
        let reader = HelperFrameReader(limits: .expressions)
        reader.allowPayload(upTo: 16)
        reader.take(try HelperFrame(header: ["type": "result", "run": 1], payload: Data(repeating: 1, count: 16)).encoded())
        #expect(try await reader.next().payload.count == 16)
        reader.take(try header(["type": "result", "run": 1, "bytes": 17]))
        await #expect(throws: ScriptHelperError.self) { _ = try await reader.next() }
    }

    /// Frames as long as a header may be, sent again and again with no run
    /// reading them, end the stream by their bytes long before their count:
    /// what the app holds of them stays within the expressions' budget.
    @Test func repeatedLongestFramesEndTheStreamByTheirBytes() async throws {
        let limits = HelperLimits.expressions
        let text = String(repeating: "x", count: limits.largestHeader - 100)
        let one = try HelperFrame(header: ["type": "output", "run": 1, "text": .string(text)]).encoded()
        #expect(one.count - 4 <= limits.largestHeader)
        let reader = HelperFrameReader(limits: limits)
        let fit = limits.mostBuffered / one.count
        for _ in 0..<fit { reader.take(one) }
        #expect(try await reader.next().type == "output")
        for _ in 0...fit { reader.take(one) }
        var read = 0
        await #expect(throws: ScriptHelperError.self) {
            while true {
                _ = try await reader.next()
                read += 1
            }
        }
        #expect(read < fit)
    }

    /// An expression's header longer than its helper takes, and one nested
    /// past what the decoder reads, are broken streams, not a crash.
    @Test func anExpressionsHeaderIsShortAndShallow() async throws {
        let long = HelperFrameReader(limits: .expressions)
        let text = String(repeating: "x", count: HelperLimits.expressions.largestHeader)
        long.take(try HelperFrame(header: ["type": "output", "text": .string(text)]).encoded())
        await #expect(throws: ScriptHelperError.self) { _ = try await long.next() }

        let deep = HelperFrameReader(limits: .expressions)
        let json = Data((String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)).utf8)
        var data = Data()
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        deep.take(data + json)
        await #expect(throws: (any Error).self) { _ = try await deep.next() }
    }

    /// An expression's request allows its samples' bytes, exactly; a
    /// script's, a line's and one whose sizes overflow allow none.
    @Test func aRequestAllowsItsOwnSamplesOnly() {
        var expression = HelperRequest(kind: .expression, code: "t")
        expression.fields = ["count": 120, "width": 3]
        #expect(expression.largestResult == 120 * 3 * 8)
        expression.fields = ["count": .number(8e15), "width": 2_000]
        #expect(expression.largestResult == 0)
        var script = HelperRequest(kind: .script, code: "pass")
        script.fields = ["count": 120, "width": 3]
        #expect(script.largestResult == 0)
    }

    @Test func aRequestCarriesItsFileAndFolder() {
        let request = HelperRequest(kind: .script, code: "pass", path: URL(filePath: "/p/Scripts/stagger.py"))
        let header = request.header(id: 4)
        #expect(header["type"] == "script" && header["id"] == 4 && header["code"] == "pass")
        #expect(header["path"] == "/p/Scripts/stagger.py" && header["folder"] == "/p/Scripts")
    }

    @Test func aReplyIsAValueOrAnErrorTheHelperRaises() {
        #expect(HelperReply.value(["a": 1]).header(id: 2) == ["type": "reply", "id": 2, "value": ["a": 1]])
        let refused = HelperReply.error(.refused("Bake them first.")).header(id: 5)
        #expect(refused["error"] == ["kind": "refused", "message": "Bake them first."])
    }

    @Test func aFailureSaysItsLine() {
        let failure = ScriptFailure(["exception": "NameError", "message": "name 'tim' is not defined", "line": 2])
        #expect(failure.summary == "Line 2: NameError: name 'tim' is not defined")
        #expect(!failure.wasStopped)
        #expect(ScriptFailure(exception: "KeyboardInterrupt", message: "Stopped.").wasStopped)
    }

    @Test func versionsCompareAndTheOldestSupportedIs3_11() {
        #expect(PythonVersion("3.14.0")! > PythonVersion("3.9.18")!)
        #expect(PythonVersion("3.11")?.isSupported == true)
        #expect(PythonVersion("3.10.14")?.isSupported == false)
        #expect(PythonVersion("three") == nil)
    }
}
