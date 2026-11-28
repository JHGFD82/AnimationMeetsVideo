import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A backwards clip's one timeline-to-source mapping (code-review-notes.md,
/// F106): its picture, its source-relative keyframes, expressions and
/// Blend all read `shownSourceTime`. Its source range is end-exclusive, so
/// it begins on its last included frame and ends on its first, never on
/// the exclusive out point or the next scene's first frame. They were read
/// a frame apart: keyframes were a frame off their picture after Reverse.
@Suite struct ReversedClipTimingTests {
    private static let frame = CMTime(value: 1, timescale: 24)

    private func frames(_ count: Int) -> CMTime { CMTimeMultiply(Self.frame, multiplier: Int32(count)) }

    /// Frames 24 to 71 of a source, played backwards at `speed` percent.
    private func reversed(speed: Double = 100) -> TimelineClip {
        var clip = TimelineClip(source: .media(UUID()), startOffset: frames(10), trimStart: frames(24), trimEnd: frames(72))
        clip.time.speed = AnimatedValue(-speed)
        return clip
    }

    /// The source frame shown at timeline frame `k` of the clip.
    private func shownFrame(_ clip: TimelineClip, _ k: Int) -> Int {
        let shown = clip.shownSourceTime(atTimelineTime: CMTimeAdd(clip.startOffset, frames(k)), frame: Self.frame)
        return Int((shown.seconds * 24 + 1e-6).rounded(.down))
    }

    @Test func atFullSpeedItRunsFromTheLastIncludedFrameToTheFirst() {
        let clip = reversed()
        let count = Int((clip.placedDuration.seconds * 24).rounded())
        #expect(count == 48)
        #expect((0..<count).map { shownFrame(clip, $0) } == Array((24...71).reversed()))
        // The edges are unchanged: the clip starts where its out point plays.
        #expect(clip.sourceTime(atTimelineTime: clip.startOffset) == frames(72))
        #expect(clip.shownSourceTime(atTimelineTime: clip.startOffset, frame: Self.frame) == frames(71))
    }

    @Test func atHalfSpeedEachFrameShowsTwiceLastFirstAndNeverPastEitherEnd() {
        let clip = reversed(speed: 50)
        let count = Int((clip.placedDuration.seconds * 24).rounded())
        #expect(count == 96)
        let shown = (0..<count).map { shownFrame(clip, $0) }
        #expect(shown == (24...71).reversed().flatMap { [$0, $0] })
        // Forwards it is first frame first, each twice: the mirror.
        var forward = clip
        forward.time.speed = AnimatedValue(50)
        #expect((0..<count).map { shownFrame(forward, $0) } == (24...71).flatMap { [$0, $0] })
    }

    @Test func everyReaderTakesTheMomentThePictureIs() {
        let clip = reversed(speed: 50)
        let stack = ClipStack(clip: clip, center: .zero, shift: .zero, frameDuration: Self.frame)
        let sampling = KeyframeSampling(clip: clip, range: CMTimeRange(start: clip.trimStart, end: clip.trimEnd), frame: Self.frame)
        for (k, time) in sampling.timelineTimes.enumerated() where time < clip.endOffset {
            let shown = clip.shownSourceTime(atTimelineTime: time, frame: Self.frame)
            #expect(stack.sourceTime(atLocal: time) == shown, "frame \(k)")
            #expect(sampling.sources[k] == shown, "frame \(k)")
            // Back again, to the frame it is shown on.
            #expect(CMTimeCompare(stack.timelineTime(forSource: shown), time) == 0, "frame \(k)")
        }
        // The sampled frames are the clip's own, from its first to its last.
        #expect(sampling.timelineTimes.first == clip.startOffset)
    }

    @Test func aKeyframeAppliesFromTheFrameShowingItAfterReverse() {
        // Rotation held at 0, then 90 from source frame 50 on.
        var clip = reversed()
        var rotation = AnimatedValue(0.0)
        rotation.setAnimated(true, at: frames(24))
        rotation.toggleHold(at: frames(24))
        rotation.set(90, at: frames(50))
        let stack = ClipStack(clip: clip, center: .zero, shift: .zero, frameDuration: Self.frame)
        for k in 0..<48 {
            let time = CMTimeAdd(clip.startOffset, frames(k))
            let value = rotation.value(at: stack.sourceTime(atLocal: time))
            // The frame showing 50 and those before it in the source's own
            // time (shown later, going backwards) are 0.
            #expect(value == (shownFrame(clip, k) >= 50 ? 90 : 0), "frame \(k) shows \(shownFrame(clip, k))")
        }
        clip.time.speed = AnimatedValue(100)
        #expect(clip.isRetimed == false)
    }

