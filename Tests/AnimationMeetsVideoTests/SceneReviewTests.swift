import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

// A review of scene detection and splitting, as tests. Tests that pin down
// behavior that is correct are ordinary tests. Tests that pin down a defect
// are wrapped in `withKnownIssue`: they assert what should happen, and the
// suite fails when the defect is fixed, as a reminder to remove the wrapper.
// Tests named "…Today" record current behavior that may be a limitation by
// design; they are not endorsements of it.

private func seconds(_ time: CMTime) -> Double { time.seconds }

private func cutTimes(_ track: ChangeScoreTrack, sensitivity: Double = SceneDetector.balancedSensitivity) -> [Double] {
    SceneDetector.autoCuts(in: track, defaultSensitivity: sensitivity).map(seconds)
}

private func clip(_ frame: Int) -> CMTime { CMTime(value: Int64(frame), timescale: 24) }

// MARK: - Timestamps (real decoding)

@Suite(.serialized) struct SceneTimestampTests {
    private let step = SceneFixture.gray

    private func twoShots(_ cut: Int) -> @Sendable (Int) -> @Sendable (Int, Int) -> (UInt8, UInt8, UInt8) {
        { $0 < cut ? SceneFixture.gray(30) : SceneFixture.gray(220) }
    }

    private func expectAscending(_ track: ChangeScoreTrack) {
        #expect(zip(track.times, track.times.dropFirst()).allSatisfy { $0 < $1 }, "frame times must strictly increase")
    }

    @Test func aHardCutIsAtTheFirstFrameOfTheNewShot() async throws {
        let (track, duration) = try await SceneFixture.score(SceneFixture.constantRate(count: 48, color: twoShots(24)))
        #expect(cutTimes(track) == [1.0])
        #expect(track.scores[24] > 120)
        #expect(abs(duration.seconds - 2.0) < 1e-6)
        expectAscending(track)
    }

    @Test func variableFrameRateCutsLandOnTheRealPresentationTime() async throws {
        // 24 fps for a second, then 12 fps; the cut is the first slow frame.
        var frames: [FixtureFrame] = []
        var time = CMTime.zero
        for index in 0..<36 {
            frames.append(FixtureFrame(pts: time, color: index < 24 ? SceneFixture.gray(30) : SceneFixture.gray(220)))
            time = CMTimeAdd(time, index < 24 ? CMTime(value: 1, timescale: 24) : CMTime(value: 1, timescale: 12))
        }
        let (track, _) = try await SceneFixture.score(frames)
        let cuts = cutTimes(track)
        #expect(cuts.count == 1)
        #expect(abs(cuts[0] - 1.0) <= 1.0 / 600)
        // After the cut, frames are 1/12 s apart, not 1/24.
        // Split up: Swift 6.3 can't type-check it as one expression in time.
        let gap: Double = Double(track.times[26] - track.times[25]) / Double(track.timescale)
        #expect(abs(gap - 1.0 / 12) <= 1.0 / 600)
        expectAscending(track)
    }

    @Test func droppedFramesMoveNothing() async throws {
        // Frames 22 and 23 never arrive; the cut is still at its real time.
        let frames = SceneFixture.constantRate(count: 48, color: twoShots(24)).enumerated()
            .filter { ![22, 23].contains($0.offset) }.map(\.element)
        let (track, _) = try await SceneFixture.score(frames)
        #expect(track.frameCount == 46)
        #expect(cutTimes(track) == [1.0])
        expectAscending(track)
    }

