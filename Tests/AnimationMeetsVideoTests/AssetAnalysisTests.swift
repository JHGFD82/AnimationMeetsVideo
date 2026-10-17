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

        analysis.analyzeMissing(in: project)
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
        analysis.analyzeMissing(in: video)
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
        first.analyzeMissing(in: video)
        try await waitUntilIdle(first, expecting: 1)

        // As when the same file is imported again under its earlier ID.
        let again = AssetAnalysis()
        again.reset(packageURL: package)
        again.analyzeMissing(in: video)

        #expect(again.progress.isEmpty)
        #expect(again.tracks[id] == first.tracks[id])
        #expect(again.references[id] != nil)
        #expect(again.thumbnailed == [id])
    }

    @Test func audioAssetsGetReferenceDataButNoScores() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        let audio = project(with: [movie], kind: .audio)
        let analysis = AssetAnalysis()

        analysis.analyzeMissing(in: audio)
        try await waitForReferences(analysis, expecting: 1)

        #expect(analysis.tracks.isEmpty)
        #expect(analysis.references[audio.clips[0].id] != nil)
    }

    @Test func skipsAssetsThatAlreadyHaveEverything() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        let video = project(with: [movie])
        let id = video.clips[0].id
        let saved = ChangeScoreTrack(timescale: 600, times: [0], scores: [0])
        let reference = try await ReferenceCapture.capture(url: movie)
        let analysis = AssetAnalysis()

        analysis.reset(tracks: [id: saved], references: [id: reference], thumbnailed: [id], sources: sources(of: video))
        analysis.analyzeMissing(in: video)

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

        analysis.analyzeMissing(in: video)
        try await waitUntilIdle(analysis, expecting: 1)

        let pictures = try #require(analysis.unsavedThumbnails[id])
        #expect(pictures.frames.count >= 3)
        #expect(analysis.thumbnailed == [id])

        analysis.markSaved(analysis.unsavedResults())
        #expect(analysis.unsavedThumbnails.isEmpty)
        #expect(analysis.thumbnailed == [id])
        analysis.analyzeMissing(in: video)
        #expect(analysis.progress.isEmpty)
    }

    @Test func assetsWithSavedPicturesAreNotCapturedAgain() async throws {
        let movie = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: movie) }
        let video = project(with: [movie])
        let id = video.clips[0].id
        let analysis = AssetAnalysis()
        analysis.reset(
            tracks: [id: ChangeScoreTrack(timescale: 600, times: [0], scores: [0])],
            references: [id: try await ReferenceCapture.capture(url: movie)],
            thumbnailed: [id], sources: sources(of: video)
        )

        analysis.analyzeMissing(in: video)

        #expect(analysis.progress.isEmpty)
    }

    @Test func capturesReferenceDataOnceAndKeepsItWhenTheFileChanges() async throws {
        let first = try await makeMovie(frames: 24)
        defer { try? FileManager.default.removeItem(at: first) }
        var video = project(with: [first])
        let id = video.clips[0].id
        let analysis = AssetAnalysis()

        analysis.analyzeMissing(in: video)
        try await waitForReferences(analysis, expecting: 1)
        let captured = try #require(analysis.references[id])
        #expect(analysis.unsavedReferences[id] == captured)

        analysis.markSaved(analysis.unsavedResults())
        #expect(analysis.unsavedReferences.isEmpty)

        let replacement = try await makeMovie(frames: 96)
        defer { try? FileManager.default.removeItem(at: replacement) }
        video.clips[0].url = replacement
        analysis.analyzeMissing(in: video)
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
        analysis.analyzeMissing(in: video)
        try await waitForReferences(analysis, expecting: 1)

        video.markReferenceForgotten(forAsset: id)
        // Kept until a save deletes it, so undoing the forget loses nothing.
        #expect(analysis.references[id] != nil)

        analysis.dropForgottenReferences(in: video)
        #expect(analysis.references[id] == nil)
        #expect(analysis.unsavedReferences[id] == nil)

        analysis.analyzeMissing(in: video)
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
            tracks: [video.clips[0].id: ChangeScoreTrack(timescale: 600, times: [0], scores: [0])],
            sources: sources(of: video)
        )

        analysis.analyzeMissing(in: video)

        #expect(analysis.progress.isEmpty)
        #expect(analysis.references.isEmpty)
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
        ChangeScoreTrack(timescale: 600, times: [0], scores: [marker])
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
        scoring(analysis) { await gate.wait(); return ChangeScoreTrack(timescale: 600, times: [0], scores: [1]) }
        analysis.analyzeMissing(in: project(ids: [id]))
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
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0], scores: [1]) }
        analysis.backend.perform = { package, body in await writeGate.wait(); try body(package) }
        analysis.reset(packageURL: package)
        analysis.analyzeMissing(in: project(ids: [id]))
        try await settle { writeGate.arrived >= 1 }

        // The same asset ID in the next project, with its own dirty result.
        analysis.reset(tracks: [:], packageURL: nil)
        analysis.backend.perform = { _, _ in }
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0], scores: [2]) }
        analysis.analyzeMissing(in: project(ids: [id]))
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }
        let before = analysis.unsavedTracks
        let stages = analysis.stages

        writeGate.open()
        try await Task.sleep(for: .milliseconds(100))

        #expect(analysis.unsavedTracks == before)
        #expect(analysis.tracks[id]?.scores == [2])
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
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0], scores: [UInt8(revisionCount.increment())]) }
        // Only the first write is held back.
        analysis.backend.perform = { package, body in
            if writeGate.arrived == 0 { await writeGate.wait() }
            try body(package)
        }
        analysis.reset(packageURL: package)
        analysis.analyzeMissing(in: video)
        try await settle { writeGate.arrived == 1 }

        // Re-detecting retires the result whose write is still in flight.
        analysis.reanalyze(video.clips[0], in: video)
        #expect(analysis.unsavedTracks.isEmpty)
        writeGate.open()
        try await settle { analysis.tracks[id]?.scores == [2] && analysis.progress.isEmpty }
        try await Task.sleep(for: .milliseconds(100))

        // The older write's acknowledgement did not disturb the newer result.
        #expect(analysis.tracks[id]?.scores == [2])
        #expect(analysis.unsavedTracks.isEmpty)
        #expect(ProjectStore.readChangeScores(for: id, in: package)?.scores == [2])
    }

    @Test func savingOnlyMarksWhatTheSaveContained() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = project(ids: [id])
        let counter = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0], scores: [UInt8(counter.increment())]) }
        analysis.analyzeMissing(in: video)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }
        let snapshot = analysis.unsavedResults()

        analysis.reanalyze(video.clips[0], in: video)
        try await settle { analysis.tracks[id]?.scores == [2] && analysis.progress.isEmpty }
        analysis.markSaved(snapshot)

        #expect(analysis.unsavedTracks[id]?.scores == [2])
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
            return ChangeScoreTrack(timescale: 600, times: [0], scores: [UInt8(attempt)])
        }
        analysis.analyzeMissing(in: video)
        try await settle { gate.arrived == 1 }

        analysis.reanalyze(video.clips[0], in: video)
        gate.open()
        try await settle { analysis.progress.isEmpty && analysis.tracks[id] != nil }
        try await Task.sleep(for: .milliseconds(50))

        #expect(analysis.tracks[id]?.scores == [2])
        #expect(counter.value == 2)
    }

    @Test func redetectingIgnoresTheScoreSavedInThePackage() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let id = UUID()
        let video = project(ids: [id])
        try ProjectStore.writeChangeScores(track(1), for: id, in: package)
        let analysis = AssetAnalysis()
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0], scores: [9]) }
        analysis.reset(packageURL: package)

        analysis.reanalyze(video.clips[0], in: video)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }

        #expect(analysis.tracks[id]?.scores == [9])
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
            return ChangeScoreTrack(timescale: 600, times: [0], scores: [UInt8(attempt)])
        }
        analysis.analyzeMissing(in: video)
        try await settle { gate.arrived == 1 }

        video.clips[0].url = URL(fileURLWithPath: "/etc/hosts")
        analysis.analyzeMissing(in: video)
        gate.open()
        try await settle { analysis.progress.isEmpty && analysis.tracks[id] != nil }
        try await Task.sleep(for: .milliseconds(50))

        #expect(analysis.tracks[id]?.scores == [2])
    }

    @Test func removingAnAssetDropsItsRunningJob() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        var video = project(ids: [id])
        scoring(analysis) { await gate.wait(); return ChangeScoreTrack(timescale: 600, times: [0], scores: [1]) }
        analysis.analyzeMissing(in: video)
        try await settle { gate.arrived == 1 }

        video.clips = []
        analysis.analyzeMissing(in: video)
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
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0], scores: [1]) }
        let captured = reference()
        analysis.backend.captureReference = { _, _ in await gate.wait(); return captured }
        analysis.analyzeMissing(in: video)
        try await settle { gate.arrived == 1 }

        video.markReferenceForgotten(forAsset: id)
        analysis.analyzeMissing(in: video)
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
        analysis.analyzeMissing(in: project(ids: [id]))

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
            return ChangeScoreTrack(timescale: 600, times: [0], scores: [UInt8(attempt)])
        }
        analysis.analyzeMissing(in: video)
        try await settle { gate.arrived == 1 }
        analysis.reanalyze(video.clips[0], in: video)
        // The first job finishes only now; the replacement hasn't started yet.
        gate.open()
        try await settle { analysis.progress.isEmpty && analysis.tracks[id] != nil }

        #expect(analysis.tracks[id]?.scores == [2])
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
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0], scores: [5]) }

        analysis.reset(tracks: [id: track(1)])
        analysis.analyzeMissing(in: video)
        try await settle { analysis.tracks[id]?.scores == [5] && analysis.progress.isEmpty }
    }

    @Test func scoresFromTheSameFileAreKept() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        let scored = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0], scores: [UInt8(scored.increment())]) }
        analysis.reset(tracks: [id: track(1)], sources: AnalysisSources(scores: [id: stampA]))

        analysis.analyzeMissing(in: video)
        try await settle { analysis.progress.isEmpty }

        #expect(scored.value == 0)
        #expect(analysis.tracks[id]?.scores == [1])
    }

    @Test func replacingTheFileRetiresItsScoresAndFindsThemAgain() async throws {
        let analysis = AssetAnalysis()
        let id = UUID()
        let video = stamped(project(ids: [id]), stampA)
        let counter = Mutex(0)
        scoring(analysis) { ChangeScoreTrack(timescale: 600, times: [0], scores: [UInt8(counter.increment())]) }
        analysis.analyzeMissing(in: video)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }

        analysis.analyzeMissing(in: stamped(video, stampB))
        #expect(analysis.tracks[id] == nil)
        try await settle { analysis.tracks[id]?.scores == [2] && analysis.progress.isEmpty }
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
        analysis.analyzeMissing(in: stamped(video, stampB))
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

        analysis.analyzeMissing(in: stamped(video, stampB))
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

    @Test func progressThatIsNotANumberOrOutOfRangeNeverReachesTheUI() async throws {
        let gate = Gate()
        let analysis = AssetAnalysis()
        let id = UUID()
        analysis.backend.scoreFrames = { _, progress in
            progress(.nan); progress(.infinity); progress(-3); progress(7)
            await gate.wait()
            return ChangeScoreTrack(timescale: 600, times: [0], scores: [1])
        }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.backend.capturePictures = { _, _, _ in ReferenceThumbnails(frames: []) }
        analysis.analyzeMissing(in: project(ids: [id]))
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
