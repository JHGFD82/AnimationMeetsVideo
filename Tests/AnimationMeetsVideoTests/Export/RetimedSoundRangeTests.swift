import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Retimed sound outside the speeds AVFoundation's time-pitch algorithms
/// are documented for, 1/32 to 32 times (code-review-notes.md, F109): a
/// reader handed back nothing for it, and a WAV Mix whose only sound was a
/// clip at 2% was written empty and reported done.
@Suite struct RetimedSoundRangeTests {
    @Test func theRangeIsAThirtySecondToThirtyTwoTimes() {
        let second = CMTime(value: 1, timescale: 1)
        #expect(ClipTime.playsSound(file: second, over: CMTimeMultiply(second, multiplier: 32)))
        #expect(!ClipTime.playsSound(file: second, over: CMTimeMultiply(second, multiplier: 50)))
        #expect(ClipTime.playsSound(file: CMTimeMultiply(second, multiplier: 32), over: second))
        #expect(!ClipTime.playsSound(file: CMTimeMultiply(second, multiplier: 50), over: second))
        #expect(!ClipTime.playsSound(file: second, over: .zero))
    }

    @Test func aMixWhoseOnlySoundIsTooSlowIsRefusedNotWrittenEmpty() async throws {
        let tone = try AudioMixSupport.tone(frequency: 440, amplitude: 0.25, seconds: 2)
        defer { try? FileManager.default.removeItem(at: tone) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: tone, seconds: 2)
        project.editClip(clipID, in: project.rootTimelineID) { $0.time.speed = AnimatedValue(2) }
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-slow-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // As a muted clip's is: there is nothing to hear.
        await #expect(throws: CompositionError.self) {
            try await AudioExport.exportMix(project: project, timelineID: project.rootTimelineID, loudness: .asMixed, to: url)
        }
    }

    @Test func aRampThroughANearStopGoesQuietOverItAndPlaysEitherSide() async throws {
        let tone = try AudioMixSupport.tone(frequency: 440, amplitude: 0.25, seconds: 4)
        defer { try? FileManager.default.removeItem(at: tone) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: tone, seconds: 4)
        let one = CMTime(value: 1, timescale: 1), after = CMTime(value: 102, timescale: 100)
        project.editClip(clipID, in: project.rootTimelineID) { clip in
            // 100%, held down to 1% for 0.02 s of source (two seconds), then 100%.
            clip.time.speed.setAnimated(true, at: .zero)
            clip.time.speed.toggleHold(at: .zero)
            clip.time.speed.set(1, at: one)
            clip.time.speed.toggleHold(at: one)
            clip.time.speed.set(100, at: after)
        }
        let clip = try #require(project.clipAndLayer(clipID, in: project.rootTimelineID)?.clip)
        let slowFrom = clip.timelineTime(forSourceTime: one).seconds, slowTo = clip.timelineTime(forSourceTime: after).seconds
        #expect(abs(slowTo - slowFrom - 2) < 0.01)
        let before = try await AudioMixSupport.loudest(of: project, after: 0.2, before: slowFrom - 0.1)
        let during = try await AudioMixSupport.loudest(of: project, after: slowFrom + 0.2, before: slowTo - 0.2)
        let later = try await AudioMixSupport.loudest(of: project, after: slowTo + 0.2, before: clip.placedDuration.seconds - 0.2)
        #expect(before.x > 0.2 && later.x > 0.2)
        #expect(during.x < 0.001)
    }
}
