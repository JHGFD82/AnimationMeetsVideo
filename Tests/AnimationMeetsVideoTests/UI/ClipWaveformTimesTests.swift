import CoreMedia
import Testing
@testable import AnimationMeetsVideo

/// Which file time each point of a clip's waveform shows
/// (`WaveformFileTimes`, `ClipBlockView.waveformFileTimes`).
struct ClipWaveformTimesTests {
    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    private let media = MediaClip(
        name: "Song", kind: .audio, url: nil, duration: CMTime(value: 60, timescale: 1),
        frameRate: 0, colorSpace: .rec709, codecName: "AAC"
    )

    @Test func oneSpeedIsAStraightLine() {
        let times = WaveformFileTimes.linear(start: 2, secondsPerPoint: 0.01)
        #expect(times.seconds(atX: 0) == 2)
        #expect(abs(times.seconds(atX: 100) - 3) < 1e-9)
        #expect(abs(times.seconds(atX: -10) - 1.9) < 1e-9)
    }

    @Test func anchorsAreFollowedBetweenAndPastTheEnds() {
        let times = WaveformFileTimes(anchors: [.init(x: 10, seconds: 1), .init(x: 0, seconds: 0), .init(x: 30, seconds: 5)])
        #expect(times.seconds(atX: 5) == 0.5)
        #expect(times.seconds(atX: 20) == 3)
        #expect(times.seconds(atX: 40) == 7)
    }

    /// A clip at one speed is read as before, a line.
    @Test func aClipAtOneSpeedHasTwoAnchors() {
        let clip = TimelineClip(source: .media(media.id), startOffset: seconds(1), trimStart: seconds(2), trimEnd: seconds(6))
        let times = ClipBlockView.waveformFileTimes(of: clip, media: media, pixelsPerSecond: 50, inset: 0, width: 200)
        #expect(times.anchors.count == 2)
        #expect(abs(times.seconds(atX: 200) - 6) < 0.01)
    }

    /// Ramping from half speed to double, the end of the drawn waveform is
    /// the end of the trim, where reading at the first speed throughout
    /// would stop far short.
    @Test func aRampedClipIsDrawnAsFarAsItPlays() {
        var clip = TimelineClip(source: .media(media.id), startOffset: .zero, trimStart: .zero, trimEnd: seconds(8))
        clip.time.speed = AnimatedValue(100, keyframes: [Keyframe(time: seconds(2), value: 50), Keyframe(time: seconds(6), value: 200)])
        #expect(RetimeMark.marks(of: clip).count > 1)
        let width = CGFloat(clip.placedDuration.seconds) * 50
        let times = ClipBlockView.waveformFileTimes(of: clip, media: media, pixelsPerSecond: 50, inset: 0, width: width)
        #expect(times.anchors.count > 2)
        #expect(abs(times.seconds(atX: 0)) < 0.01)
        #expect(abs(times.seconds(atX: width) - 8) < 0.05)
        let firstSpeedOnly = 0.5 * clip.placedDuration.seconds
        #expect(abs(firstSpeedOnly - 8) > 1)
    }
}
