import AVFoundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct BeatClickPlayerTests {
    @Test func blipIsShortQuietAndFadesIn() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let blip = try #require(BeatClickPlayer.makeBlip(frequency: 1000, format: format))
        #expect(blip.frameLength == 2_400)

        let channels = try #require(blip.floatChannelData)
        let left = UnsafeBufferPointer(start: channels[0], count: Int(blip.frameLength))
        let right = UnsafeBufferPointer(start: channels[1], count: Int(blip.frameLength))
        #expect(Array(left) == Array(right))
        #expect(left[0] == 0)
        let peak = left.map(abs).max() ?? 0
        #expect(peak > 0.3 && peak <= 0.5)
        // Decayed to near silence by the end, so it doesn't click off.
        #expect(abs(left[left.count - 1]) < 0.01)
    }
}
