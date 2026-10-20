import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct RetimeMarkTests {
    private func second(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func clip(trim: ClosedRange<Double> = 0...4) -> TimelineClip {
        TimelineClip(source: .media(UUID()), startOffset: second(10), trimStart: second(trim.lowerBound), trimEnd: second(trim.upperBound))
    }

    @Test func aClipAtItsOwnSpeedHasNoMarks() {
        #expect(RetimeMark.marks(of: clip()).isEmpty)
    }

    @Test func aSteadySpeedIsReadOutOnceAtTheStart() {
        var c = clip()
        c.time.speed = AnimatedValue(50)
        #expect(RetimeMark.marks(of: c) == [RetimeMark(seconds: 0, speed: 50)])
    }

    @Test func eachKeyframeInsideTheClipIsAMarkAtWhereItPlays() {
        var c = clip()
        c.time.speed.setAnimated(true, at: .zero)
        c.time.speed.set(50, at: second(1))
        c.time.speed.set(200, at: second(9))
        let marks = RetimeMark.marks(of: c)
        // Source second 1 plays after 1 s at 100% ramping to 50%: later than 1 s.
        #expect(marks.count == 2)
        #expect(marks[0] == RetimeMark(seconds: 0, speed: 100))
        #expect(marks[1].speed == 50 && marks[1].seconds > 1)
        #expect(marks[0].ramps(to: marks[1]))
    }

    @Test func keyframesBeforeATrimAreReadAsTheSpeedAtTheStart() {
        var c = clip(trim: 2...6)
        c.time.speed.setAnimated(true, at: .zero)
        c.time.speed.set(300, at: second(4))
        let marks = RetimeMark.marks(of: c)
        #expect(marks.first?.seconds == 0)
        // Between the keyframes at 100% and 300%, halfway.
        #expect(abs((marks.first?.speed ?? 0) - 200) < 1)
    }

    @Test func equalSpeedsDoNotRamp() {
        #expect(!RetimeMark(seconds: 0, speed: 100).ramps(to: RetimeMark(seconds: 1, speed: 100)))
    }
}

@Suite struct CompositionKeySpeedTests {
    private func project() -> (EditingProject, UUID, UUID) {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "m", kind: .video, url: URL(fileURLWithPath: "/tmp/none.mov"), duration: CMTime(value: 4, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let placed = project.importClip(media, intoTimeline: project.rootTimelineID)!
        return (project, project.rootTimelineID, placed.clipID)
    }

    @Test func aSpeedChangeAloneIsOnlyASpeedChange() {
        let (before, tl, clip) = project()
        var after = before
        after.editClip(clip, in: tl) { $0.time.speed = AnimatedValue(50) }
        #expect(CompositionKey(project: after).differsOnlyInSpeed(from: CompositionKey(project: before)))
    }

    @Test func aSpeedChangeWithAnEffectChangeIsNot() {
        let (before, tl, clip) = project()
        var after = before
        after.editClip(clip, in: tl) { $0.time.speed = AnimatedValue(50); $0.time.frameBlending = .blend }
        #expect(!CompositionKey(project: after).differsOnlyInSpeed(from: CompositionKey(project: before)))
    }
}
