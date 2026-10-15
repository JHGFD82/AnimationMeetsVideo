import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ClipTimingTests {
    private func second(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func clip(speed: Double = 100, trim: ClosedRange<Double> = 2...6, start: Double = 10) -> TimelineClip {
        var clip = TimelineClip(source: .media(UUID()), startOffset: second(start), trimStart: second(trim.lowerBound), trimEnd: second(trim.upperBound))
        clip.time.speed = AnimatedValue(speed)
        return clip
    }

    @Test func aClipAtItsOwnSpeedPlaysItsSourceStraight() {
        let c = clip()
        #expect(c.placedDuration == c.trimmedDuration && c.endOffset == second(14))
        #expect(c.timelineTime(forSourceTime: second(3)) == second(11))
        #expect(c.sourceTime(atTimelineTime: second(13)) == second(5))
        #expect(!c.isRetimed)
    }

    @Test(arguments: [25.0, 50, 200, 400, 33.3])
    func speedIsHowFastTheSourcePlays(speed: Double) {
        let c = clip(speed: speed)
        // Four seconds of source takes 400/speed seconds.
        #expect(abs(c.placedDuration.seconds - 400 / speed) < 1e-4)
        #expect(abs(c.endOffset.seconds - (10 + 400 / speed)) < 1e-4)
        // And the two mappings undo each other.
        for source in [2.0, 3.3, 5.9] {
            let there = c.timelineTime(forSourceTime: second(source))
            #expect(abs(c.sourceTime(atTimelineTime: there).seconds - source) < 1e-4)
        }
        #expect(c.isRetimed == (speed != 100))
    }

    @Test func aWholePercentIsExactOnTheFrameGrid() {
        var c = clip(speed: 50)
        // 1001/24000 s of source at 50% is 2002/24000 s on the timeline.
        c.trimStart = .zero
        c.trimEnd = CMTime(value: 1001, timescale: 24000)
        #expect(c.placedDuration == CMTime(value: 2002, timescale: 24000))
    }

    @Test func aRampTakesTheIntegralOfItsReciprocalSpeed() {
        var c = clip(speed: 100, trim: 0...2, start: 0)
        // Speeding up from 100% to 200% over the two seconds of source.
        c.time.speed.setAnimated(true, at: .zero)
        c.time.speed.set(200, at: second(2))
        // The integral of 1 / (1 + s / 2) over 0...2 is 2 ln 2.
        #expect(abs(c.placedDuration.seconds - 2 * log(2)) < 1e-3)
        for source in [0.3, 1.0, 1.9] {
            let there = c.timelineTime(forSourceTime: second(source))
            #expect(abs(c.sourceTime(atTimelineTime: there).seconds - source) < 1e-3)
        }
        // Held at 200% beyond the last keyframe.
        #expect(abs(c.timelineLength(ofSource: second(2), to: second(4)).seconds - 1) < 1e-3)
    }

    @Test func trimmingTheEndOfARetimedClipTrimsTheSourceItNeverStretches() {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(name: "m", kind: .video, url: nil, duration: second(20), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let placed = project.importClip(media, intoTimeline: t)!
        project.editClip(placed.clipID, in: t) {
            $0.trimStart = second(2)
            $0.trimEnd = second(6)
            $0.startOffset = second(1)
            $0.time.speed = AnimatedValue(50)
        }
        let before = project.clipAndLayer(placed.clipID, in: t)!.clip
        #expect(before.endOffset == second(9))
        // Dragging the end out to 11 s on the timeline plays 5 s of source
        // from the same start: the trim end moves, the speed doesn't.
        project.trimClipEnd(placed.clipID, in: t, layer: placed.layerID, to: before.sourceTime(atTimelineTime: second(11)))
        let after = project.clipAndLayer(placed.clipID, in: t)!.clip
        #expect(abs(after.endOffset.seconds - 11) < 0.05)
        #expect(abs(after.trimEnd.seconds - 7) < 0.05 && after.time.speed == AnimatedValue(50))
        // Not past the end of the file: 20 s of source from 2 s takes 36 s.
        project.trimClipEnd(placed.clipID, in: t, layer: placed.layerID, to: second(50))
        #expect(project.clipAndLayer(placed.clipID, in: t)!.clip.trimEnd == second(20))
    }

    @Test func trimmingTheStartOfARetimedClipKeepsItsEndAndItsSpeed() {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(name: "m", kind: .video, url: nil, duration: second(20), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let placed = project.importClip(media, intoTimeline: t)!
        project.editClip(placed.clipID, in: t) {
            $0.trimStart = second(4)
            $0.trimEnd = second(8)
            $0.startOffset = second(10)
            $0.time.speed = AnimatedValue(200)
        }
        let before = project.clipAndLayer(placed.clipID, in: t)!.clip
        #expect(before.endOffset == second(12))
        project.trimClipStart(placed.clipID, in: t, layer: placed.layerID, to: second(6))
        let after = project.clipAndLayer(placed.clipID, in: t)!.clip
        #expect(abs(after.endOffset.seconds - 12) < 0.05)
        #expect(abs(after.startOffset.seconds - 11) < 0.05 && abs(after.trimStart.seconds - 6) < 0.05)
    }

    @Test func splittingARetimedClipSplitsItsSourceAndKeepsBothPlayingTheSameWay() {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(name: "m", kind: .video, url: nil, duration: second(20), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let placed = project.importClip(media, intoTimeline: t)!
        project.editClip(placed.clipID, in: t) {
            $0.trimStart = .zero
            $0.trimEnd = second(8)
            $0.startOffset = .zero
            $0.time.speed = AnimatedValue(50)
        }
        let whole = project.clipAndLayer(placed.clipID, in: t)!.clip
        #expect(whole.placedDuration == second(16))
        project.split(placed.clipID, in: t, layer: placed.layerID, atTimelineTime: second(6))
        let halves = project.timeline(id: t)!.layers.first { $0.id == placed.layerID }!.clips
        #expect(halves.count == 2)
        #expect(halves[0].endOffset == second(6) && halves[1].startOffset == second(6))
        #expect(abs(halves[0].trimEnd.seconds - 3) < 1e-3 && abs(halves[1].trimStart.seconds - 3) < 1e-3)
        #expect(halves.allSatisfy { $0.time == whole.time })
        #expect(abs(halves[1].endOffset.seconds - 16) < 1e-3)
    }

    @Test func retimedClipsDontJoinTransitions() {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(name: "m", kind: .video, url: nil, duration: second(20), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let a = project.importClip(media, intoTimeline: t)!
        let layer = project.timeline(id: t)!.layers[0]
        _ = layer
        let clip = project.clipAndLayer(a.clipID, in: t)!.clip
        var next = clip
        next.id = UUID()
        next.startOffset = clip.endOffset
        let layerClips = [clip, next]
        #expect(project.successor(joining: clip, among: layerClips) != nil)
        next.time.speed = AnimatedValue(50)
        #expect(project.successor(joining: clip, among: [clip, next]) == nil)
    }

    @Test func theStackReadsItsKeyframesInTheClipsSourceTime() {
        var c = clip(speed: 50, trim: 0...4, start: 10)
        var effect = Effect(kind: .transform, controls: [EffectControl(kind: .opacity)])
        effect.controls[0].number.setAnimated(true, at: second(0))
        effect.controls[0].number.set(ComponentValue(values: [0]), at: second(2))
        c.effects = [effect]
        let stack = ClipStack(clip: c, center: .zero, shift: .zero)
        // 1 s of source has played after 2 s of the timeline: halfway.
        #expect(abs(stack.resolve(atRoot: second(12)).placement.opacity - 0.5) < 1e-6)
        #expect(stack.resolve(atRoot: second(14)).placement.opacity == 0)
        // The keyframes end 2 s of source in, which is 4 s into the clip.
        #expect(stack.animatedRanges == [CMTimeRange(start: second(10), end: second(14))])
    }

    @Test func retimingAClipMovesTheOnesAfterItAndKeepsItsEndOnAFrame() {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(name: "m", kind: .video, url: nil, duration: second(20), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let first = project.importClip(media, intoTimeline: t)!
        let layerID = first.layerID
        project.editClip(first.clipID, in: t) { $0.trimStart = .zero; $0.trimEnd = second(4); $0.startOffset = .zero }
        var later = project.clipAndLayer(first.clipID, in: t)!.clip
        later.id = UUID()
        later.startOffset = second(5)
        project.timelines[0].layers[0].clips.append(later)

        project.editTime(ofClip: first.clipID, in: t, layer: layerID) { $0.speed = AnimatedValue(50) }
        var clips = project.timeline(id: t)!.layers[0].clips.sorted { $0.startOffset < $1.startOffset }
        // Four seconds at 50% last eight: the clip after moves by the four it
        // grew by, keeping the second between them.
        #expect(clips[0].endOffset == second(8))
        #expect(clips[1].startOffset == second(9))

        // A speed that doesn't divide into frames still ends on one.
        project.editTime(ofClip: first.clipID, in: t, layer: layerID) { $0.speed = AnimatedValue(70) }
        clips = project.timeline(id: t)!.layers[0].clips.sorted { $0.startOffset < $1.startOffset }
        let timeline = project.timeline(id: t)!
        #expect(clips[0].endOffset == timeline.frameAligned(clips[0].endOffset, .nearest))
        #expect(clips[1].startOffset == CMTimeAdd(clips[0].endOffset, second(1)))

        // The speed is kept within what it can be.
        project.editTime(ofClip: first.clipID, in: t, layer: layerID) { $0.speed = AnimatedValue(0) }
        #expect(project.timeline(id: t)!.layers[0].clips.first { $0.id == first.clipID }!.time.speed.value == 1)
    }

    @Test func timeAndShutterRoundTripThroughTheProjectFile() throws {
        var c = clip(speed: 40)
        c.time.speed.setAnimated(true, at: second(2))
        c.time.speed.set(250, at: second(5))
        c.time.frameBlending = .opticalFlow
        c.time.echo = Echo(count: 5, delay: CMTime(value: 1001, timescale: 12000), decay: 0.4)
        c.time.sound = .changePitch
        c.shutter.motionBlur = MotionBlur(angle: 270, samples: 12)
        c.shutter.trails = Trails(count: 3, delay: CMTime(value: 2, timescale: 24), decay: 0.7)
        let time = try #require(ProjectFile.ClipTimeEntry(c.time))
        let shutter = try #require(ProjectFile.ShutterEntry(c.shutter))
        let data = try JSONEncoder().encode(["time": time])
        let back = try JSONDecoder().decode([String: ProjectFile.ClipTimeEntry].self, from: data)
        #expect(back["time"]?.time == c.time)
        let shutterData = try JSONEncoder().encode(["shutter": shutter])
        #expect(try JSONDecoder().decode([String: ProjectFile.ShutterEntry].self, from: shutterData)["shutter"]?.shutter == c.shutter)
        // Defaults write nothing.
        #expect(ProjectFile.ClipTimeEntry(ClipTime()) == nil && ProjectFile.ShutterEntry(ClipShutter()) == nil)
    }
}
