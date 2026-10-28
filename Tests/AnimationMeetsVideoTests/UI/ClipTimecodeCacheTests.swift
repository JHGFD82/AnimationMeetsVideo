import CoreMedia
import Testing
@testable import AnimationMeetsVideo

/// The timecodes VoiceOver reads for a clip block (`ClipTimecodeCache`).
@MainActor
struct ClipTimecodeCacheTests {
    @Test func timecodesFollowTheClip() {
        let cache = ClipTimecodeCache()
        var clip = TimelineClip(source: .media(UUID()), startOffset: CMTime(value: 2, timescale: 1), trimStart: .zero, trimEnd: CMTime(value: 3, timescale: 1))
        let first = cache.timecodes(of: clip, frameRate: 24)
        #expect(first.start == clip.startOffset.timecode(frameRate: 24))
        #expect(first.duration == clip.placedDuration.timecode(frameRate: 24))

        // Something VoiceOver doesn't read as timecode changes nothing.
        clip.soundMuted = true
        #expect(cache.timecodes(of: clip, frameRate: 24) == first)

        clip.startOffset = CMTime(value: 5, timescale: 1)
        #expect(cache.timecodes(of: clip, frameRate: 24).start == clip.startOffset.timecode(frameRate: 24))
        #expect(cache.timecodes(of: clip, frameRate: 30).start == clip.startOffset.timecode(frameRate: 30))
    }
}