    // The same through the composition: every timeline frame of a
    // backwards clip of numbered footage shows the frame the mapping names.
    @Test(arguments: [100.0, 50])
    func thePictureIsTheFrameTheMappingNames(speed: Double) async throws {
        var fixture = try DrawingFixture(frame: CGSize(width: ReviewFixtures.width, height: ReviewFixtures.height))
        defer { fixture.cleanUp() }
        let url = fixture.directory.appending(path: "numbered.mov")
        try await ReviewFixtures.writeMovie(to: url, picture: .held(hold: 1), timing: .constant(Self.frame), count: 96, keyFrameInterval: 12)
        let media = MediaClip(
            name: "Numbered", kind: .video, url: url, duration: frames(96), frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let imported = fixture.project.importClip(media, intoTimeline: fixture.timelineID)
        let placed = try #require(imported)
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) {
            $0.trimStart = self.frames(24)
            $0.trimEnd = self.frames(72)
            $0.time.speed = AnimatedValue(-speed)
        }
        let clip = try #require(fixture.project.clipAndLayer(placed.clipID, in: fixture.timelineID)?.clip)
        let composed = try await fixture.build()
        let generator = AVAssetImageGenerator(asset: composed.composition)
        generator.videoComposition = composed.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let count = Int((clip.placedDuration.seconds * 24).rounded())
        for k in 0..<count {
            let time = CMTimeAdd(clip.startOffset, frames(k))
            let number = ReviewFixtures.frameNumber(in: try await generator.image(at: time).image)
            #expect(number == shownFrame(clip, k), "timeline frame \(k)")
        }
    }
}

/// Scene following on a backwards clip (F100 with F106): split on the
/// timeline's frames by the one mapping, and joined again, every frame
/// shows the same picture and reads the same values.
@Suite struct ReversedSceneFollowingTests {
    @Test(arguments: [30.0, 24])
    func splittingAndJoiningKeepEveryFramesPictureAndValues(sourceRate: Double) throws {
        let frame = CMTime(value: 1, timescale: 24)
        let footage = MediaClip(
            name: "Footage", kind: .video, url: nil, duration: CMTime(value: 10, timescale: 1),
            frameRate: sourceRate, colorSpace: .rec709, codecName: "H.264"
        )
        var project = EditingProject.empty
        project.addMedia(footage)
        project.timelines[0].frameRate = 24
        var whole = TimelineClip(source: .media(footage.id), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        whole.time.speed = AnimatedValue(-100)
        // Keyframes on one side of the cut only, so it splits.
        whole.volume.setAnimated(true, at: CMTime(value: 2, timescale: 1))
        whole.volume.set(-12, at: CMTime(value: 3, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [whole])]
        // A cut between two timeline frames at 30 fps, on one at 24.
        let cut = sourceRate == 30 ? CMTime(value: 31, timescale: 30) : CMTime(value: 25, timescale: 24)

        let result = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.addCut(at: cut) }
        #expect(result.split.count == 1)
        let pieces = project.timelines[0].layers[0].clips.sorted { $0.startOffset < $1.startOffset }
        #expect(pieces.count == 2)
        guard pieces.count == 2 else { return }
        // On the frames, and whole frames, so reopening keeps them.
        #expect(project.timelines[0].frameAligned(pieces[1].startOffset, .nearest) == pieces[1].startOffset)
        var reopened = project
        reopened.alignClipLengthsToFrames()
        #expect(reopened.timelines[0].layers[0].clips.sorted { $0.startOffset < $1.startOffset } == pieces)

        let count = Int((whole.placedDuration.seconds * 24).rounded())
        for k in 0..<count {
            let time = CMTimeMultiply(frame, multiplier: Int32(k))
            let piece = pieces[time < pieces[1].startOffset ? 0 : 1]
            let before = whole.shownSourceTime(atTimelineTime: time, frame: frame)
            let after = piece.shownSourceTime(atTimelineTime: time, frame: frame)
            #expect(CMTimeCompare(before, after) == 0, "frame \(k): picture")
            #expect(whole.volume.value(at: before) == piece.volume.value(at: after), "frame \(k): value")
            // Each half shows only its own scene: backwards, the later
            // scene first.
            #expect((after >= cut) == (piece.id == pieces[0].id), "frame \(k): scene")
        }

        let merged = project.editScenesFollowingClips(ofAsset: footage.id, track: nil) { $0.removeCut(SceneCut(time: cut, origin: .manual)) }
        #expect(merged.joined == 1)
        let back = project.timelines[0].layers[0].clips
        #expect(back.count == 1)
        if let first = back.first {
            var expected = whole
            expected.id = first.id
            #expect(first == expected)
        }
    }
}
