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
        reader.take(Array(repeating: one, count: HelperFrameReader.mostUnread + 1).reduce(Data(), +))
        await #expect(throws: ScriptHelperError.self) { _ = try await reader.next() }
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
