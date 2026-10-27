import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private let frame = CMTime(value: 1, timescale: 24)

/// Clips' finished pictures kept for later frames (`ClipPictureCache`):
/// what is kept, what is taken, and that a frame drawn from them is the
/// frame drawn without.
@Suite struct ClipPictureCacheTests {
    /// Exposure, so the clip's pixels are changed and its picture is worth
    /// keeping.
    private func exposure(_ stops: Double) -> Effect {
        var effect = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
        effect.controls[0].number = AnimatedValue(ComponentValue(values: [stops]))
        return effect
    }

    /// Eight pixels right over the first frame.
    private func sliding() -> Effect {
        var move = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
        move.controls[0].number.setAnimated(true, at: .zero)
        move.controls[0].number.set(ComponentValue(values: [8, 0]), at: frame)
        return move
    }

    private func same(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { close($0, $1, tolerance: 0.002) }
    }

    @Test func trailsTakeTheClipAsItFinishedAFrameEarlier() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.4, 0.4, 0.4, 1))
        try harness.addSolid(track: 2, SIMD4(0.4, 0.4, 0.4, 1))
        var timeline = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 10, timescale: 1))
        timeline.effects = [sliding(), exposure(1)]
        timeline.shutter.trails = Trails(count: 1, delay: frame, decay: 0.5)
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1))
        let clip = DrawClip(
            content: .media(MediaDraw(
                trackID: 1, base: .identity, url: URL(fileURLWithPath: "/dev/null"), sourceStart: .zero, segmentStart: .zero,
                frameDuration: frame, trails: [TrackCopy(trackID: 2, range: range, strength: 0.5, delay: frame)]
            )),
            stack: ClipStack(clip: timeline, center: CGPoint(x: 8, y: 4), shift: .zero, frameDuration: frame),
            range: range, owner: UUID()
        )
        let kept = ClipPictureCache()
        // Frames in order, as playback and export draw them: each one's
        // trail copy is the picture the frame before kept.
        var drawn: [[SIMD4<Float>]] = []
        for index in 0..<4 {
            drawn.append(try harness.draw([clip], at: CMTimeMultiply(frame, multiplier: Int32(index)), kept: kept))
        }
        #expect(kept.counts.kept == 4)
        #expect(kept.counts.hits == 3)
        for index in 0..<4 {
            #expect(same(drawn[index], try harness.draw([clip], at: CMTimeMultiply(frame, multiplier: Int32(index)))))
        }
    }

    @Test func aDraggedValueDrawsOnlyItsOwnClipAgain() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.2, 0.3, 0.4, 1))
        try harness.addPicture(track: 2) { x, _ in x < 0.5 ? SIMD4(0.6, 0.5, 0.4, 1) : .zero }
        let below = CompositorHarness.clip(track: 1, effects: [exposure(0.5)])
        let above = CompositorHarness.clip(track: 2, effects: [exposure(1)])
        let kept = ClipPictureCache()
        func draw(_ clips: [DrawClip]) throws -> [SIMD4<Float>] { try harness.draw(clips, kept: kept, keeping: .steady) }
        // Drawn once, nothing is known to stay; the same again, both are
        // kept; and the third time both are taken.
        _ = try draw([above, below])
        #expect(kept.counts.kept == 0)
        _ = try draw([above, below])
        #expect(kept.counts.kept == 2)
        _ = try draw([above, below])
        #expect(kept.counts.hits == 2)
        // A drag of the clip above: only it is drawn again, and the frame is
        // the frame drawn from scratch.
        var dragged = above
        dragged.stack.effects = [exposure(1.5)]
        let frame = try draw([dragged, below])
        #expect(kept.counts.hits == 3)
        #expect(same(frame, try harness.draw([dragged, below])))
    }

    @Test func aKeptPictureIsTheRightWayUp() throws {
        var harness = CompositorHarness()
        // Light at the top, dark at the bottom.
        try harness.addPicture(track: 1) { _, y in y < 0.5 ? SIMD4(0.8, 0.8, 0.8, 1) : SIMD4(0.1, 0.1, 0.1, 1) }
        let clip = CompositorHarness.clip(track: 1, effects: [exposure(0.5)])
        let drawn = try harness.draw([clip])
        #expect(harness.pixel(drawn, x: 8, y: 1).x > harness.pixel(drawn, x: 8, y: 6).x)
        // Kept as it is drawn, then taken.
        let kept = ClipPictureCache()
        let keeping = try harness.draw([clip], kept: kept, keeping: .all)
        let taken = try harness.draw([clip], kept: kept, keeping: .all)
        #expect(kept.counts.hits == 1)
        #expect(same(drawn, keeping))
        #expect(same(drawn, taken))
    }

    @Test func aClipThatDependsOnWhatIsBelowOrNeedsNoDrawingIsntKept() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.2, 0.3, 0.4, 1))
        try harness.addSolid(track: 2, SIMD4(0.6, 0.5, 0.4, 1))
        var multiply = Effect(kind: .blending)
        multiply.controls[0].blendMode = .multiply
        let kept = ClipPictureCache()
        _ = try harness.draw(
            [CompositorHarness.clip(track: 2, effects: [exposure(1), multiply]), CompositorHarness.clip(track: 1)], kept: kept, keeping: .all
        )
        #expect(kept.counts.kept == 0)
        // Moved only: as cheap to draw as to take.
        var move = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
        move.controls[0].number = AnimatedValue(ComponentValue(values: [3, 0]))
        _ = try harness.draw([CompositorHarness.clip(track: 1, effects: [move])], kept: kept, keeping: .all)
        #expect(kept.counts.kept == 0)
    }

    @Test func theLeastRecentlyUsedPicturesGoPastTheBudget() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0.2, 0.3, 0.4, 1))
        // Room for two 16 x 8 half-float pictures.
        let kept = ClipPictureCache(budget: 16 * 8 * 8 * 2)
        let clips = (0..<3).map { _ in CompositorHarness.clip(track: 1, effects: [exposure(1)]) }
        for clip in clips { _ = try harness.draw([clip], kept: kept, keeping: .all) }
        #expect(kept.counts.kept == 3)
        #expect(kept.counts.bytes == 16 * 8 * 8 * 2)
        // The last is still there; the first went. (Drawn as they were kept:
        // keeping all is drawing ahead, as playing draws.)
        _ = try harness.draw([clips[2]], kept: kept, keeping: .all)
        #expect(kept.counts.hits == 1)
        _ = try harness.draw([clips[0]], kept: kept, keeping: .all)
        #expect(kept.counts.hits == 1)
    }
}
