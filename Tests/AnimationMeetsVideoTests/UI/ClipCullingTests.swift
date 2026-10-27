import CoreMedia
import Testing
@testable import AnimationMeetsVideo

/// Which clips a layer's row draws (`LayerClipRow.isVisible`).
struct ClipCullingTests {
    /// A clip from `start` to `end` seconds.
    private func clip(_ start: Double, _ end: Double) -> TimelineClip {
        TimelineClip(
            id: UUID(), source: .adjustment, startOffset: CMTime(seconds: start, preferredTimescale: 600),
            trimStart: .zero, trimEnd: CMTime(seconds: end - start, preferredTimescale: 600)
        )
    }

    // At 10 points a second, with the view scrolled to 1000...1500 (100 s
    // to 150 s), and 200 points (20 s) drawn either side.

    @Test func aClipInViewIsDrawn() {
        #expect(LayerClipRow.isVisible(clip(110, 120), pixelsPerSecond: 10, in: 1000...1500))
    }

    @Test func aClipAcrossTheViewIsDrawn() {
        #expect(LayerClipRow.isVisible(clip(0, 400), pixelsPerSecond: 10, in: 1000...1500))
    }

    @Test func aClipJustOutOfViewIsDrawnWithinTheMargin() {
        #expect(LayerClipRow.isVisible(clip(70, 85), pixelsPerSecond: 10, in: 1000...1500))
        #expect(LayerClipRow.isVisible(clip(165, 180), pixelsPerSecond: 10, in: 1000...1500))
    }

    @Test func aClipFarOutOfViewIsntDrawn() {
        #expect(!LayerClipRow.isVisible(clip(10, 70), pixelsPerSecond: 10, in: 1000...1500))
        #expect(!LayerClipRow.isVisible(clip(175, 200), pixelsPerSecond: 10, in: 1000...1500))
    }
}
