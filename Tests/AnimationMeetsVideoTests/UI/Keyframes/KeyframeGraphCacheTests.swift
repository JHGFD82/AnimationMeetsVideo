import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A project with one shape whose Position has keyframes at 0 s and 2 s.
@MainActor
private struct OneShape {
    var project = EditingProject.empty
    var key: ParameterKey

    init() throws {
        let timelineID = project.rootTimelineID
        let added = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(added)
        let transform = project.addEffect(.transform, toClip: shape.clipID, in: timelineID)
        let effectID = try #require(transform)
        var controlID = UUID()
        project.editClip(shape.clipID, in: timelineID) { clip in
            let e = clip.effects.index(of: effectID)!
            controlID = clip.effects[e].controls[0].id
            clip.effects[e].controls[0].number = AnimatedValue(ComponentValue(values: [0, 0]), keyframes: [
                Keyframe(time: .zero, value: ComponentValue(values: [0, 0])),
                Keyframe(time: CMTime(value: 2, timescale: 1), value: ComponentValue(values: [100, 50])),
            ])
        }
        key = ParameterKey(timelineID: timelineID, parameter: .control(.position, clipID: shape.clipID, effectID: effectID, controlID: controlID))
    }
}

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
@Suite struct KeyframeGraphCacheTests {
    @Test func keyframesAreReadAgainOnlyAfterAnEdit() throws {
        var shape = try OneShape()
        shape.project.stampEdit(since: nil)
        let cache = KeyframeGraphCache()
        let first = try #require(cache.source(of: shape.key, in: shape.project).stored)
        #expect(first.keyframes.count == 2)
        #expect(cache.source(of: shape.key, in: shape.project).axis != nil)

        let before = shape.project
        shape.project.editComponents(of: shape.key) { $0.set(ComponentValue(values: [5, 5]), at: seconds(1)) }
        shape.project.stampEdit(since: before)
        #expect(try #require(cache.source(of: shape.key, in: shape.project).stored).keyframes.count == 3)
    }

    @Test func aProjectNeverStampedIsReadEveryTime() throws {
        var shape = try OneShape()
        let cache = KeyframeGraphCache()
        #expect(try #require(cache.source(of: shape.key, in: shape.project).stored).keyframes.count == 2)
        shape.project.editComponents(of: shape.key) { $0.set(ComponentValue(values: [5, 5]), at: seconds(1)) }
        #expect(shape.project.editCount == 0)
        #expect(try #require(cache.source(of: shape.key, in: shape.project).stored).keyframes.count == 3)
    }

    @Test func fitsAreTheLayoutsAndFollowTheKeyframes() {
        let cache = KeyframeGraphCache()
        var value = everySecond(4)
        value.applyEase(.easyEase, at: seconds(1))
        let span = KeyframeGraphLayout.padded(0...10)
        #expect(cache.fitValues(value, offset: [3], components: [0]) == KeyframeGraphLayout.fitValues(value, offset: [3], components: [0]))
        #expect(cache.fitTimes(value, span: span, frame: 1.0 / 24) == KeyframeGraphLayout.fitTimes(value, span: span, frame: 1.0 / 24))
        #expect(cache.segments(of: value).count == 3)

        value.set(ComponentValue(values: [40]), at: seconds(8))
        #expect(cache.fitValues(value, offset: [3], components: [0]) == KeyframeGraphLayout.fitValues(value, offset: [3], components: [0]))
        #expect(cache.fitTimes(value, span: span, frame: 1.0 / 24) == KeyframeGraphLayout.fitTimes(value, span: span, frame: 1.0 / 24))
        #expect(cache.segments(of: value).count == 4)
    }

    @Test func aLinksBoundsFollowItsEdits() throws {
        var shape = try OneShape()
        shape.project.stampEdit(since: nil)
        let link = KeyframeGraphLink([shape.key])
        let before = try #require(link.bounds(in: shape.project))
        #expect(before.fit.upperBound < 3)

        let project = shape.project
        shape.project.editComponents(of: shape.key) { $0.set(ComponentValue(values: [5, 5]), at: seconds(4)) }
        shape.project.stampEdit(since: project)
        // The clip is five seconds long, which the fit stays inside.
        let after = try #require(link.bounds(in: shape.project))
        #expect(after.fit.upperBound > 4)
    }
}
