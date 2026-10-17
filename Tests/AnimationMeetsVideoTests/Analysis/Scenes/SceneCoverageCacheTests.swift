import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite struct SceneCoverageCacheTests {
    private func track(frames: Int, spikes: [Int]) -> ChangeScoreTrack {
        var scores = [UInt8](repeating: 1, count: frames)
        scores[0] = 0
        for spike in spikes { scores[spike] = 200 }
        return ChangeScoreTrack(timescale: 24, times: (0..<Int64(frames)).map { $0 }, scores: scores)
    }

    private func project() -> (EditingProject, MediaClip) {
        var project = EditingProject.empty
        let clip = MediaClip(name: "A", kind: .video, url: nil, duration: CMTime(value: 480, timescale: 24), frameRate: 24, colorSpace: .rec709, codecName: "T")
        project.clips = [clip]
        return (project, clip)
    }

    @Test func nothingChangedMeansNoNewWork() {
        let (project, clip) = project()
        let scores = track(frames: 480, spikes: [100, 300])
        let cache = SceneCoverageCache()
        let first = cache.coverage(of: clip, in: project, track: scores)
        let second = cache.coverage(of: clip, in: project, track: scores)
        #expect(first?.scenes.count == 3)
        #expect(second?.scenes == first?.scenes)
        #expect(cache.computations == 1)
    }

    @Test func editsSensitivityAndScoresEachMakeItLookAgain() throws {
        var (project, clip) = project()
        let cache = SceneCoverageCache()
        _ = cache.coverage(of: clip, in: project, track: track(frames: 480, spikes: [100]))

        project.editScenes(ofAsset: clip.id) { $0.addCut(at: CMTime(value: 240, timescale: 24)) }
        let edited = try #require(project.clips.first)
        #expect(cache.coverage(of: edited, in: project, track: track(frames: 480, spikes: [100]))?.scenes.count == 3)

        project.defaultSensitivity = 0.1
        _ = cache.coverage(of: edited, in: project, track: track(frames: 480, spikes: [100]))

        #expect(cache.coverage(of: edited, in: project, track: track(frames: 480, spikes: [100, 400]))?.scenes.count == 4)
        #expect(cache.computations == 4)
    }

    @Test func twoHoursOfScoresAreQuickToFindScenesIn() {
        let frames = 2 * 60 * 60 * 24
        let scores = track(frames: frames, spikes: Array(stride(from: 50, to: frames, by: 97)))
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SceneDetector.autoCuts(in: scores, defaultSensitivity: 0.5) }
        #expect(elapsed < .seconds(2))
    }
}
