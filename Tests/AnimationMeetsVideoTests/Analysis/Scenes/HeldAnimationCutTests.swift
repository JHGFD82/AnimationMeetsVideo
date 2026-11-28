import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Anime's held drawings and impact flashes against scene detection
/// (code-review-notes.md, F112): animation on twos or threes changes only
/// every second or third frame, and each new drawing rose to a cut against
/// a usual change of half a drawing's or none; a two-frame white flash cut
/// where a one-frame one didn't.
@Suite struct HeldAnimationCutTests {
    private let balanced = SceneDetector.balancedSensitivity

    /// Scores at 24 fps from `score(i)`, with skip scores and long skip
    /// scores given as functions of the frame too.
    private func track(
        count: Int, score: (Int) -> UInt8, skip: (Int) -> UInt8 = { _ in 0 }, longSkip: (Int) -> UInt8 = { _ in 0 }
    ) -> ChangeScoreTrack {
        let scores = (0..<count).map { $0 == 0 ? 0 : score($0) }
        let skips = (0..<count).map { $0 < 2 ? 0 : skip($0) }
        let longSkips = (0..<count).map { $0 < 3 ? 0 : longSkip($0) }
        return ChangeScoreTrack(
            timescale: 24, times: (0..<count).map(Int64.init), scores: scores, skipScores: skips, longSkipScores: longSkips
        )
    }

    @Test(arguments: [2, 3])
    func drawingsHeldOnTwosOrThreesAreOneShot(hold: Int) {
        // A strong change at each new drawing, none between.
        let held = track(count: 240, score: { $0 % hold == 0 ? 90 : 1 }, skip: { _ in 90 })
        #expect(SceneDetector.autoCuts(in: held, defaultSensitivity: balanced).isEmpty, "\(SceneDetector.autoCuts(in: held, defaultSensitivity: balanced).map(\.value))")
        // A cut in it, well over a drawing's change, is still one.
        let cut = track(count: 240, score: { $0 == 120 ? 230 : $0 % hold == 0 ? 90 : 1 }, skip: { _ in 90 })
        #expect(SceneDetector.autoCuts(in: cut, defaultSensitivity: balanced) == [CMTime(value: 120, timescale: 24)])
    }

    @Test func aTwoFrameFlashIsNoCutButATwoFrameShotIs() {
        // A still shot, white over frames 60 and 61, then the shot again:
        // into the white and out of it change, across both frames not.
        let scores: (Int) -> UInt8 = { $0 == 60 || $0 == 62 ? 200 : 0 }
        let skips: (Int) -> UInt8 = { $0 == 61 || $0 == 62 ? 200 : 0 }
        let flash = track(count: 120, score: scores, skip: skips, longSkip: { _ in 0 })
        #expect(SceneDetector.autoCuts(in: flash, defaultSensitivity: balanced).isEmpty)
        // Two frames of something else, then a new shot: a cut.
        let shot = track(count: 120, score: scores, skip: skips, longSkip: { $0 >= 62 && $0 <= 64 ? 200 : 0 })
        #expect(!SceneDetector.autoCuts(in: shot, defaultSensitivity: balanced).isEmpty)
    }

    @Test func aStillShotWithOneBlipStillCutsAsBefore() {
        // One moving neighbor isn't motion: the cut beside it rises from none.
        let blip = track(count: 120, score: { $0 == 58 ? 30 : $0 == 60 ? 60 : 0 }, skip: { $0 == 60 || $0 == 61 ? 60 : 0 }, longSkip: { $0 >= 60 ? 60 : 0 })
        #expect(SceneDetector.autoCuts(in: blip, defaultSensitivity: balanced) == [CMTime(value: 60, timescale: 24)])
    }

    // The same through the scorer, on footage made for the review.
    @Test(arguments: [
        ReviewFixtures.Picture.held(hold: 2), .held(hold: 3), .flashes(every: 36, hold: 2, length: 2),
    ])
    func generatedHeldAnimationAndFlashesHaveNoCuts(picture: ReviewFixtures.Picture) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-held-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ReviewFixtures.writeMovie(to: url, picture: picture, timing: .constant(CMTime(value: 1, timescale: 24)), count: 96, keyFrameInterval: 24)
        let scores = try await FrameScorer.score(url: url)
        #expect(scores.longSkipScores != nil)
        // The fixture opens on its first flash, with no shot before it to
        // come back to, so the opening frames are left out.
        let cuts = SceneDetector.autoCuts(in: scores, defaultSensitivity: balanced).filter { $0.seconds > 0.5 }
        #expect(cuts.isEmpty, "\(picture): cuts at \(cuts.map(\.seconds))")
    }
}
