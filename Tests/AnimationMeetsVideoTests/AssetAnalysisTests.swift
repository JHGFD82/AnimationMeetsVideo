import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite struct AssetAnalysisTests {
    /// Black for its first half, then white: one cut in the middle.
    private func makeMovie(frames: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-analysis-\(UUID().uuidString).mov")
        try await writeMovie(to: url, segments: [(0, frames / 2), (255, frames - frames / 2)])
        return url
    }

    private func project(with urls: [URL], kind: MediaKind = .video) -> EditingProject {
        var project = EditingProject.empty
        project.clips = urls.map {
            MediaClip(name: $0.lastPathComponent, kind: kind, url: $0, duration: CMTime(seconds: 1, preferredTimescale: 600),
                      frameRate: 24, colorSpace: .rec709, codecName: "Test", acceptedStamp: FileStamp(url: $0))
        }
        return project
    }

    private func sources(of project: EditingProject) -> AnalysisSources {
        var sources = AnalysisSources()
        for clip in project.clips { sources.scores[clip.id] = clip.acceptedStamp }
        return sources
    }

    private func waitUntilIdle(_ analysis: AssetAnalysis, expecting count: Int) async throws {
        for _ in 0..<2000 {
            if analysis.progress.isEmpty && analysis.tracks.count + analysis.failures.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("analysis did not finish")
    }

    private func waitForReferences(_ analysis: AssetAnalysis, expecting count: Int) async throws {
        for _ in 0..<2000 {
            if analysis.progress.isEmpty && analysis.references.count + analysis.referenceFailures.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("reference capture did not finish")
    }

    @Test func analyzesVideoAssetsAndMarksThemUnsaved() async throws {
        let first = try await makeMovie(frames: 24), second = try await makeMovie(frames: 48)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let project = project(with: [first, second])
        let analysis = AssetAnalysis()

        analysis.update(with: project)
        try await waitUntilIdle(analysis, expecting: 2)

        #expect(analysis.tracks[project.clips[0].id]?.frameCount == 24)
        #expect(analysis.tracks[project.clips[1].id]?.frameCount == 48)
        #expect(Set(analysis.unsavedTracks.keys) == Set(project.clips.map(\.id)))

        analysis.markSaved(analysis.unsavedResults())
        #expect(analysis.unsavedTracks.isEmpty)
    }

    @Test func withAPackageResultsAreWrittenAtOnceAndPicturesLeaveMemory() async throws {
        let movie = try await makeMovie(frames: 48)
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-analysis-\(UUID().uuidString).amv")
        defer { try? FileManager.default.removeItem(at: movie); try? FileManager.default.removeItem(at: package) }
        try ProjectStore.preparePackage(at: package)
        let video = project(with: [movie])
        let id = video.clips[0].id
        let analysis = AssetAnalysis()

        analysis.reset(packageURL: package)
        analysis.update(with: video)
        try await waitUntilIdle(analysis, expecting: 1)

        #expect(analysis.unsavedTracks.isEmpty)
        #expect(analysis.unsavedReferences.isEmpty)
        #expect(analysis.unsavedThumbnails.isEmpty)
        #expect(analysis.thumbnailed == [id])
        #expect(ProjectStore.readChangeScores(for: id, in: package) == analysis.tracks[id])
        #expect(ProjectStore.readReference(for: id, in: package) != nil)
        #expect(ProjectStore.hasThumbnails(for: id, in: package))
    }

    @Test func whatThePackageAlreadyHoldsIsLoadedNotAnalyzedAgain() async throws {
        let movie = try await makeMovie(frames: 48)
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-analysis-\(UUID().uuidString).amv")
        defer { try? FileManager.default.removeItem(at: movie); try? FileManager.default.removeItem(at: package) }
        try ProjectStore.preparePackage(at: package)
        let video = project(with: [movie])
        let id = video.clips[0].id
        let first = AssetAnalysis()
        first.reset(packageURL: package)
        first.update(with: video)
        try await waitUntilIdle(first, expecting: 1)

        // As when the same file is imported again under its earlier ID. Its
        // saved results are read first, and only then is anything analyzed.
        let again = AssetAnalysis()
        let analyzed = Mutex(0)
        let live = again.backend
        again.backend.captureReference = { analyzed.increment(); return try await live.captureReference($0, $1) }
        again.backend.scoreFrames = { analyzed.increment(); return try await live.scoreFrames($0, $1) }
        again.backend.capturePictures = { analyzed.increment(); return try await live.capturePictures($0, $1, $2) }
        again.backend.detectBeats = { analyzed.increment(); return try await live.detectBeats($0, $1) }
        again.reset(packageURL: package)
        again.update(with: video)
        #expect(again.isLoadingSaved)
        for _ in 0..<2000 where again.isLoadingSaved || !again.progress.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))

        #expect(again.progress.isEmpty)
        #expect(analyzed.value == 0)
        #expect(again.tracks[id] == first.tracks[id])
        #expect(again.references[id] != nil)
        #expect(again.thumbnailed == [id])
    }

    @Test func audioAssetsGetReferenceDataButNoScores() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        let audio = project(with: [movie], kind: .audio)
        let analysis = AssetAnalysis()

        analysis.update(with: audio)
        try await waitForReferences(analysis, expecting: 1)

        #expect(analysis.tracks.isEmpty)
        #expect(analysis.references[audio.clips[0].id] != nil)
    }

    @Test func skipsAssetsThatAlreadyHaveEverything() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        let video = project(with: [movie])
        let id = video.clips[0].id
        let saved = ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 0])
        let reference = try await ReferenceCapture.capture(url: movie)
        let analysis = AssetAnalysis()

        analysis.reset(tracks: [id: saved], references: [id: reference], thumbnailed: [id], sources: sources(of: video))
        analysis.update(with: video)

        #expect(analysis.progress.isEmpty)
        #expect(analysis.tracks[id] == saved)
        #expect(analysis.unsavedTracks.isEmpty)
        #expect(analysis.unsavedReferences.isEmpty)
    }

    @Test func capturesReferencePicturesForVideoOnce() async throws {
        let movie = try await makeMovie(frames: 48)
        defer { try? FileManager.default.removeItem(at: movie) }
        let video = project(with: [movie])
        let id = video.clips[0].id
        let analysis = AssetAnalysis()

        analysis.update(with: video)
        try await waitUntilIdle(analysis, expecting: 1)

        let pictures = try #require(analysis.unsavedThumbnails[id])
        #expect(pictures.frames.count >= 3)
        #expect(analysis.thumbnailed == [id])

        analysis.markSaved(analysis.unsavedResults())
        #expect(analysis.unsavedThumbnails.isEmpty)
        #expect(analysis.thumbnailed == [id])
        analysis.update(with: video)
        #expect(analysis.progress.isEmpty)
    }

    @Test func assetsWithSavedPicturesAreNotCapturedAgain() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        let video = project(with: [movie])
        let id = video.clips[0].id
        let analysis = AssetAnalysis()
        analysis.reset(
            tracks: [id: ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 0])],
            references: [id: try await ReferenceCapture.capture(url: movie)],
            thumbnailed: [id], sources: sources(of: video)
        )

        analysis.update(with: video)

        #expect(analysis.progress.isEmpty)
    }

    @Test func capturesReferenceDataOnceAndKeepsItWhenTheFileChanges() async throws {
        let first = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: first) }
        var video = project(with: [first])
        let id = video.clips[0].id
        let analysis = AssetAnalysis()

        analysis.update(with: video)
        try await waitForReferences(analysis, expecting: 1)
        let captured = try #require(analysis.references[id])
        #expect(analysis.unsavedReferences[id] == captured)

        analysis.markSaved(analysis.unsavedResults())
        #expect(analysis.unsavedReferences.isEmpty)

        let replacement = try await makeMovie(frames: 96)
        defer { try? FileManager.default.removeItem(at: replacement) }
        video.clips[0].url = replacement
        video.clips[0].acceptedStamp = FileStamp(url: replacement)
        analysis.update(with: video)
        analysis.reanalyze(video.clips[0], in: video)
        try await waitUntilIdle(analysis, expecting: 1)

        #expect(analysis.references[id] == captured)
        #expect(analysis.unsavedReferences.isEmpty)
    }

    @Test func aForgottenOriginalIsNotCapturedAgain() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        var video = project(with: [movie])
        let id = video.clips[0].id
        let analysis = AssetAnalysis()
        analysis.update(with: video)
        try await waitForReferences(analysis, expecting: 1)

        video.markReferenceForgotten(forAsset: id)
        // Kept until a save deletes it, so undoing the forget loses nothing.
        #expect(analysis.references[id] != nil)

        analysis.dropForgottenReferences(in: video)
        #expect(analysis.references[id] == nil)
        #expect(analysis.unsavedReferences[id] == nil)

        analysis.update(with: video)
        #expect(analysis.references[id] == nil)
        #expect(analysis.progress.isEmpty)
    }

    @Test func aReplacedFileIsNeverCapturedAsTheOriginal() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        var video = project(with: [movie])
        video.clips[0].previousPaths = ["/elsewhere/original.mov"]
        let analysis = AssetAnalysis()
        analysis.reset(
            tracks: [video.clips[0].id: ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 0])],
            sources: sources(of: video)
        )

        analysis.update(with: video)

        #expect(analysis.progress.isEmpty)
        #expect(analysis.references.isEmpty)
    }

    @Test func anUnreadableFileIsReportedAndNotRetried() async throws {
        let bad = FileManager.default.temporaryDirectory.appending(path: "amv-bad-\(UUID().uuidString).mov")
        try Data("nope".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        let project = project(with: [bad])
        let analysis = AssetAnalysis()

        analysis.update(with: project)
        try await waitUntilIdle(analysis, expecting: 1)

        #expect(analysis.failures[project.clips[0].id] != nil)
        analysis.update(with: project)
        #expect(analysis.progress.isEmpty)
    }

    @Test func resettingDropsResultsFromTheOldProject() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        let project = project(with: [movie])
        let analysis = AssetAnalysis()

        analysis.update(with: project)
        analysis.reset()
        try await Task.sleep(for: .milliseconds(300))

        #expect(analysis.tracks.isEmpty)
        #expect(analysis.progress.isEmpty)
    }

}

