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

@Suite struct SpeedRampCostTests {
    private func second(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func rampedClip() -> TimelineClip {
        var clip = TimelineClip(source: .media(UUID()), startOffset: second(5), trimStart: .zero, trimEnd: second(120))
        clip.time.speed.setAnimated(true, at: .zero)
        clip.time.speed.set(50, at: second(10))
        clip.time.speed.set(400, at: second(60))
        return clip
    }

    @Test func aLinearRampTakesAsLongAsItsIntegralSays() {
        var clip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: second(10))
        clip.time.speed.setAnimated(true, at: .zero)
        clip.time.speed.set(50, at: second(10))
        // Speed 100 - 5t: the integral of 100 / speed is 20 ln 2.
        #expect(abs(clip.placedDuration.seconds - 20 * log(2.0)) < 1e-4)
    }

    @Test func theTwoMappingsUndoEachOtherAcrossKeyframes() {
        let clip = rampedClip()
        for source in [3.0, 10.0, 25.5, 60.0, 90.0] {
            let there = clip.timelineTime(forSourceTime: second(source))
            #expect(abs(clip.sourceTime(atTimelineTime: there).seconds - source) < 1e-3)
        }
    }

    @Test func askingWhereAndHowLongIsCheapEnoughForEveryFrame() {
        let clip = rampedClip()
        let start = ContinuousClock.now
        for index in 0..<200 {
            _ = clip.placedDuration
            _ = clip.sourceTime(atTimelineTime: second(5 + Double(index) * 0.3))
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(500))
    }

    // MARK: Inverting a speed ramp

    /// The bisection the mapping used before: the reference for the new one.
    private func bisectedSource(_ clip: TimelineClip, atElapsed target: Double) -> Double {
        let integral = SpeedIntegral.of(clip.time.speed)
        let anchor = clip.trimStart.seconds
        let base = integral.at(anchor)
        let fastest = ClipTime.speedRange.upperBound / 100
        var low = target >= 0 ? anchor : anchor + target * fastest - 1e-6
        var high = target >= 0 ? anchor + target * fastest + 1e-6 : anchor
        for _ in 0..<44 {
            let middle = (low + high) / 2
            if integral.at(middle) - base < target { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    private func easedClip(speeds: [(Double, Double)], eased: Bool = true) -> TimelineClip {
        var clip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: second(speeds[0].0), trimEnd: second(speeds[speeds.count - 1].0))
        clip.time.speed.setAnimated(true, at: second(speeds[0].0))
        for (time, value) in speeds { clip.time.speed.set(value, at: second(time)) }
        if eased {
            for (time, _) in speeds { clip.time.speed.setEase(at: second(time), in: KeyframeEase(influence: 0.7, speed: 0), out: KeyframeEase(influence: 0.7, speed: 0)) }
        }
        return clip
    }

    /// Checks that the mapping agrees with the integral it inverts, to the
    /// tolerance, at `elapsed` seconds of timeline time.
    private func expectInverts(_ clip: TimelineClip, elapsed: [Double]) {
        let integral = SpeedIntegral.of(clip.time.speed)
        let base = integral.at(clip.trimStart.seconds)
        for t in elapsed {
            let at = CMTime(seconds: t, preferredTimescale: 240_000)
            let source = clip.sourceTime(atTimelineTime: at).seconds
            // The source time is cut to 1 / 240000 (under that, since the cut
            // truncates), which the rate (at most 100) turns into timeline
            // time, plus the Newton tolerance.
            #expect(abs(integral.at(source) - base - t) <= 100 / 240_000 + SpeedIntegral.timeTolerance, "elapsed \(t)")
            #expect(abs(source - bisectedSource(clip, atElapsed: at.seconds)) < 2e-5, "elapsed \(t)")
        }
    }

    @Test func invertingANonlinearRampMatchesTheIntegral() {
        let clip = easedClip(speeds: [(0, 100), (10, 30), (25, 800), (40, 100)])
        expectInverts(clip, elapsed: stride(from: -3.0, through: 60, by: 0.37).map { $0 })
    }

    @Test func invertingNearTheSlowestSpeed() {
        // 1% is the slowest: a hundred seconds of timeline per source second.
        let clip = easedClip(speeds: [(0, 1), (2, 1), (4, 5), (6, 1)])
        expectInverts(clip, elapsed: [0, 0.001, 0.5, 37, 100, 150, 199.9, 260, 400, 800])
    }

    @Test func invertingAtTheFastestSpeed() {
        let clip = easedClip(speeds: [(0, 10_000), (1, 10_000), (3, 100)])
        expectInverts(clip, elapsed: [0, 0.0001, 0.01, 0.0199, 0.5, 2, 3])
    }

    @Test func invertingExactlyAtKeyframesGivesTheKeyframe() {
        let clip = easedClip(speeds: [(0, 100), (10, 30), (25, 800), (40, 100)])
        let integral = SpeedIntegral.of(clip.time.speed)
        for keyframe in [0.0, 10, 25, 40] {
            let there = clip.timelineTime(forSourceTime: second(keyframe))
            // The error of source time to timeline time and back, in source
            // seconds, with v the speed there as a multiple of 1. Both ways go
            // through the same integral, so its own error (a few
            // `pieceTolerance`) cancels, and what is left is:
            //  - `timelineLength` cuts to the 1 / 240000 grid (CMTime(seconds:)
            //    truncates): under 1 / 240000 of timeline time, which the
            //    inverse scales by v;
            //  - the inverse lands within `timeTolerance` of the timeline
            //    time on the integral's own curve, scaled by v;
            //  - the final cut of the source time: under 1 / 240000.
            let v = clip.speed(atSource: second(keyframe)) / 100
            let bound = (v + 1) / 240_000 + SpeedIntegral.timeTolerance * v
            #expect(abs(clip.sourceTime(atTimelineTime: there).seconds - keyframe) <= bound, "keyframe \(keyframe)")
            #expect(abs(integral.source(atIntegral: integral.at(keyframe)) - keyframe) < 1e-7)
        }
    }

    @Test func invertingBeyondTheKeyframesFollowsTheHeldSpeed() {
        let clip = easedClip(speeds: [(5, 50), (15, 200)], eased: false)
        let integral = SpeedIntegral.of(clip.time.speed)
        #expect(abs(integral.source(atIntegral: integral.at(30)) - 30) < 1e-7)
        #expect(abs(integral.source(atIntegral: integral.at(-4)) - -4) < 1e-7)
    }

    @Test func invertingARampIsFasterThanBisecting() {
        let clip = easedClip(speeds: [(0, 100), (10, 30), (25, 800), (40, 100)])
        let times = (0..<400).map { Double($0) * 0.1 }
        func measure(_ body: (Double) -> Double) -> Duration {
            let start = ContinuousClock.now
            var sum = 0.0
            for _ in 0..<5 { for t in times { sum += body(t) } }
            #expect(sum.isFinite)
            return ContinuousClock.now - start
        }
        _ = clip.sourceTime(atTimelineTime: second(1))
        let newer = measure { clip.sourceTime(atTimelineTime: CMTime(seconds: $0, preferredTimescale: 240_000)).seconds }
        let older = measure { bisectedSource(clip, atElapsed: $0) }
        print("speed-ramp inverse: new \(newer), bisection \(older)")
        #expect(newer < older)
    }
}