    @Test func ntscTimesAreExactWhenTheFileKeepsItsOwnTimescale() async throws {
        let frames = (0..<60).map { index in
            FixtureFrame(pts: CMTime(value: Int64(index) * 1001, timescale: 30000), color: index < 30 ? SceneFixture.gray(30) : SceneFixture.gray(220))
        }
        let (track, _) = try await SceneFixture.score(frames, mediaTimeScale: 30000)
        #expect(track.timescale == 30000)
        let cuts = SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5)
        #expect(cuts == [CMTime(value: 30030, timescale: 30000)])
    }

    @Test func aCoarseFileTimescaleRoundsByLessThanHalfATick() async throws {
        // Written at 600 units a second, 30000/1001 frames can't be exact.
        let frames = (0..<60).map { index in
            FixtureFrame(pts: CMTime(value: Int64(index) * 1001, timescale: 30000), color: index < 30 ? SceneFixture.gray(30) : SceneFixture.gray(220))
        }
        let (track, _) = try await SceneFixture.score(frames, mediaTimeScale: 600)
        let cut = try #require(cutTimes(track).first)
        #expect(abs(cut - 1.001) <= 1.0 / 1200 + 1e-9)
    }

    @Test func aFileThatStartsLateKeepsTimesOnTheAssetTimeline() async throws {
        // The first picture is a second into the movie (an empty edit comes first).
        let frames = SceneFixture.constantRate(count: 48, start: CMTime(value: 1, timescale: 1), color: twoShots(24))
        let (track, duration) = try await SceneFixture.score(frames)
        #expect(abs(duration.seconds - 3.0) < 1e-6)
        // The cut is at 2 s of the movie, where the asset's duration puts it.
        #expect(cutTimes(track).contains { abs($0 - 2.0) < 1e-6 })
        // And the last picture ends where the asset does.
        let last = Double(track.times.last!) / Double(track.timescale)
        #expect(abs(last + 1.0 / 24 - duration.seconds) < 1e-3)
        expectAscending(track)
    }

    @Test func scenesFromARealFileCoverTheAssetWithoutGapsOrOverlaps() async throws {
        let (track, duration) = try await SceneFixture.score(SceneFixture.constantRate(count: 96) { index in
            index < 24 ? SceneFixture.gray(30) : (index < 60 ? SceneFixture.gray(220) : SceneFixture.gray(110))
        })
        let cuts = SceneDetector.cuts(in: track, defaultSensitivity: 0.5, edits: SceneEdits())
        let scenes = SceneDetector.scenes(from: cuts, duration: duration)
        #expect(scenes.count == 3)
        #expect(scenes.first?.start == .zero)
        #expect(scenes.last?.end == duration)
        for (a, b) in zip(scenes, scenes.dropFirst()) { #expect(a.end == b.start) }
        #expect(scenes.allSatisfy { $0.duration > .zero })
    }
}

// MARK: - Detection quality (real decoding)

@Suite(.serialized) struct SceneDetectionQualityTests {
    @Test func aSlowFadeIsNotCutAtTheDefaultSensitivity() async throws {
        let (track, _) = try await SceneFixture.score(SceneFixture.constantRate(count: 60) {
            SceneFixture.fade(at: $0, from: 30, to: 220, start: 24, length: 12)
        })
        #expect(cutTimes(track).isEmpty)
    }

    @Test func aCrossDissolveIsNotCutAtTheDefaultSensitivity() async throws {
        let (track, _) = try await SceneFixture.score(SceneFixture.constantRate(count: 60) {
            SceneFixture.dissolve(at: $0, from: 24, length: 12)
        })
        #expect(cutTimes(track).isEmpty)
    }

    @Test func aFadeIsSplitInTheMiddleAtHighSensitivity() async throws {
        // The documentation says a slow dissolve is not split down the middle.
        // At a high sensitivity a fade is: its per-frame change is steady and
        // slightly over the threshold, and one frame of the steady stretch
        // reads as a peak.
        let (track, _) = try await SceneFixture.score(SceneFixture.constantRate(count: 60) {
            SceneFixture.fade(at: $0, from: 30, to: 220, start: 24, length: 12)
        })
        withKnownIssue("a fade is split mid-way at sensitivity 0.9") {
            #expect(cutTimes(track, sensitivity: 0.9).isEmpty)
        }
    }

    @Test func aSingleFlashFrameCausesAFalseCut() async throws {
        let (track, _) = try await SceneFixture.score(SceneFixture.constantRate(count: 60) {
            $0 == 30 ? SceneFixture.gray(255) : SceneFixture.stripes(shift: 0)
        })
        // Into the flash and out of it both score high; the cut lands on the
        // frame after the flash, though the shot did not change.
        withKnownIssue("one white frame is reported as a scene change") {
            #expect(cutTimes(track).isEmpty)
        }
    }