/// A step that stays suspended until the test lets it finish.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var arrivals = 0

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                arrivals += 1
                if !isOpen { continuations.append(continuation) }
                return isOpen
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { continuations = [] }
            return continuations
        }
        pending.forEach { $0.resume() }
    }

    var arrived: Int { lock.withLock { arrivals } }
}

@MainActor
@Suite struct AssetAnalysisRaceTests {
    private func project(ids: [UUID] = [UUID()], hasAudio: Bool = false) -> EditingProject {
        var project = EditingProject.empty
        project.clips = ids.map {
            var clip = MediaClip(
                id: $0, name: "a.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"),
                duration: CMTime(seconds: 1, preferredTimescale: 600),
                frameRate: 24, colorSpace: .rec709, codecName: "Test"
            )
            clip.hasAudio = hasAudio
            return clip
        }
        return project
    }

    private func track(_ marker: UInt8) -> ChangeScoreTrack {
        ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, marker])
    }

    private func reference() -> AssetReference {
        AssetReference(
            metadata: AssetMetadataSnapshot(
                fileName: "a.mov", originalPath: "/dev/null", byteCount: 1, modified: nil, isVideo: true,
                durationValue: 600, durationTimescale: 600, frameRate: 24, width: 16, height: 16,
                codecName: "Test", audioSampleRate: nil, capturedAt: 0
            ),
            audioEnvelope: nil
        )
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("condition never held")
    }

    private func makePackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-race-\(UUID().uuidString).amv")
        try ProjectStore.preparePackage(at: package)
        return package
    }

    /// Scores come from `score`; everything else finishes at once without data.
    private func scoring(_ analysis: AssetAnalysis, _ score: @escaping @Sendable () async throws -> ChangeScoreTrack) {
        analysis.backend.scoreFrames = { _, _ in try await score() }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.backend.capturePictures = { _, _, _ in ReferenceThumbnails(frames: []) }
        analysis.backend.detectBeats = { _, _ in BeatTrack.none() }
    }

    @Test func aResultThatArrivesAfterResetIsDropped() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        scoring(analysis) { await gate.wait(); return ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1]) }
        analysis.update(with: project(ids: [id]))
        try await settle { gate.arrived == 1 }

        analysis.reset()
        gate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(analysis.tracks.isEmpty)
        #expect(analysis.progress.isEmpty)
        #expect(analysis.unsavedTracks.isEmpty)
    }

    @Test func aWriteFinishingAfterResetChangesNothingInTheNewProject() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let writeGate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1]) }
        analysis.backend.perform = { package, body in await writeGate.wait(); try body(package) }
        analysis.reset(packageURL: package)
        analysis.update(with: project(ids: [id]))
        try await settle { writeGate.arrived >= 1 }

        // The same asset ID in the next project, with its own dirty result.
        analysis.reset(tracks: [:], packageURL: nil)
        analysis.backend.perform = { _, _ in }
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 2]) }
        analysis.update(with: project(ids: [id]))
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }
        let before = analysis.unsavedTracks
        let stages = analysis.stages

        writeGate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(analysis.unsavedTracks == before)
        #expect(analysis.tracks[id]?.scores == [0, 2])
        #expect(analysis.stages == stages)
    }

    @Test func aLateWriteOfAnOlderRevisionLeavesTheNewerOneUnsaved() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let writeGate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = project(ids: [id])
        let revisionCount = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(revisionCount.increment())]) }
        // Only the first write is held back.
        analysis.backend.perform = { package, body in
            if writeGate.arrived == 0 { await writeGate.wait() }
            try body(package)
        }
        analysis.reset(packageURL: package)
        analysis.update(with: video)
        try await settle { writeGate.arrived == 1 }

        // Re-detecting retires the result whose write is still in flight.
        analysis.reanalyze(video.clips[0], in: video)
        #expect(analysis.unsavedTracks.isEmpty)
        writeGate.open()
        try await settle { analysis.tracks[id]?.scores == [0, 2] && analysis.progress.isEmpty }
        try await Task.sleep(for: .milliseconds(100))

        // The older write's acknowledgement did not disturb the newer result.
        #expect(analysis.tracks[id]?.scores == [0, 2])
        #expect(analysis.unsavedTracks.isEmpty)
        #expect(ProjectStore.readChangeScores(for: id, in: package)?.scores == [0, 2])
    }

    @Test func savingOnlyMarksWhatTheSaveContained() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = project(ids: [id])
        let counter = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(counter.increment())]) }
        analysis.update(with: video)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }
        let snapshot = analysis.unsavedResults()

        analysis.reanalyze(video.clips[0], in: video)
        try await settle { analysis.tracks[id]?.scores == [0, 2] && analysis.progress.isEmpty }
        analysis.markSaved(snapshot)

        #expect(analysis.unsavedTracks[id]?.scores == [0, 2])
    }

    @Test func redetectingWhileScoringKeepsOnlyTheReplacement() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = project(ids: [id])
        let counter = Mutex(0)
        scoring(analysis) {
            let attempt = counter.increment()
            if attempt == 1 { await gate.wait() }
            return ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(attempt)])
        }
        analysis.update(with: video)
        try await settle { gate.arrived == 1 }

        analysis.reanalyze(video.clips[0], in: video)
        gate.open()
        try await settle { analysis.progress.isEmpty && analysis.tracks[id] != nil }
        try await Task.sleep(for: .milliseconds(50))

        #expect(analysis.tracks[id]?.scores == [0, 2])
        #expect(counter.value == 2)
    }

    @Test func redetectingIgnoresTheScoreSavedInThePackage() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let id = UUID()
        let video = project(ids: [id])
        try ProjectStore.writeChangeScores(track(1), for: id, in: package)
        let analysis = AssetAnalysis()
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 9]) }
        analysis.reset(packageURL: package)

        analysis.reanalyze(video.clips[0], in: video)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }

        #expect(analysis.tracks[id]?.scores == [0, 9])
    }

    @Test func aFailedRedetectionLeavesNoOldScoreToReload() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let id = UUID()
        let video = project(ids: [id])
        try ProjectStore.writeChangeScores(track(1), for: id, in: package)
        let analysis = AssetAnalysis()
        scoring(analysis) { throw NSError(domain: "test", code: 2) }
        analysis.reset(packageURL: package)

        analysis.reanalyze(video.clips[0], in: video)
        try await settle { analysis.failures[id] != nil && analysis.progress.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(analysis.tracks[id] == nil)
        #expect(ProjectStore.readChangeScores(for: id, in: package) == nil)
    }

    @Test func aFileReplacedWhileScoringIsNotCommittedAsTheOldRun() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        var video = project(ids: [id])
        let counter = Mutex(0)
        scoring(analysis) {
            let attempt = counter.increment()
            if attempt == 1 { await gate.wait() }
            return ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(attempt)])
        }
        analysis.update(with: video)
        try await settle { gate.arrived == 1 }

        video.clips[0].url = URL(fileURLWithPath: "/etc/hosts")
        analysis.update(with: video)
        gate.open()
        try await settle { analysis.progress.isEmpty && analysis.tracks[id] != nil }
        try await Task.sleep(for: .milliseconds(50))

        #expect(analysis.tracks[id]?.scores == [0, 2])
    }

    @Test func removingAnAssetDropsItsRunningJob() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        var video = project(ids: [id])
        scoring(analysis) { await gate.wait(); return ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1]) }
        analysis.update(with: video)
        try await settle { gate.arrived == 1 }

        video.clips = []
        analysis.update(with: video)
        gate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(analysis.tracks.isEmpty)
        #expect(analysis.progress.isEmpty)
    }

    @Test func forgettingTheOriginalDuringCaptureKeepsItForgotten() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        var video = project(ids: [id])
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1]) }
        let captured = reference()
        analysis.backend.captureReference = { _, _ in await gate.wait(); return captured }
        analysis.update(with: video)
        try await settle { gate.arrived == 1 }

        video.markReferenceForgotten(forAsset: id)
        analysis.update(with: video)
        gate.open()
        try await settle { analysis.progress.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(analysis.references[id] == nil)
        #expect(analysis.unsavedReferences.isEmpty)
        #expect(!analysis.thumbnailed.contains(id))
    }

    @Test func aStageThatThrowsCancellationLeavesNoOrphanedProgress() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        scoring(analysis) { throw CancellationError() }
        analysis.update(with: project(ids: [id]))

        try await settle { analysis.progress.isEmpty && analysis.failures[id] != nil }

        #expect(analysis.stages.isEmpty)
    }

    @Test func aSupersededJobCannotClearTheReplacementsProgress() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = project(ids: [id])
        let counter = Mutex(0)
        scoring(analysis) {
            let attempt = counter.increment()
            await gate.wait()
            return ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(attempt)])
        }
        analysis.update(with: video)
        try await settle { gate.arrived == 1 }
        analysis.reanalyze(video.clips[0], in: video)
        // The first job finishes only now; the replacement hasn't started yet.
        gate.open()
        try await settle { analysis.progress.isEmpty && analysis.tracks[id] != nil }

        #expect(analysis.tracks[id]?.scores == [0, 2])
    }

    // MARK: Provenance and durable retirement

    private let stampA = FileStamp(byteCount: 100, modified: 1)
    private let stampB = FileStamp(byteCount: 200, modified: 2)

    private func stamped(_ video: EditingProject, _ stamp: FileStamp) -> EditingProject {
        var video = video
        for index in video.clips.indices { video.clips[index].acceptedStamp = stamp }
        return video
    }

    @Test func scoresWithNoKnownSourceAreAnalyzedAgain() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 5]) }

        analysis.reset(tracks: [id: track(1)])
        analysis.update(with: video)
        try await settle { analysis.tracks[id]?.scores == [0, 5] && analysis.progress.isEmpty }
    }

    @Test func scoresFromTheSameFileAreKept() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        let scored = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(scored.increment())]) }
        analysis.reset(tracks: [id: track(1)], sources: AnalysisSources(scores: [id: stampA]))

        analysis.update(with: video)
        try await settle { analysis.progress.isEmpty }

        #expect(scored.value == 0)
        #expect(analysis.tracks[id]?.scores == [0, 1])
    }

    @Test func replacingTheFileRetiresItsScoresAndFindsThemAgain() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        let counter = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(counter.increment())]) }
        analysis.update(with: video)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }

        analysis.update(with: stamped(video, stampB))
        #expect(analysis.tracks[id] == nil)
        try await settle { analysis.tracks[id]?.scores == [0, 2] && analysis.progress.isEmpty }
    }

    @Test func aRetiredBeatFileThatCannotBeDeletedStaysRetiredAfterReopening() async throws {
        let package = try makePackage()
        let id = UUID()
        let file = ProjectStore.referenceFolder(for: id, in: package).appending(path: ProjectStore.beatFileName)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: package)
        }
        let video = stamped(project(ids: [id], hasAudio: true), stampA)
        try ProjectStore.writeBeats(.none(), for: id, in: package, source: stampA)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        let analysis = AssetAnalysis()
        scoring(analysis) { throw NSError(domain: "test", code: 3) }
        analysis.backend.detectBeats = { _, _ in throw NSError(domain: "test", code: 4) }
        analysis.reset(beats: [id: .none()], sources: AnalysisSources(beats: [id: stampA]), packageURL: package)

        // The file changes, so the saved beats no longer apply.
        analysis.update(with: stamped(video, stampB))
        try await settle { analysis.discardedBeats.isEmpty }

        #expect(FileManager.default.fileExists(atPath: file.path))
        let reopened = ProjectStore.readVerifiedBeats(for: id, in: package, identity: stampA)
        guard case .rejected(.invalidated) = reopened else {
            Issue.record("the retired beats were accepted again")
            return
        }
    }

    @Test func aRetirementThatCannotBePersistedStaysPendingAndVisibleUntilItCan() async throws {
        let package = try makePackage()
        let id = UUID()
        let directory = ProjectStore.referenceFolder(for: id, in: package)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: package)
        }
        let video = stamped(project(ids: [id], hasAudio: true), stampA)
        try ProjectStore.writeBeats(.none(), for: id, in: package, source: stampA)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let analysis = AssetAnalysis()
        scoring(analysis) { throw NSError(domain: "test", code: 3) }
        analysis.backend.detectBeats = { _, _ in throw NSError(domain: "test", code: 4) }
        analysis.reset(beats: [id: .none()], sources: AnalysisSources(beats: [id: stampA]), packageURL: package)

        analysis.update(with: stamped(video, stampB))
        try await settle { !analysis.invalidationFailures.isEmpty }

        #expect(analysis.discardedBeats == [id])
        // The same results go to a save, which fails rather than lose the retirement.
        #expect(analysis.unsavedResults().discardedBeats == [id])

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        analysis.retryPendingInvalidations()
        try await settle { analysis.discardedBeats.isEmpty }
        #expect(analysis.invalidationFailures.isEmpty)
        #expect(ProjectStore.readBeats(for: id, in: package) == nil)
    }

    @Test func aRedetectedScoreCannotComeBackWhenItsFileCannotBeDeleted() async throws {
        let package = try makePackage()
        let id = UUID()
        let file = ProjectStore.referenceFolder(for: id, in: package).appending(path: ProjectStore.changeScoreFileName)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: package)
        }
        let video = stamped(project(ids: [id]), stampA)
        try ProjectStore.writeChangeScores(track(1), for: id, in: package, source: stampA)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        let analysis = AssetAnalysis()
        scoring(analysis) { throw NSError(domain: "test", code: 5) }
        analysis.reset(packageURL: package)

        analysis.reanalyze(video.clips[0], in: video)
        try await settle { analysis.failures[id] != nil && analysis.progress.isEmpty }
        try await settle { analysis.unsavedResults().invalidatedScores.isEmpty }

        guard case .rejected(.invalidated) = ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stampA) else {
            Issue.record("the old score is usable again")
            return
        }
    }

    // MARK: Inputs checked by the job itself

    @MainActor private final class ProjectBox {
        var project: EditingProject
        init(_ project: EditingProject) { self.project = project }
    }

    /// Records what the package held for the asset after every operation on it.
    private final class PackageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var scores: [[UInt8]] = [], beatFileSeen = false
        func record(_ id: UUID, _ package: URL) {
            lock.withLock {
                if let track = ProjectStore.readChangeScores(for: id, in: package) { scores.append(track.scores) }
                if ProjectStore.readBeats(for: id, in: package) != nil { beatFileSeen = true }
            }
        }
        var everHeldScores: [[UInt8]] { lock.withLock { scores } }
        var everHeldBeats: Bool { lock.withLock { beatFileSeen } }
    }

    private func logging(_ analysis: AssetAnalysis, _ id: UUID, _ log: PackageLog) {
        analysis.backend.perform = { package, body in
            try await PackageCoordinator.shared.run(on: [package]) {
                try body(package)
                log.record(id, package)
            }
        }
    }

    @Test func aFileReplacedWithoutAnyNotificationIsNotCommittedAsTheOldRun() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let log = PackageLog()
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        let box = ProjectBox(stamped(project(ids: [id]), stampA))
        let counter = Mutex(0)
        scoring(analysis) {
            let attempt = counter.increment()
            if attempt == 1 { await gate.wait() }
            return ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(attempt)])
        }
        logging(analysis, id, log)
        analysis.reset(packageURL: package)
        analysis.projectSource = { box.project }
        analysis.update(with: box.project)
        try await settle { gate.arrived == 1 }

        // The project changes; nothing calls `update`.
        box.project = stamped(box.project, stampB)
        gate.open()
        try await settle { analysis.progress.isEmpty && analysis.tracks[id] != nil }

        #expect(analysis.tracks[id]?.scores == [0, 2])
        #expect(counter.value == 2)
        #expect(!log.everHeldScores.contains([0, 1]))
    }

    @Test func removingAudioDuringBeatDetectionPublishesNoBeats() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let log = PackageLog()
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        let box = ProjectBox(stamped(project(ids: [id], hasAudio: true), stampA))
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1]) }
        analysis.backend.detectBeats = { _, _ in await gate.wait(); return BeatTrack(timescale: 1000, times: [1], beatsPerMinute: 120) }
        logging(analysis, id, log)
        analysis.reset(packageURL: package)
        analysis.projectSource = { box.project }
        analysis.update(with: box.project)
        try await settle { gate.arrived == 1 }

        box.project.clips[0].hasAudio = false
        gate.open()
        try await settle { analysis.progress.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(analysis.beats[id] == nil)
        #expect(!log.everHeldBeats)
    }

    @Test func forgettingTheOriginalWithoutAnyNotificationStopsTheCapture() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        let box = ProjectBox(stamped(project(ids: [id]), stampA))
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1]) }
        let captured = reference()
        analysis.backend.captureReference = { _, _ in await gate.wait(); return captured }
        analysis.projectSource = { box.project }
        analysis.update(with: box.project)
        try await settle { gate.arrived == 1 }

        box.project.markReferenceForgotten(forAsset: id)
        gate.open()
        try await settle { analysis.progress.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(analysis.references[id] == nil)
        #expect(analysis.unsavedReferences.isEmpty)
    }

    // MARK: Reading the package

    @Test func resettingDuringAReadDropsWhatItFound() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let gate = Gate()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        try ProjectStore.writeChangeScores(track(1), for: id, in: package, source: stampA)
        let analysis = AssetAnalysis()
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 9]) }
        let live = analysis.backend
        analysis.backend.readSaved = { package, id, identity, includingReference in
            await gate.wait()
            return await live.readSaved(package, id, identity, includingReference)
        }
        analysis.reset(packageURL: package)
        analysis.update(with: video)
        try await settle { gate.arrived == 1 }

        analysis.reset()
        gate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(analysis.tracks.isEmpty)
        #expect(!analysis.isLoadingSaved)
    }

    @Test func theMainActorRunsWhileASlowReadIsSuspended() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        try ProjectStore.writeChangeScores(track(1), for: id, in: package, source: stampA)
        let analysis = AssetAnalysis()
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 9]) }
        observing(analysis) { self.stampA }
        analysis.reset(packageURL: package)
        // A slow disk: an operation ahead of the read in the package's queue,
        // held open until the test lets it go.
        let gate = Gate()
        let slow = Task { try await PackageCoordinator.shared.run(on: [package]) { await gate.wait() } }
        try await settle { gate.arrived == 1 }

        analysis.update(with: video)
        #expect(analysis.isLoadingSaved)

        // With the read suspended, the main actor still runs other work.
        let ran = Mutex(0)
        await Task { @MainActor in _ = ran.increment() }.value
        #expect(ran.value == 1)
        #expect(analysis.isLoadingSaved)
        #expect(analysis.tracks[id] == nil)

        gate.open()
        try await slow.value
        try await settle { !analysis.isLoadingSaved }
        #expect(analysis.tracks[id]?.scores == [0, 1])
    }

    @Test func aScoreRetiredWhileAReadWasQueuedIsNotReadBack() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        try ProjectStore.writeChangeScores(track(1), for: id, in: package, source: stampA)
        let analysis = AssetAnalysis()
        let counter = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(8 + counter.increment())]) }
        analysis.reset(packageURL: package)
        analysis.update(with: video)

        // Re-detect before the first read is back.
        analysis.reanalyze(video.clips[0], in: video)
        try await settle { analysis.tracks[id]?.scores == [0, 9] && analysis.progress.isEmpty && !analysis.isLoadingSaved }

        #expect(counter.value == 1)
    }

    // MARK: Structured failures and retries

    @Test func failuresAreSortedIntoKinds() {
        let cases: [(any Error, AnalysisFailure.Kind)] = [
            (CocoaError(.fileNoSuchFile), .missingFile),
            (CocoaError(.fileReadNoSuchFile), .missingFile),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)), .missingFile),
            (CocoaError(.fileReadNoPermission), .permissionDenied),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), .permissionDenied),
            (CocoaError(.fileReadCorruptFile), .corruptMedia),
            (FrameScorer.ScoringError.noVideoTrack, .unsupportedMedia),
            (BeatDetector.DetectionError.noAudioTrack, .unsupportedMedia),
            (NSError(domain: AVFoundationErrorDomain, code: AVError.fileFormatNotRecognized.rawValue), .unsupportedMedia),
            (NSError(domain: AVFoundationErrorDomain, code: AVError.fileFailedToParse.rawValue), .corruptMedia),
            (FrameScorer.ScoringError.readerFailed("x", underlying: CocoaError(.fileReadNoPermission)), .permissionDenied),
            (FrameScorer.ScoringError.readerFailed("unsupported video format"), .unsupportedMedia),
            (NSError(domain: "other", code: 1, userInfo: [NSUnderlyingErrorKey: CocoaError(.fileNoSuchFile)]), .missingFile),
            (CancellationError(), .interrupted),
            (NSError(domain: "other", code: 1), .other),
        ]
        for (error, kind) in cases {
            #expect(AnalysisFailure.kind(of: error) == kind, "\(error)")
        }
    }

    @Test func aFailureNamesItsStageAndTheFileItRanOn() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        scoring(analysis) { throw FrameScorer.ScoringError.noVideoTrack }
        analysis.update(with: video)
        try await settle { analysis.failure(.scenes, for: id) != nil && analysis.progress.isEmpty }

        let failure = try #require(analysis.failure(.scenes, for: id))
        #expect(failure.stage == .scenes)
        #expect(failure.kind == .unsupportedMedia)
        #expect(failure.file?.stamp == stampA)
        #expect(failure.title == "Scene detection failed")
    }

    @Test func aFileThatVanishesMidRunIsUnavailableNotFailed() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        scoring(analysis) { throw CocoaError(.fileNoSuchFile) }
        analysis.update(with: video)
        try await settle { analysis.progress.isEmpty }

        #expect(analysis.failure(.scenes, for: id) == nil)
        // It waits for the file; an asset given another file is tried at once.
        let counter = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(counter.increment())]) }
        analysis.update(with: video)
        try await Task.sleep(for: .milliseconds(50))
        #expect(counter.value == 0)
        analysis.update(with: stamped(video, stampB))
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }
    }

    @Test func aFailureIsDroppedWhenItsFileChanges() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        let counter = Mutex(0)
        scoring(analysis) {
            if counter.increment() == 1 { throw FrameScorer.ScoringError.noVideoTrack }
            return ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 4])
        }
        analysis.update(with: video)
        try await settle { analysis.failure(.scenes, for: id) != nil && analysis.progress.isEmpty }

        analysis.update(with: video)
        #expect(analysis.failure(.scenes, for: id) != nil)

        analysis.update(with: stamped(video, stampB))
        #expect(analysis.failure(.scenes, for: id) == nil)
        try await settle { analysis.tracks[id]?.scores == [0, 4] && analysis.progress.isEmpty }
    }

    @Test func aFailedStageCanBeRetriedWithoutResettingAnythingElse() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id], hasAudio: true), stampA)
        let beatAttempts = Mutex(0)
        let scored = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(scored.increment())]) }
        analysis.backend.captureReference = { _, _ in throw FrameScorer.ScoringError.noVideoTrack }
        analysis.backend.detectBeats = { _, _ in
            if beatAttempts.increment() == 1 { throw BeatDetector.DetectionError.noAudioTrack }
            return BeatTrack.none()
        }
        analysis.update(with: video)
        try await settle { analysis.failure(.beats, for: id) != nil && analysis.progress.isEmpty }
        let track = analysis.tracks[id]

        #expect(analysis.retry(.beats, for: id, in: video))
        try await settle { analysis.beats[id] != nil && analysis.progress.isEmpty }

        #expect(scored.value == 1)
        #expect(analysis.tracks[id] == track)
        #expect(analysis.failure(.reference, for: id) != nil)
    }

    @Test func aPictureFailureCanBeRetried() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        let attempts = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1]) }
        analysis.backend.capturePictures = { _, _, _ in
            if attempts.increment() == 1 { throw CocoaError(.fileReadCorruptFile) }
            return ReferenceThumbnails(frames: [])
        }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.update(with: video)
        try await settle { analysis.failure(.pictures, for: id) != nil && analysis.progress.isEmpty }
        #expect(analysis.failure(.pictures, for: id)?.kind == .corruptMedia)

        analysis.retry(.pictures, for: id, in: video)
        try await settle { analysis.thumbnailed.contains(id) && analysis.progress.isEmpty }
    }

    @Test func theOriginalIsNeverRecapturedFromAReplacementEvenOnRetry() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        var video = stamped(project(ids: [id]), stampA)
        let captures = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1]) }
        analysis.backend.captureReference = { _, _ in captures.increment(); throw NSError(domain: "test", code: 1) }
        analysis.update(with: video)
        try await settle { analysis.failure(.reference, for: id) != nil && analysis.progress.isEmpty }
        #expect(captures.value == 1)

        video.clips[0].previousPaths = ["/elsewhere/original.mov"]
        video.clips[0].acceptedStamp = stampB
        analysis.update(with: video)
        #expect(!analysis.retry(.reference, for: id, in: video))
        #expect(!analysis.retry(.pictures, for: id, in: video))
        try await settle { analysis.progress.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(captures.value == 1)
        #expect(analysis.references[id] == nil)
    }

    @Test func aResultThatCannotBeWrittenIsReportedAndKept() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        let failing = Mutex(1)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 3]) }
        analysis.backend.perform = { package, body in
            if failing.value == 1 { throw CocoaError(.fileWriteNoPermission) }
            try body(package)
        }
        analysis.reset(packageURL: package)
        analysis.update(with: video)
        try await settle { analysis.progress.isEmpty && analysis.tracks[id] != nil }

        let failure = try #require(analysis.persistenceFailures[.init(id: id, stage: .scenes)])
        #expect(failure.kind == .persistence)
        #expect(analysis.unsavedTracks[id] != nil)
        // The result is still usable; the failure is not an analysis failure.
        #expect(analysis.failure(.scenes, for: id) == nil)

        // What the library shows, and what its retry does.
        #expect(analysis.persistenceProblem(for: id)?.title == "Couldn't save results")
        #expect(analysis.hasPersistenceProblems)

        failing.increment()
        await analysis.retryPersistence()
        #expect(analysis.persistenceProblem(for: id) == nil)
        #expect(analysis.persistenceFailures[.init(id: id, stage: .scenes)] == nil)
        #expect(analysis.unsavedTracks.isEmpty)
    }

    // MARK: Observed identity

    /// Makes the disk show `stamp()` for the asset's file, whatever the project accepted.
    private func observing(_ analysis: AssetAnalysis, _ stamp: @escaping @Sendable () -> FileStamp?) {
        analysis.backend.observeFile = { _ in AssetAnalysis.FileObservation(exists: true, stamp: stamp()) }
    }

    @Test func aFileChangedOutsideTheAppIsNotAnalyzedUntilTheChangeIsAccepted() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        let scored = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(scored.increment())]) }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        // On disk the file is already the other version.
        observing(analysis) { self.stampB }
        analysis.reset(packageURL: package)
        analysis.update(with: video)
        try await settle { analysis.changedFiles[id] != nil && analysis.progress.isEmpty }

        #expect(scored.value == 0)
        #expect(analysis.tracks[id] == nil)
        #expect(analysis.changedFiles[id] == AssetAnalysis.ChangedFile(accepted: stampA, observed: stampB))

        // Accepting the change makes it the file the project means.
        analysis.update(with: stamped(video, stampB))
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }
        #expect(analysis.changedFiles[id] == nil)
        // Nothing was recorded under the old identity.
        guard case .valid(_, let source) = ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stampB) else {
            Issue.record("the result is not recorded for the accepted file")
            return
        }
        #expect(source == stampB)
        #expect({ if case .valid = ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stampA) { true } else { false } }() == false)
    }

    @Test func aFileThatChangesWhileItIsReadGivesNoResult() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let log = PackageLog()
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        let calls = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1]) }
        // As accepted when the job starts, different once it has been read.
        observing(analysis) { calls.increment() == 1 ? self.stampA : self.stampB }
        logging(analysis, id, log)
        analysis.reset(packageURL: package)
        analysis.update(with: video)
        try await settle { analysis.changedFiles[id] != nil && analysis.progress.isEmpty }

        #expect(analysis.tracks[id] == nil)
        #expect(log.everHeldScores.isEmpty)
    }

    @Test func savedResultsAreNotUsedForAFileThatChangedOutsideTheApp() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        try ProjectStore.writeChangeScores(track(1), for: id, in: package, source: stampA)
        try ProjectStore.writeReference(reference(), for: id, in: package)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 9]) }
        observing(analysis) { self.stampB }
        analysis.reset(packageURL: package)
        analysis.update(with: video)
        try await settle { !analysis.isLoadingSaved && analysis.progress.isEmpty }

        #expect(analysis.tracks[id] == nil)
        #expect(analysis.changedFiles[id] != nil)
        // The original's reference does not depend on the current file.
        #expect(analysis.references[id] != nil)
    }

    @Test func progressThatIsNotANumberOrOutOfRangeNeverReachesTheUI() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        analysis.backend.scoreFrames = { _, progress in
            progress(.nan); progress(.infinity); progress(-3); progress(7)
            await gate.wait()
            return ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, 1])
        }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.backend.capturePictures = { _, _, _ in ReferenceThumbnails(frames: []) }
        analysis.update(with: project(ids: [id]))
        try await settle { gate.arrived == 1 }
        try await Task.sleep(for: .milliseconds(50))

        let value = try #require(analysis.progress[id])
        #expect(value >= 0 && value <= 1)
        gate.open()
    }
}

final class Mutex: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int
    init(_ value: Int) { stored = value }
    var value: Int { lock.withLock { stored } }
    func increment() -> Int { lock.withLock { stored += 1; return stored } }
}
