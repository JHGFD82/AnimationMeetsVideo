import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The scores of the original footage are reference data: kept separately
/// from the scores of the file in use, so a replacement can be aligned to
/// the original however many files the asset has had since.
@MainActor
@Suite struct OriginalScoresTests {
    private let stampA = FileStamp(byteCount: 100, modified: 1)
    private let stampB = FileStamp(byteCount: 200, modified: 2)
    private let stampC = FileStamp(byteCount: 300, modified: 3)

    private func track(_ marker: UInt8) -> ChangeScoreTrack {
        ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, marker])
    }

    private func project(stamp: FileStamp) -> (EditingProject, UUID) {
        var project = EditingProject.empty
        let clip = MediaClip(
            name: "a.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"),
            duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 24, colorSpace: .rec709,
            codecName: "Test", acceptedStamp: stamp
        )
        project.clips = [clip]
        return (project, clip.id)
    }

    private func replacement(url: String, stamp: FileStamp) -> MediaClip {
        MediaClip(
            name: "b.mov", kind: .video, url: URL(fileURLWithPath: url),
            duration: CMTime(seconds: 12, preferredTimescale: 600), frameRate: 24, colorSpace: .rec709,
            codecName: "Test", acceptedStamp: stamp
        )
    }

    /// Scores by file path: each file gets a track marked with its own number.
    private func scoring(_ analysis: AssetAnalysis, marks: [String: UInt8]) {
        analysis.backend.scoreFrames = { url, _ in
            ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, marks[url.path] ?? 99])
        }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.backend.capturePictures = { _, _, _ in ReferenceThumbnails(frames: []) }
        analysis.backend.observeFile = { url in
            let stamp: FileStamp? = url.path == "/dev/null" ? FileStamp(byteCount: 100, modified: 1)
                : url.path == "/etc/hosts" ? FileStamp(byteCount: 200, modified: 2) : FileStamp(byteCount: 300, modified: 3)
            return AssetAnalysis.FileObservation(exists: true, stamp: stamp)
        }
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("condition never held")
    }

    private func makePackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-orig-\(UUID().uuidString).amv")
        try ProjectStore.preparePackage(at: package)
        return package
    }

    // MARK: Capture

    @Test func theOriginalsScoresAreSetAsideWhileTheOriginalIsTheFile() async throws {
        let (project, id) = project(stamp: stampA)
        let analysis = AssetAnalysis()
        scoring(analysis, marks: ["/dev/null": 11])
        analysis.update(with: project)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }

        #expect(analysis.originalScores[id] == track(11))
        #expect(analysis.unsavedResults().originalScoreTracks[id] == track(11))
        #expect(analysis.unsavedResults().sources.originalScores[id] == stampA)
    }

    @Test func scoresOfAReplacementAreNeverLabeledOriginal() async throws {
        var (project, id) = project(stamp: stampA)
        // Replaced before the original's scores were ever set aside.
        project.replaceMedia(id: id, with: replacement(url: "/etc/hosts", stamp: stampB), offset: CMTime(value: 1, timescale: 1))
        let analysis = AssetAnalysis()
        scoring(analysis, marks: ["/etc/hosts": 22])
        analysis.update(with: project)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }

        #expect(analysis.tracks[id] == track(22))
        #expect(analysis.originalScores[id] == nil)
        #expect(analysis.resolveOriginalScores(for: project.clips[0]) == .failure(.notCaptured))
    }

    @Test func redetectingChangesTheCurrentScoresNotTheOriginals() async throws {
        let (project, id) = project(stamp: stampA)
        let analysis = AssetAnalysis()
        let marks = Mutex(10)
        analysis.backend.scoreFrames = { _, _ in ChangeScoreTrack(timescale: 600, times: [0, 1], scores: [0, UInt8(marks.increment())]) }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.backend.capturePictures = { _, _, _ in ReferenceThumbnails(frames: []) }
        analysis.backend.observeFile = { _ in AssetAnalysis.FileObservation(exists: true, stamp: FileStamp(byteCount: 100, modified: 1)) }
        analysis.update(with: project)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }
        let original = analysis.originalScores[id]

        analysis.reanalyze(project.clips[0], in: project)
        try await settle { analysis.tracks[id] == track(12) && analysis.progress.isEmpty }

        #expect(analysis.originalScores[id] == original)
        #expect(original == track(11))
    }

    // MARK: Replacement

    @Test func afterTheFirstReplacementTheOriginalsScoresAreStillTheOriginals() async throws {
        var (project, id) = project(stamp: stampA)
        let analysis = AssetAnalysis()
        scoring(analysis, marks: ["/dev/null": 11, "/etc/hosts": 22, "/etc/shells": 33])
        analysis.update(with: project)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }

        project.replaceMedia(id: id, with: replacement(url: "/etc/hosts", stamp: stampB), offset: CMTime(value: 1, timescale: 1))
        analysis.update(with: project)
        try await settle { analysis.tracks[id] == track(22) && analysis.progress.isEmpty }
        #expect(analysis.resolveOriginalScores(for: project.clips[0]) == .success(track(11)))

        // A second replacement, with another offset, still points at the original.
        project.replaceMedia(id: id, with: replacement(url: "/etc/shells", stamp: stampC), offset: CMTime(value: 1, timescale: 2))
        analysis.update(with: project)
        try await settle { analysis.tracks[id] == track(33) && analysis.progress.isEmpty }
        #expect(analysis.resolveOriginalScores(for: project.clips[0]) == .success(track(11)))
        #expect(analysis.originalScores[id] == track(11))
    }

    @Test func aReplacementChosenBeforeTheScoresWereSetAsideKeepsThemAsTheOriginals() async throws {
        let (project, id) = project(stamp: stampA)
        let analysis = AssetAnalysis()
        scoring(analysis, marks: ["/dev/null": 11])
        analysis.update(with: project)
        try await settle { analysis.tracks[id] != nil && analysis.progress.isEmpty }
        // As if they were read from a package saved without original scores.
        analysis.reset(tracks: [id: track(11)], sources: AnalysisSources(scores: [id: stampA]))

        #expect(analysis.originalScores[id] == nil)
        #expect(analysis.resolveOriginalScores(for: project.clips[0]) == .success(track(11)))
        #expect(analysis.originalScores[id] == track(11))
    }

    // MARK: Alignment against real files

    private func movie(_ prefixFrames: Int) async throws -> URL {
        // Four shots of different lengths (cuts at 1.0, 2.5 and 3.25 s, so no
        // other offset lines them up), after `prefixFrames` of flat gray:
        // every cut is later by that many frames.
        let url = SceneFixture.tempURL()
        var frames = SceneFixture.constantRate(count: prefixFrames) { _ in SceneFixture.gray(128) }
        let lengths = [24, 36, 18, 30], grays = [30, 220, 90, 180]
        var starts: [Int] = []
        var total = 0
        for length in lengths { starts.append(total); total += length }
        let shotStarts = starts
        frames += SceneFixture.constantRate(prefixFrames, count: total) { index in
            let local = index - prefixFrames
            let shot = shotStarts.lastIndex { $0 <= local } ?? 0
            return SceneFixture.gray(grays[shot])
        }
        try await SceneFixture.write(frames, to: url)
        return url
    }

    private func analyze(_ candidate: URL, original: URL, asset: MediaClip, scores: Result<ChangeScoreTrack, OriginalScoresUnavailable>) async throws -> ReplacementAnalysis {
        let reference = try await ReferenceCapture.capture(url: original)
        return try await MediaReplacer.analyze(
            candidate: candidate, replacing: asset, reference: reference, originalScores: scores, usedRanges: [], packageURL: nil
        )
    }

    @Test func eachReplacementIsAlignedToTheOriginalNotToThePreviousReplacement() async throws {
        let original = try await movie(0)
        let first = try await movie(24)     // 1 s later than the original
        let second = try await movie(12)    // 0.5 s later than the original
        defer { for url in [original, first, second] { try? FileManager.default.removeItem(at: url) } }
        let originalScores = try await FrameScorer.score(url: original)
        let firstScores = try await FrameScorer.score(url: first)
        var asset = MediaClip(
            name: "a", kind: .video, url: original, duration: CMTime(seconds: 4, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Test"
        )

        let one = try await analyze(first, original: original, asset: asset, scores: .success(originalScores))
        #expect(abs(one.proposedOffset.seconds - 1.0) <= 1.0 / 24)

        // The asset now points at the first replacement, offset 1 s.
        asset.alignmentOffset = one.proposedOffset
        asset.previousPaths = [original.path]
        asset.url = first
        let two = try await analyze(second, original: original, asset: asset, scores: .success(originalScores))
        // Original time t is at t + 0.5 s in the second file.
        #expect(abs(two.proposedOffset.seconds - 0.5) <= 1.0 / 24)

        // Taking the first replacement's scores for the original's, as the
        // asset's own scores would be, gives the offset between the two
        // replacements instead: not a mapping from the original at all.
        let wrong = try await analyze(second, original: original, asset: asset, scores: .success(firstScores))
        #expect(abs(wrong.proposedOffset.seconds - (-0.5)) <= 1.0 / 24)
    }

    @Test func withoutTheOriginalsScoresNothingIsMadeUpFromTheReplacement() async throws {
        let original = try await movie(0)
        let candidate = try await movie(12)
        defer { for url in [original, candidate] { try? FileManager.default.removeItem(at: url) } }
        let asset = MediaClip(
            name: "a", kind: .video, url: original, duration: CMTime(seconds: 4, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Test"
        )

        let result = try await analyze(candidate, original: original, asset: asset, scores: .failure(.notCaptured))

        #expect(result.suggestion == nil)
        #expect(result.cutMatchingUnavailable == .notCaptured)
        // The fixtures have no sound, so none was compared and none is claimed.
        #expect(!result.audioWasCompared)
        let message = try #require(result.alignmentLimitation)
        #expect(!message.contains("judged by sound alone"))
        #expect(message.contains("could not be established"))
        #expect(result.proposedOffset == asset.alignmentOffset)
    }

    @Test func aForgottenOriginalReportsWhyCutsCannotBeMatched() async throws {
        let original = try await movie(0)
        let candidate = try await movie(12)
        defer { for url in [original, candidate] { try? FileManager.default.removeItem(at: url) } }
        let asset = MediaClip(
            name: "a", kind: .video, url: original, duration: CMTime(seconds: 4, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Test"
        )
        let result = try await analyze(candidate, original: original, asset: asset, scores: .failure(.forgotten))
        #expect(result.cutMatchingUnavailable == .forgotten)
    }

    // MARK: Saving, reopening, forgetting

    private func savedPackage() async throws -> (root: URL, package: URL, project: EditingProject, id: UUID) {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-orig-save-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appending(path: "footage.mov")
        try Data("not really video".utf8).write(to: media)
        var project = EditingProject.empty
        let asset = MediaClip(
            name: "footage.mov", kind: .video, url: media, duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub", acceptedStamp: FileStamp(url: media)
        )
        _ = project.importClip(asset, intoTimeline: project.rootTimelineID)
        return (root, root.appending(path: "Test.amv", directoryHint: .isDirectory), project, asset.id)
    }

    private static let stubImporter: @Sendable (URL) async throws -> MediaClip = { url in
        MediaClip(
            name: url.lastPathComponent, kind: .video, url: url, duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
    }

    @Test func theOriginalsScoresSurviveSavingAndReopeningAndStillAlignAReplacement() async throws {
        let (root, package, saved, id) = try await savedPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = saved
        let stamp = try #require(project.clips[0].acceptedStamp)
        try await ProjectStore.save(
            project, to: package, originalScores: [id: track(11)],
            sources: AnalysisSources(originalScores: [id: stamp])
        )
        // Replaced after that, and saved again with no scores to write.
        project.replaceMedia(id: id, with: replacement(url: root.appending(path: "footage.mov").path, stamp: stampB), offset: CMTime(value: 1, timescale: 1))
        project.clips[0].previousPaths = ["/elsewhere/original.mov"]
        try await ProjectStore.save(project, to: package)

        let loaded = try await ProjectStore.load(from: package, importMedia: Self.stubImporter)
        #expect(loaded.originalScores[id] == track(11))
        #expect(loaded.analysisSources.originalScores[id] == stamp)

        let analysis = AssetAnalysis()
        analysis.reset(
            tracks: loaded.changeScores, originalScores: loaded.originalScores,
            sources: loaded.analysisSources, packageURL: package
        )
        #expect(analysis.resolveOriginalScores(for: loaded.project.clips[0]) == .success(track(11)))
    }

    @Test func originalScoresWithoutARecordOfTheOriginalAreNotTrusted() async throws {
        let (root, package, project, id) = try await savedPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.save(project, to: package)
        // A file with no record at all.
        try FileManager.default.createDirectory(at: ProjectStore.referenceFolder(for: id, in: package), withIntermediateDirectories: true)
        try track(11).encoded().write(to: ProjectStore.referenceFolder(for: id, in: package).appending(path: ProjectStore.originalScoresFileName))

        let loaded = try await ProjectStore.load(from: package, importMedia: Self.stubImporter)
        #expect(loaded.originalScores[id] == nil)
        #expect(loaded.rejectedAnalysis[id]?[.originalScores] == .noProvenance)
    }

    @Test func originalScoresThatNameADifferentFileThanTheSavedOriginalAreRejected() async throws {
        let (root, package, project, id) = try await savedPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = AssetReference(
            metadata: AssetMetadataSnapshot(
                fileName: "footage.mov", originalPath: "/x", byteCount: 100, modified: 1, isVideo: true,
                durationValue: 600, durationTimescale: 600, frameRate: 24, width: 16, height: 16,
                codecName: "Test", audioSampleRate: nil, capturedAt: 0
            ),
            audioEnvelope: nil
        )
        try await ProjectStore.save(
            project, to: package, references: [id: reference], originalScores: [id: track(11)],
            sources: AnalysisSources(originalScores: [id: stampB])
        )

        guard case .rejected(.differentFile) = ProjectStore.readVerifiedOriginalScores(for: id, in: package) else {
            Issue.record("scores of another file were accepted as the original's")
            return
        }
    }

    @Test func forgettingTheOriginalDeletesItsScoresAndTheyAreNotUsed() async throws {
        let (root, package, saved, id) = try await savedPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = saved
        let stamp = try #require(project.clips[0].acceptedStamp)
        try await ProjectStore.save(
            project, to: package, originalScores: [id: track(11)], sources: AnalysisSources(originalScores: [id: stamp])
        )
        let analysis = AssetAnalysis()
        let loaded = try await ProjectStore.load(from: package, importMedia: Self.stubImporter)
        analysis.reset(originalScores: loaded.originalScores, sources: loaded.analysisSources, packageURL: package)
        #expect(analysis.resolveOriginalScores(for: project.clips[0]) == .success(track(11)))

        project.markReferenceForgotten(forAsset: id)
        // Kept until a save, so undoing the forget loses nothing, but not used.
        #expect(analysis.resolveOriginalScores(for: project.clips[0]) == .failure(.forgotten))

        let result = try await ProjectStore.save(project, to: package)
        analysis.dropForgottenReferences(in: result)
        #expect(analysis.originalScores[id] == nil)
        #expect(analysis.unsavedResults().originalScoreTracks.isEmpty)
        let file = ProjectStore.referenceFolder(for: id, in: package).appending(path: ProjectStore.originalScoresFileName)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let reloaded = try await ProjectStore.load(from: package, importMedia: Self.stubImporter)
        #expect(reloaded.originalScores[id] == nil)
        #expect(reloaded.project.clips[0].referenceForgotten)
    }

    @Test func aForgottenOriginalIsNotWrittenAgainBySaving() async throws {
        let (root, package, saved, id) = try await savedPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = saved
        project.markReferenceForgotten(forAsset: id)
        let stamp = try #require(project.clips[0].acceptedStamp)

        try await ProjectStore.save(
            project, to: package, originalScores: [id: track(11)], sources: AnalysisSources(originalScores: [id: stamp])
        )

        let file = ProjectStore.referenceFolder(for: id, in: package).appending(path: ProjectStore.originalScoresFileName)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theCurrentFilesScoresStayWhenTheOriginalIsForgotten() async throws {
        let (root, package, saved, id) = try await savedPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = saved
        let stamp = try #require(project.clips[0].acceptedStamp)
        try await ProjectStore.save(
            project, to: package, changeScores: [id: track(7)], originalScores: [id: track(7)],
            sources: AnalysisSources(scores: [id: stamp], originalScores: [id: stamp])
        )
        project.markReferenceForgotten(forAsset: id)
        try await ProjectStore.save(project, to: package)

        let loaded = try await ProjectStore.load(from: package, importMedia: Self.stubImporter)
        #expect(loaded.changeScores[id] == track(7))
        #expect(loaded.originalScores[id] == nil)
    }

    @Test func theLimitationOnlyClaimsASoundComparisonThatHappened() {
        let compared = ReplacementAnalysis.limitation(.forgotten, audioWasCompared: true)
        let none = ReplacementAnalysis.limitation(.forgotten, audioWasCompared: false)
        #expect(compared.contains("judged by sound alone"))
        #expect(!none.contains("judged by sound alone"))
        #expect(none.contains("Set it by hand"))
        for reason in [OriginalScoresUnavailable.forgotten, .notCaptured, .damaged, .incompatible, .unverified] {
            #expect(ReplacementAnalysis.limitation(reason, audioWasCompared: true).hasPrefix(reason.sentence))
        }
    }
}
