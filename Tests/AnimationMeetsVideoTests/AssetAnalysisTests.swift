import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite struct AssetAnalysisTests {
    private func makeMovie(frames: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-analysis-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), index < frames / 2 ? 0 : 255, CVPixelBufferGetBytesPerRow(pixels) * 64)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 24))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    private func project(with urls: [URL], kind: MediaKind = .video) -> EditingProject {
        var project = EditingProject.empty
        project.clips = urls.map {
            MediaClip(name: $0.lastPathComponent, kind: kind, url: $0, duration: CMTime(seconds: 1, preferredTimescale: 600),
                      frameRate: 24, colorSpace: .rec709, codecName: "Test")
        }
        return project
    }

    private func waitUntilIdle(_ analysis: AssetAnalysis, expecting count: Int) async throws {
        for _ in 0..<2000 {
            if analysis.progress.isEmpty && analysis.tracks.count + analysis.failures.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("analysis did not finish")
    }

    @Test func analyzesVideoAssetsAndMarksThemUnsaved() async throws {
        let first = try await makeMovie(frames: 24), second = try await makeMovie(frames: 48)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let project = project(with: [first, second])
        let analysis = AssetAnalysis()

        analysis.analyzeMissing(in: project)
        try await waitUntilIdle(analysis, expecting: 2)

        #expect(analysis.tracks[project.clips[0].id]?.frameCount == 24)
        #expect(analysis.tracks[project.clips[1].id]?.frameCount == 48)
        #expect(Set(analysis.unsavedTracks.keys) == Set(project.clips.map(\.id)))

        analysis.markSaved([project.clips[0].id])
        #expect(Set(analysis.unsavedTracks.keys) == [project.clips[1].id])
    }

    @Test func skipsAudioAndAssetsThatAlreadyHaveScores() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        let audio = project(with: [movie], kind: .audio)
        let analysis = AssetAnalysis()
        analysis.analyzeMissing(in: audio)
        #expect(analysis.progress.isEmpty)
        #expect(analysis.tracks.isEmpty)

        let video = project(with: [movie])
        let saved = ChangeScoreTrack(timescale: 600, times: [0], scores: [0])
        analysis.reset(tracks: [video.clips[0].id: saved])
        analysis.analyzeMissing(in: video)
        #expect(analysis.progress.isEmpty)
        #expect(analysis.tracks[video.clips[0].id] == saved)
        #expect(analysis.unsavedTracks.isEmpty)
    }

    @Test func anUnreadableFileIsReportedAndNotRetried() async throws {
        let bad = FileManager.default.temporaryDirectory.appending(path: "amv-bad-\(UUID().uuidString).mov")
        try Data("nope".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        let project = project(with: [bad])
        let analysis = AssetAnalysis()

        analysis.analyzeMissing(in: project)
        try await waitUntilIdle(analysis, expecting: 1)

        #expect(analysis.failures[project.clips[0].id] != nil)
        analysis.analyzeMissing(in: project)
        #expect(analysis.progress.isEmpty)
    }

    @Test func resettingDropsResultsFromTheOldProject() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        let project = project(with: [movie])
        let analysis = AssetAnalysis()

        analysis.analyzeMissing(in: project)
        analysis.reset()
        try await Task.sleep(for: .milliseconds(300))

        #expect(analysis.tracks.isEmpty)
        #expect(analysis.progress.isEmpty)
    }
}