    @Test func sustainedCameraMotionGetsAPhantomCutOnTheLastFrame() async throws {
        let (track, duration) = try await SceneFixture.score(SceneFixture.constantRate(count: 48) {
            SceneFixture.stripes(shift: $0 * 12)
        })
        // Every frame changes by the same amount. A plateau has no peak, except
        // that the last frame counts as one, so the track ends in a one-frame scene.
        withKnownIssue("steady motion over the threshold is cut at the final frame") {
            #expect(cutTimes(track).isEmpty)
        }
        #expect(duration.seconds > 0)
    }

    @Test func aThreeFrameShotCollapsesToOneCutToday() async throws {
        // Designed (minimum scene length 0.4 s): cuts 0.125 s apart merge and
        // the stronger wins; on a tie the earlier stays. The short shot then
        // belongs to the shot after it.
        let (track, _) = try await SceneFixture.score(SceneFixture.constantRate(count: 60) {
            (30..<33).contains($0) ? SceneFixture.gray(220) : SceneFixture.gray(30)
        })
        #expect(cutTimes(track) == [1.25])
    }

    @Test func aChangeOfColorAtEqualBrightnessIsMissedToday() async throws {
        // Scoring compares brightness only.
        let (track, _) = try await SceneFixture.score(SceneFixture.constantRate(count: 48) {
            $0 < 24 ? SceneFixture.solid(150, 0, 0) : SceneFixture.solid(0, 76, 0)
        })
        #expect(cutTimes(track, sensitivity: 0.5).isEmpty)
        #expect(Double(track.scores[24]) / 255 < SceneDetector.threshold(forSensitivity: 0.5))
    }
}

// MARK: - Boundary validity (no decoding)

@Suite struct SceneBoundaryTests {
    /// A deterministic pseudo-random sequence.
    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func randomTrack(_ random: inout Generator) -> ChangeScoreTrack {
        let timescale: Int32 = [24, 600, 30000][random.next(3)]
        let step = Int64(timescale) / 24
        let count = 3 + random.next(400)
        var times: [Int64] = []
        var scores: [UInt8] = []
        var time: Int64 = Int64(random.next(5)) * step
        for index in 0..<count {
            times.append(time)
            // Mostly quiet, some plateaus and spikes.
            let roll = random.next(20)
            scores.append(index == 0 ? 0 : roll == 0 ? UInt8(100 + random.next(155)) : roll == 1 ? UInt8(40 + random.next(60)) : UInt8(random.next(12)))
            time += step * Int64(1 + (random.next(8) == 0 ? random.next(3) : 0))
        }
        return ChangeScoreTrack(timescale: timescale, times: times, scores: scores)
    }

    @Test func detectedCutsAreSortedUniqueAndInsideTheTrack() {
        var random = Generator(state: 7)
        for _ in 0..<400 {
            let track = randomTrack(&random)
            let sensitivity = Double(random.next(101)) / 100
            let cuts = SceneDetector.autoCuts(in: track, defaultSensitivity: sensitivity)
            #expect(zip(cuts, cuts.dropFirst()).allSatisfy { CMTimeCompare($0, $1) < 0 })
            #expect(cuts.allSatisfy { CMTimeCompare($0, track.time(at: 0)) > 0 && CMTimeCompare($0, track.time(at: track.frameCount - 1)) <= 0 })
            // Every cut is a real frame time.
            let frames = Set(track.times.map { track.time(at: track.times.firstIndex(of: $0)!).seconds })
            #expect(cuts.allSatisfy { frames.contains($0.seconds) })
        }
    }

    @Test func cutsAreNeverCloserThanTheMinimumSceneLength() {
        var random = Generator(state: 11)
        for _ in 0..<400 {
            let track = randomTrack(&random)
            let cuts = SceneDetector.autoCuts(in: track, defaultSensitivity: Double(random.next(101)) / 100)
            for (a, b) in zip(cuts, cuts.dropFirst()) {
                #expect(b.seconds - a.seconds >= SceneDetector.minimumSceneSeconds - 1e-9)
            }
        }
    }

