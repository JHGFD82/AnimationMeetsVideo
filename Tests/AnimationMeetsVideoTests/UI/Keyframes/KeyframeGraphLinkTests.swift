import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Two shapes keyframed in Position, one starting 1 s into the timeline and
/// the other 3 s in, each with keyframes 0 s and 2 s into its own time.
@MainActor
private struct TwoShapes {
    var project = EditingProject.empty
    var keys: [ParameterKey] = []

    init() throws {
        let timelineID = project.rootTimelineID
        for start in [1.0, 3.0] {
            let added = project.addShapeLayer(.rectangle, to: timelineID)
            let shape = try #require(added)
            let transform = project.addEffect(.transform, toClip: shape.clipID, in: timelineID)
            let effectID = try #require(transform)
            var controlID = UUID()
            project.editClip(shape.clipID, in: timelineID) { clip in
                clip.startOffset = CMTime(seconds: start, preferredTimescale: 600)
                let e = clip.effects.index(of: effectID)!
                controlID = clip.effects[e].controls[0].id
                clip.effects[e].controls[0].number = AnimatedValue(ComponentValue(values: [0, 0]), keyframes: [
                    Keyframe(time: .zero, value: ComponentValue(values: [0, 0])),
                    Keyframe(time: CMTime(value: 2, timescale: 1), value: ComponentValue(values: [100, 50])),
                ])
            }
            keys.append(ParameterKey(
                timelineID: timelineID, parameter: .control(.position, clipID: shape.clipID, effectID: effectID, controlID: controlID)
            ))
        }
    }
}

@MainActor
@Suite struct KeyframeGraphLinkTests {
    @Test func linkedGraphsShowTheSameMomentsOfTheTimeline() throws {
        let shapes = try TwoShapes()
        let link = KeyframeGraphLink(shapes.keys)
        let shown = try #require(link.shownTimes(in: shapes.project))
        // Both graphs' keyframes fit: the first's at 1 s, the last's at 5 s.
        #expect(shown.lowerBound < 1 && shown.upperBound > 5)

        // Each lays the stretch out in its own time, so the same timeline
        // moment is at the same place across in both.
        let axes = try shapes.keys.map { try #require(shapes.project.timeAxis(of: $0)) }
        let first = try #require(link.keyTimes(for: axes[0], in: shapes.project))
        let second = try #require(link.keyTimes(for: axes[1], in: shapes.project))
        #expect(abs((first.lowerBound - second.lowerBound) - 2) < 1e-6)
        #expect(abs((first.upperBound - first.lowerBound) - (shown.upperBound - shown.lowerBound)) < 1e-6)

        // Zooming in about 3 s of the timeline zooms both, keeping 3 s put.
        let before = (3 - shown.lowerBound) / (shown.upperBound - shown.lowerBound)
        let zoomed = link.zoomTimes(by: 2, around: 3, in: shapes.project)
        #expect(abs(zoomed - 2) < 1e-6)
        let after = try #require(link.shownTimes(in: shapes.project))
        #expect(abs((3 - after.lowerBound) / (after.upperBound - after.lowerBound) - before) < 1e-6)

        // Scrolling moves the shared stretch.
        let moved = link.panTimes(byPoints: 10, across: 100, in: shapes.project)
        #expect(moved > 0)
        #expect(try #require(link.shownTimes(in: shapes.project)).lowerBound > after.lowerBound)
    }

    @Test func onlyGraphsOfOneTimelineLink() throws {
        let shapes = try TwoShapes()
        let a = KeyframeGraphLink([shapes.keys[0]])
        let b = KeyframeGraphLink([shapes.keys[1]])
        #expect(a.canLink(b))
        #expect(!a.canLink(a))
        var elsewhere = shapes.keys[1]
        elsewhere.timelineID = UUID()
        #expect(!a.canLink(KeyframeGraphLink([elsewhere])))
    }
}
