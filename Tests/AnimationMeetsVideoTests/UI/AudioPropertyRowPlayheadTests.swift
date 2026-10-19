import CoreMedia
import Testing
@testable import AnimationMeetsVideo

/// A sound row finds the playhead when it acts, not from what it was built
/// with, so one that isn't redrawn by the playhead still keyframes where it
/// is (see `PlayheadTime`).
@MainActor
struct AudioPropertyRowPlayheadTests {
    private final class Box {
        var value: AnimatedValue<Double>
        init(_ value: AnimatedValue<Double>) { self.value = value }
    }

    private func row(_ box: Box, _ playhead: PlayheadState) -> AudioPropertyRow {
        AudioPropertyRow(
            value: box.value, playhead: PlayheadTime(playhead), onEdit: { change in change(&box.value) }, onSeek: { _ in }
        )
    }

    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    @Test func animatingAFixedValueKeyframesWhereThePlayheadIsNow() {
        let box = Box(AnimatedValue(-4.5))
        let playhead = PlayheadState()
        let row = row(box, playhead)
        // Moved after the row was built: a fixed value isn't redrawn by it.
        playhead.time = seconds(0.75)
        row.toggleAnimated()
        #expect(box.value.isAnimated)
        #expect(box.value.keyframes.map(\.time) == [seconds(0.75)])
    }

    @Test func aKeyframeIsToggledAtTheCurrentPlayhead() {
        var animated = AnimatedValue(0.0)
        animated.setAnimated(true, at: .zero)
        let box = Box(animated)
        let playhead = PlayheadState()
        let row = row(box, playhead)
        playhead.time = seconds(2)
        row.toggleKeyframe()
        #expect(box.value.keyframes.map(\.time).contains(seconds(2)))
        row.toggleKeyframe()
        #expect(!box.value.keyframes.map(\.time).contains(seconds(2)))
    }

    @Test func aFixedTimeStaysWhereItWas() {
        let box = Box(AnimatedValue(0.0))
        let row = AudioPropertyRow(
            value: box.value, time: seconds(1), onEdit: { change in change(&box.value) }, onSeek: { _ in }
        )
        row.toggleAnimated()
        #expect(box.value.keyframes.map(\.time) == [seconds(1)])
    }
}