    @Test func scenesAlwaysCoverTheAssetWithPositiveLengths() {
        var random = Generator(state: 13)
        for _ in 0..<400 {
            let track = randomTrack(&random)
            let duration = CMTime(seconds: Double(random.next(2000)) / 100 + 0.1, preferredTimescale: 600)
            var edits = SceneEdits()
            for _ in 0..<random.next(6) {
                edits.addCut(at: CMTime(seconds: Double(random.next(2200)) / 100, preferredTimescale: [24, 600, 30000][random.next(3)]))
            }
            let cuts = SceneDetector.cuts(in: track, defaultSensitivity: Double(random.next(101)) / 100, edits: edits)
            let scenes = SceneDetector.scenes(from: cuts, duration: duration)
            #expect(scenes.first?.start == .zero)
            #expect(scenes.last?.end == duration)
            #expect(scenes.allSatisfy { CMTimeCompare($0.end, $0.start) > 0 })
            for (a, b) in zip(scenes, scenes.dropFirst()) { #expect(a.end == b.start) }
        }
    }

    @Test func theSameCutInTwoTimescalesIsOneCut() {
        var edits = SceneEdits()
        edits.addCut(at: CMTime(value: 24, timescale: 24))
        edits.addCut(at: CMTime(value: 600, timescale: 600))
        edits.addCut(at: CMTime(value: 30000, timescale: 30000))
        let scenes = SceneDetector.scenes(from: SceneDetector.cuts(in: nil, defaultSensitivity: 0.5, edits: edits), duration: clip(48))
        #expect(scenes.count == 2)
    }

    @Test func shortScenesAtTheEndsOfAnAssetAreKept() {
        // Policy: the 0.4 s minimum applies between cuts, not at the two ends
        // of the asset. A genuine boundary near an end is not suppressed and
        // no footage is dropped to enforce a length.
        let times = (0..<48).map(Int64.init)
        var scores = [UInt8](repeating: 2, count: 48)
        scores[0] = 0
        scores[3] = 200   // 0.125 s into the asset
        scores[46] = 200  // 0.083 s before its end
        let track = ChangeScoreTrack(timescale: 24, times: times, scores: scores)
        let scenes = SceneDetector.scenes(
            from: SceneDetector.cuts(in: track, defaultSensitivity: 0.5, edits: SceneEdits()), duration: clip(48)
        )
        #expect(scenes.count == 3)
        #expect(scenes.first!.duration.seconds < SceneDetector.minimumSceneSeconds)
        #expect(scenes.last!.duration.seconds < SceneDetector.minimumSceneSeconds)
        // Nothing is dropped: the scenes still cover the whole asset.
        #expect(scenes.first?.start == .zero && scenes.last?.end == clip(48))
        for (a, b) in zip(scenes, scenes.dropFirst()) { #expect(a.end == b.start) }
    }

    @Test func aConstantPlateauIsCutOnlyAtTheEndOfTheTrack() {
        let times = (0..<100).map(Int64.init)
        let scores = (0..<100).map { $0 == 0 ? UInt8(0) : UInt8(60) }
        let track = ChangeScoreTrack(timescale: 24, times: times, scores: scores)
        withKnownIssue("a plateau in the middle has no peak but one at the end does") {
            #expect(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5).isEmpty)
        }
    }

    @Test func chainedMergesKeepOnlyTheStrongestOfThreeCloseCutsToday() {
        // Cuts at 0.5 s, 0.8 s and 1.1 s (0.3 s apart). The middle one is
        // strongest, replaces the first, and then rejects the third even
        // though the third is 0.6 s from the first. Greedy, by design of the
        // single pass; recorded so a change to it is deliberate.
        var scores = [UInt8](repeating: 2, count: 48)
        scores[12] = 150; scores[19] = 200; scores[26] = 150
        let track = ChangeScoreTrack(timescale: 24, times: (0..<48).map(Int64.init), scores: scores)
        // 12/24 = 0.5, 19/24 ≈ 0.79, 26/24 ≈ 1.08
        #expect(SceneDetector.autoCuts(in: track, defaultSensitivity: 0.5).map { $0.value } == [19])
    }
}

// MARK: - Timeline mapping and split behavior

@MainActor
@Suite struct SceneMappingTests {
    private func project(duration: Int = 240, offset: CMTime = .zero) -> (EditingProject, UUID) {
        var project = EditingProject.empty
        var asset = MediaClip(
            name: "Shot", kind: .video, url: nil, duration: clip(duration),
            frameRate: 24, colorSpace: .rec709, codecName: "Test"
        )
        asset.alignmentOffset = offset
        project.clips = [asset]
        return (project, asset.id)
    }

    private func spikes(_ frames: [Int: UInt8], count: Int = 240) -> ChangeScoreTrack {
        ChangeScoreTrack(
            timescale: 24, times: (0..<count).map(Int64.init),
            scores: (0..<count).map { $0 == 0 ? 0 : (frames[$0] ?? 2) }
        )
    }

    @Test func aReplacementAlignedByTwoSecondsGetsItsCutsInOriginalTime() {
        // Original time t is at t + 2 s in the file. The scores describe the
        // file (a cut at 5 s of the file), but scenes and trims are in
        // original time, so the cut is at 3 s.
        let (project, id) = project(offset: CMTime(value: 2, timescale: 1))
        let scenes = project.scenes(ofAsset: id, track: spikes([120: 200]))
        #expect(scenes.map(\.start).contains(clip(72)))
    }

    @Test func aSceneAddedFromAReplacementStartsWhereTheCutIsInTheFile() {
        var (project, id) = project(offset: CMTime(value: 2, timescale: 1))
        let scenes = project.scenes(ofAsset: id, track: spikes([120: 200]))
        let second = scenes[1]
        project.addScenes([second], ofAsset: id, intoTimeline: project.rootTimelineID)
        let placed = project.timelines[0].layers[0].clips[0]
        // The clip reads the file at trimStart + offset. It is the cut, 5 s.
        #expect(abs(project.clips[0].fileTime(forSourceTime: placed.trimStart).seconds - 5.0) < 1.0 / 24)
    }

    @Test func scenesBecomeClipsThatMeetOnATimelineWithAnotherFrameRate() throws {
        var (project, id) = project(duration: 100)
        project.timelines[0].frameRate = 30
        let scenes = SceneDetector.scenes(
            from: [SceneCut(time: clip(25), origin: .auto), SceneCut(time: clip(51), origin: .auto), SceneCut(time: clip(77), origin: .auto)],
            duration: clip(100)
        )
        let added = project.addScenes(scenes, ofAsset: id, intoTimeline: project.rootTimelineID)
        let result = try #require(added)
        let clips = try #require(project.timelines[0].layers.first?.clips)
        #expect(clips.map(\.id) == result.clipIDs)
        let frame = project.timelines[0].frameDuration.seconds
        for (a, b) in zip(clips, clips.dropFirst()) {
            // On the timeline each clip starts where the last ends.
            #expect(abs(b.startOffset.seconds - a.endOffset.seconds) < Timeline.abutmentTolerance.seconds)
            // In the footage nothing is repeated, and less than one timeline
            // frame at most is left out where a scene's end was trimmed back
            // to a whole frame.
            let skipped = (b.trimStart - a.trimEnd).seconds
            #expect(skipped >= -1e-9)
            #expect(skipped < frame + 1e-9)
            // Every clip is a whole number of timeline frames.
            let frames = a.placedDuration.seconds / frame
            #expect(abs(frames - frames.rounded()) < 1e-6)
        }
        #expect(clips.first?.trimStart == .zero)
    }

    @Test func splittingAtTheSameFrameTwiceChangesNothingTheSecondTime() throws {
        var (project, id) = project(duration: 240)
        let timelineID = project.rootTimelineID
        project.addScenes([SceneRange(start: .zero, end: clip(240), origin: .auto)], ofAsset: id, intoTimeline: timelineID)
        let layer = project.timelines[0].layers[0]
        let whole = layer.clips[0]
        let at = CMTime(value: 5, timescale: 1)

        project.split(whole.id, in: timelineID, layer: layer.id, atTimelineTime: at)
        let pieces = project.timelines[0].layers[0].clips
        #expect(pieces.count == 2)
        // No gap and no overlap, and the footage is continuous across the cut.
        #expect(pieces[0].endOffset == pieces[1].startOffset)
        #expect(pieces[0].trimEnd == pieces[1].trimStart)
        #expect(pieces[0].trimStart == whole.trimStart && pieces[1].trimEnd == whole.trimEnd)
        #expect(pieces[0].transitionOut == nil && pieces[1].transitionIn == nil)

        // The playhead is now on an edge, not inside either piece.
        project.split(pieces[0].id, in: timelineID, layer: layer.id, atTimelineTime: at)
        project.split(pieces[1].id, in: timelineID, layer: layer.id, atTimelineTime: at)
        #expect(project.timelines[0].layers[0].clips.map(\.id) == pieces.map(\.id))
    }

    @Test func aSplitClipKeepsItsAudioWithItsPicture() throws {
        var (project, id) = project(duration: 240)
        project.clips[0].hasAudio = true
        let timelineID = project.rootTimelineID
        project.addScenes([SceneRange(start: .zero, end: clip(240), origin: .auto)], ofAsset: id, intoTimeline: timelineID)
        let layer = project.timelines[0].layers[0]
        project.split(layer.clips[0].id, in: timelineID, layer: layer.id, atTimelineTime: CMTime(value: 4, timescale: 1))

        // Picture and sound are one clip, so each half carries both streams
        // over the same stretch of footage.
        let pieces = project.timelines[0].layers[0].clips
        #expect(pieces.allSatisfy { $0.streams == .videoAndAudio })
        #expect(pieces[0].trimEnd == pieces[1].trimStart)
    }

    @Test func addingScenesAndSplittingEachUndoAndRedoAsOneStep() throws {
        let (initial, id) = project(duration: 240)
        let history = ProjectHistory(project: initial)
        let undoManager = UndoManager()
        history.undoManager = undoManager
        var current = initial
        history.restore = { current = $0 }
        var clock = Date(timeIntervalSince1970: 1_000)

        // The undo manager groups steps per run loop event, so let it turn
        // between two user actions, as the app's own history tests do.
        func turnRunLoop() {
            RunLoop.current.add(Timer(timeInterval: 0, repeats: false) { _ in }, forMode: .default)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        func edit(_ change: (inout EditingProject) -> Void) {
            clock = clock.addingTimeInterval(10)
            change(&current)
            history.projectDidChange(current, now: clock)
            turnRunLoop()
        }
        func undo() {
            undoManager.undo()
            turnRunLoop()
            history.projectDidChange(current, now: clock)
        }
        func redo() {
            undoManager.redo()
            turnRunLoop()
            history.projectDidChange(current, now: clock)
        }

        let timelineID = current.rootTimelineID
        let scenes = [SceneRange(start: .zero, end: clip(100), origin: .auto), SceneRange(start: clip(100), end: clip(240), origin: .auto)]
        edit { _ = $0.addScenes(scenes, ofAsset: id, intoTimeline: timelineID) }
        let afterAdd = current
        #expect(afterAdd.timelines[0].layers[0].clips.count == 2)

        let layer = current.timelines[0].layers[0]
        edit { $0.split(layer.clips[0].id, in: timelineID, layer: layer.id, atTimelineTime: CMTime(value: 2, timescale: 1)) }
        let afterSplit = current
        #expect(afterSplit.timelines[0].layers[0].clips.count == 3)

        undo()
        #expect(current == afterAdd)
        undo()
        #expect(current == initial)
        redo()
        #expect(current == afterAdd)
        redo()
        #expect(current == afterSplit)
    }
}
