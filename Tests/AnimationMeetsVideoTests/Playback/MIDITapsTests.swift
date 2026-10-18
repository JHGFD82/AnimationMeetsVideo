import CoreMIDI
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct MIDITapsTests {
    /// A MIDI 1.0 channel voice message as a Universal MIDI Packet word.
    private func word(_ status: UInt32, _ note: UInt32, _ velocity: UInt32) -> UInt32 {
        0x2000_0000 | status << 16 | note << 8 | velocity
    }

    @Test func noteOnsWithAVelocityAreTaps() {
        #expect(MIDITaps.noteOns(in: [word(0x90, 60, 100)]) == 1)
        // Velocity 0 is a note-off; so is 0x80.
        #expect(MIDITaps.noteOns(in: [word(0x90, 60, 0), word(0x80, 60, 64)]) == 0)
        // Any channel; a controller isn't a tap.
        #expect(MIDITaps.noteOns(in: [word(0x99, 36, 127), word(0xB0, 1, 64)]) == 1)
        // A two-word message is stepped over whole.
        #expect(MIDITaps.noteOns(in: [0x4090_3C00, 0xFFFF_0000, word(0x90, 62, 90)]) == 1)
    }

    /// A note sent from a virtual source arrives with the time it was sent
    /// for, not when it was handled.
    @MainActor @Test func aTapKeepsItsTimeStamp() async throws {
        var client = MIDIClientRef()
        guard MIDIClientCreateWithBlock("AMV test" as CFString, &client, nil) == noErr else { return }
        defer { MIDIClientDispose(client) }
        var source = MIDIEndpointRef()
        guard MIDISourceCreateWithProtocol(client, "AMV test pad" as CFString, ._1_0, &source) == noErr else { return }
        defer { MIDIEndpointDispose(source) }

        let stamp = mach_absolute_time() - 1_000_000
        let received: UInt64? = await withCheckedContinuation { continuation in
            var resumed = false
            func finish(_ value: UInt64?) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            let taps = MIDITaps(name: "AMV test listener") { time in finish(time) }
            guard let taps else { return finish(nil) }
            var list = MIDIEventList()
            let packet = MIDIEventListInit(&list, ._1_0)
            var message = word(0x90, 60, 100)
            _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, stamp, 1, &message)
            MIDIReceivedEventList(source, &list)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withExtendedLifetime(taps) { finish(nil) }
            }
        }
        #expect(received == stamp)
    }
}
