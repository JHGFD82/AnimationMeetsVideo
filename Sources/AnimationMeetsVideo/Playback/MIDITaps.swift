import CoreMIDI
import Foundation

/// Hears note-ons from every MIDI source, so beats can be tapped on a pad
/// or a keyboard. Each tap carries the host time the note arrived at, from
/// Core MIDI, rather than whenever the main thread gets to it, so it lands
/// where it was played. See docs/beat-matching.md, "Tapping on MIDI".
final class MIDITaps: @unchecked Sendable {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    /// Called on the main queue with each tap's host time.
    private let onTap: @MainActor (UInt64) -> Void

    /// Starts listening; nil when Core MIDI can't be reached.
    init?(name: String = "Animation Meets Video", onTap: @escaping @MainActor (UInt64) -> Void) {
        self.onTap = onTap
        // Sources plugged in later are connected as they appear.
        let status = MIDIClientCreateWithBlock(name as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgObjectAdded else { return }
            self?.connectSources()
        }
        guard status == noErr else { return nil }
        let portStatus = MIDIInputPortCreateWithProtocol(client, "\(name) taps" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.receive(list)
        }
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            return nil
        }
        connectSources()
    }

    deinit {
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    /// Connects every source not yet connected; connecting twice is
    /// harmless.
    private func connectSources() {
        for index in 0..<MIDIGetNumberOfSources() {
            MIDIPortConnectSource(port, MIDIGetSource(index), nil)
        }
    }

    private func receive(_ list: UnsafePointer<MIDIEventList>) {
        var taps: [UInt64] = []
        for packet in list.unsafeSequence() {
            let words = withUnsafeBytes(of: packet.pointee.words) { raw in
                Array(raw.bindMemory(to: UInt32.self).prefix(Int(packet.pointee.wordCount)))
            }
            // A time stamp of zero means now.
            let time = packet.pointee.timeStamp == 0 ? mach_absolute_time() : packet.pointee.timeStamp
            taps += Array(repeating: time, count: Self.noteOns(in: words))
        }
        guard !taps.isEmpty else { return }
        let onTap = onTap
        DispatchQueue.main.async {
            MainActor.assumeIsolated { for time in taps { onTap(time) } }
        }
    }

    /// How many note-ons with a velocity are among Universal MIDI Packet
    /// words of MIDI 1.0 channel voice messages; a note-on at velocity 0
    /// is a note-off.
    static func noteOns(in words: [UInt32]) -> Int {
        var count = 0
        var index = 0
        while index < words.count {
            let word = words[index]
            let type = word >> 28
            if type == 0x2, (word >> 16) & 0xF0 == 0x90, word & 0x7F > 0 { count += 1 }
            // Each type of message is its own number of words long.
            let length: Int = switch type {
            case 0x0, 0x1, 0x2, 0x6, 0x7: 1
            case 0x3, 0x4, 0x8, 0x9, 0xA: 2
            case 0xB, 0xC: 3
            default: 4
            }
            index += length
        }
        return count
    }
}
