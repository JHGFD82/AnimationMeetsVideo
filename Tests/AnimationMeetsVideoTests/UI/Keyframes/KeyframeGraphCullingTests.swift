import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// Keyframes a second apart from 0 s, valued as their time.
private func everySecond(_ count: Int) -> AnimatedValue<ComponentValue> {
    AnimatedValue(ComponentValue(values: [0]), keyframes: (0..<count).map {
        Keyframe(time: seconds(Double($0)), value: ComponentValue(values: [Double($0)]))
    })
}

@MainActor
@Suite struct KeyframeGraphCullingTests {
    @Test func indicesAreTheKeyframesInTheStretchEndsIncluded() {
        let keyframes = everySecond(10).keyframes
        #expect(KeyframeGraphLayout.indices(of: keyframes, from: 2, through: 5) == 2..<6)
        #expect(KeyframeGraphLayout.indices(of: keyframes, from: 2.5, through: 4.5) == 3..<5)
        #expect(KeyframeGraphLayout.indices(of: keyframes, from: -3, through: 100) == 0..<10)
        // A stretch between two keyframes, or past them all, has none.
        #expect(KeyframeGraphLayout.indices(of: keyframes, from: 3.2, through: 3.8).isEmpty)
        #expect(KeyframeGraphLayout.indices(of: keyframes, from: 20, through: 30).isEmpty)
        #expect(KeyframeGraphLayout.indices(of: keyframes, from: 5, through: 2).isEmpty)
        #expect(KeyframeGraphLayout.indices(of: [], from: 0, through: 1).isEmpty)
    }

    @Test func keyframeIndicesFollowTheLayoutAcross() {
        let layout = KeyframeGraphLayout(times: 0...10, values: [0...10], plot: CGRect(x: 0, y: 0, width: 100, height: 100))
        // Ten points a second: 25 to 45 points across is 2.5 s to 4.5 s.
        #expect(layout.keyframeIndices(everySecond(10).keyframes, fromX: 25, toX: 45) == 3..<5)
    }

    @Test func thePresetsTakeTheKeyframeAtThePlayhead() {
        let value = everySecond(5)
        let timeline = EditingProject.empty.timelines[0]
        let axis = ParameterTimeAxis(clip: nil, span: 0...10, frameDuration: timeline.frameDuration)
        let at = { (playhead: Double, selected: SelectionSet<CMTime>) in
            KeyframeGraphView.presetTargets(selected: selected, value: value, axis: axis, timeline: timeline, playhead: seconds(playhead))
        }
        #expect(at(3, SelectionSet()) == [seconds(3)])
        #expect(at(3.5, SelectionSet()).isEmpty)
        // Those selected that are still there, before the playhead's.
        var selected = SelectionSet<CMTime>()
        selected.set([seconds(1), seconds(4), seconds(9)], anchor: seconds(1))
        #expect(at(3, selected) == [seconds(1), seconds(4)])
    }
}
