import CoreGraphics
import CoreMedia
import Testing
@testable import AnimationMeetsVideo

/// A retimed clip's graph in timeline time (docs/keyframing-effects.md,
/// "The Keyframe Designer"): a clip at 200%, from 0 on the timeline, its
/// source trimmed to 0...8 s.
@Suite struct ParameterTimeAxisTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func clip(speed: Double = 200) -> TimelineClip {
        var clip = TimelineClip(source: .graphic, startOffset: .zero, trimStart: .zero, trimEnd: seconds(8), streams: .video)
        clip.time.speed = AnimatedValue(speed)
        return clip
    }

    private func axis(_ clip: TimelineClip) -> ParameterTimeAxis {
        ParameterTimeAxis(clip: clip, span: 0...8, frameDuration: CMTime(value: 1, timescale: 24))
    }

    @Test func keysShowWhereTheTimelinePlaysThemAndRoundTrip() throws {
        let warp = try #require(axis(clip()).warp(.timeline))
        for (key, shown) in [(0.0, 0.0), (2, 1), (4, 2)] {
            #expect(abs(warp.display(key) - shown) < 1e-6)
            #expect(abs(warp.key(warp.display(key)) - key) < 1e-6)
        }
    }

    @Test func clipTimeAndAClipThatIsntRetimedHaveNoWarp() {
        #expect(axis(clip()).warp(.clip) == nil)
        #expect(axis(clip(speed: 100)).warp(.timeline) == nil)
        #expect(!axis(clip(speed: 100)).offersTimeBasis)
        #expect(axis(clip()).offersTimeBasis)
    }

    /// Keys 2 s apart in the clip's time are 1 s apart on the timeline: in
    /// timeline time they sit evenly across, over a plot of the keys'
    /// own 0...4 s, and a point across reads back as the key there.
    @Test func theLayoutSpacesKeysAsTheTimelinePlaysThem() {
        let plot = CGRect(x: 0, y: 0, width: 400, height: 100)
        let warped = KeyframeGraphLayout(times: 0...4, values: [0...1], plot: plot, warp: axis(clip()).warp(.timeline))
        #expect(abs(warped.x(2) - 200) < 1e-6)
        #expect(abs(warped.seconds(atX: 100) - 1) < 1e-6)
        // An animated speed bends lines; a steady one doesn't.
        #expect(!warped.bendsLines)
        var ramp = clip()
        ramp.time.speed = AnimatedValue(100, keyframes: [Keyframe(time: .zero, value: 100), Keyframe(time: seconds(8), value: 300)])
        let bent = KeyframeGraphLayout(times: 0...4, values: [0...1], plot: plot, warp: axis(ramp).warp(.timeline))
        #expect(bent.bendsLines)
        #expect(abs(bent.seconds(atX: bent.x(3)) - 3) < 1e-3)
    }
}
