import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Footage that an edit list leaves out (a late first picture, or a gap in
/// the middle) is not part of the footage: the reader fills it with black
/// samples of its own, and those must not be scored as frames.
@Suite struct EmptySegmentPolicyTests {
    private func range(_ a: Double, _ b: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600), end: CMTime(seconds: b, preferredTimescale: 600))
    }
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    @Test func aSampleInsideAnEmptyStretchIsNotFootage() {
        let empty = EmptySegments(ranges: [range(1, 2)])
        #expect(empty.contains(t(1)))
        #expect(empty.contains(t(1.5)))
        // The end is the first moment of footage.
        #expect(!empty.contains(t(2)))
        #expect(!empty.contains(t(0.95)))
    }

    @Test func aStretchWhollyBetweenTwoFramesSeparatesThem() {
        let empty = EmptySegments(ranges: [range(1, 2)])
        #expect(empty.separates(t(0.958), t(2)))
        #expect(!empty.separates(t(2), t(2.042)))
        #expect(!empty.separates(t(0.5), t(0.542)))
    }

    @Test func aLeadingStretchIsBeforeTheFirstFrameNotBetweenFrames() {
        let empty = EmptySegments(ranges: [range(0, 1)])
        #expect(empty.separates(nil, t(1)))
        #expect(!empty.separates(t(1), t(1.042)))
    }

    @Test func spansAreRecordedInTheTracksTimeUnits() {
        let empty = EmptySegments(ranges: [range(0, 1), range(2, 3)])
        #expect(empty.spans(timescale: 600) == [.init(start: 0, end: 600), .init(start: 1200, end: 1800)])
    }
}

@Suite struct EmptySpanFormatTests {
    private func track(spans: [ChangeScoreTrack.EmptySpan], times: [Int64] = [600, 625, 650]) -> ChangeScoreTrack {
        ChangeScoreTrack(timescale: 600, times: times, scores: [0, 9, 9], emptySpans: spans)
    }

    @Test func spansRoundTrip() throws {
        let original = track(spans: [.init(start: 0, end: 600)])
        #expect(try ChangeScoreTrack(decoding: original.encoded()) == original)
    }

    @Test func aVersionOneFileStillLoadsWithoutSpans() throws {
        // As written before spans existed: header, times, scores, nothing more.
        var data = Data("AMVS".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(1)); append(Int32(24)); append(UInt32(3))
        for time in [0, 1, 2] as [Int64] { append(time) }
        data.append(contentsOf: [0, 5, 7])
        let loaded = try ChangeScoreTrack(decoding: data)
        #expect(loaded.times == [0, 1, 2])
        #expect(loaded.emptySpans.isEmpty)
    }

    @Test func spansThatOverlapOrAreOutOfOrderAreRejected() {
        #expect(throws: ChangeScoreTrackError.self) {
            try ChangeScoreTrack(decoding: track(spans: [.init(start: 0, end: 300), .init(start: 200, end: 500)], times: [600, 625, 650]).encoded())
        }
        #expect(throws: ChangeScoreTrackError.self) {
            try ChangeScoreTrack(decoding: track(spans: [.init(start: 100, end: 100)]).encoded())
        }
    }

    @Test func aFrameInsideAnEmptySpanIsRejected() {
        #expect(throws: ChangeScoreTrackError.self) {
            try ChangeScoreTrack(decoding: track(spans: [.init(start: 0, end: 640)]).encoded())
        }
    }
}

@Suite(.serialized) struct EmptySegmentScoringTests {
    private func cuts(_ track: ChangeScoreTrack, sensitivity: Double = 0.5) -> [Double] {
        SceneDetector.autoCuts(in: track, defaultSensitivity: sensitivity).map(\.seconds)
    }

    @Test func lateBrightFootageStartsAtItsFirstFrameWithNoCut() async throws {
        let frames = SceneFixture.constantRate(count: 48, start: CMTime(value: 1, timescale: 1)) { _ in SceneFixture.gray(150) }
        let (track, duration) = try await SceneFixture.score(frames)

        // No synthetic frame at 0; the first real frame keeps its own timestamp.
        #expect(track.frameCount == 48)
        #expect(track.times[0] == 600)
        #expect(track.scores[0] == 0)
        #expect(track.scores.allSatisfy { $0 < 5 })
        #expect(track.emptySpans == [.init(start: 0, end: 600)])
        // No cut at any sensitivity: the footage simply begins there.
        #expect(cuts(track, sensitivity: 0).isEmpty)
        #expect(cuts(track, sensitivity: 1).isEmpty)
        #expect(abs(duration.seconds - 3.0) < 1e-6)
    }

    @Test func lateFootageStillCutsWhereItReallyCuts() async throws {
        let frames = SceneFixture.constantRate(count: 48, start: CMTime(value: 1, timescale: 1)) {
            $0 < 24 ? SceneFixture.gray(30) : SceneFixture.gray(220)
        }
        let (track, _) = try await SceneFixture.score(frames)
        #expect(cuts(track) == [2.0])
    }

    @Test func lateFootageThatOpensWithRealBlackIsStillFootage() async throws {
        // Black picture after an empty stretch: a real frame, kept, and the
        // cut to bright footage after it is found.
        let frames = SceneFixture.constantRate(count: 48, start: CMTime(value: 1, timescale: 1)) {
            $0 < 24 ? SceneFixture.gray(16) : SceneFixture.gray(220)
        }
        let (track, _) = try await SceneFixture.score(frames)
        #expect(track.frameCount == 48)
        #expect(track.times[0] == 600)
        #expect(cuts(track) == [2.0])
    }

    @Test func zeroStartFootageThatOpensWithBlackKeepsEveryFrame() async throws {
        let frames = SceneFixture.constantRate(count: 48) { $0 < 24 ? SceneFixture.gray(16) : SceneFixture.gray(220) }
        let (track, _) = try await SceneFixture.score(frames)
        #expect(track.frameCount == 48)
        #expect(track.times[0] == 0)
        #expect(track.emptySpans.isEmpty)
        #expect(cuts(track) == [1.0])
    }

    @Test func ordinaryZeroStartFootageIsUnchanged() async throws {
        let frames = SceneFixture.constantRate(count: 48) { $0 < 24 ? SceneFixture.gray(30) : SceneFixture.gray(220) }
        let (track, duration) = try await SceneFixture.score(frames)
        #expect(track.frameCount == 48)
        #expect(track.times.first == 0)
        #expect(track.emptySpans.isEmpty)
        #expect(cuts(track) == [1.0])
        #expect(abs(duration.seconds - 2.0) < 1e-6)
    }

    /// One second of footage, a second with none, one second of footage:
    /// the same two shots, 30 then 220, with the gap between them.
    private func withInternalGap() async throws -> (track: ChangeScoreTrack, duration: CMTime) {
        let source = SceneFixture.tempURL(), output = SceneFixture.tempURL()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        try await SceneFixture.write(SceneFixture.constantRate(count: 48) { $0 < 24 ? SceneFixture.gray(30) : SceneFixture.gray(220) }, to: source)
        let asset = AVURLAsset(url: source)
        let sourceTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let second = CMTime(value: 1, timescale: 1)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: second), of: sourceTrack, at: .zero)
        track.insertEmptyTimeRange(CMTimeRange(start: second, duration: second))
        try track.insertTimeRange(CMTimeRange(start: second, duration: second), of: sourceTrack, at: CMTime(value: 2, timescale: 1))
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.outputURL = output
        session.outputFileType = .mov
        await session.export()
        try #require(session.status == .completed)
        let scored = try await FrameScorer.score(url: output)
        return (scored, try await AVURLAsset(url: output).load(.duration))
    }

    @Test func nothingIsScoredAcrossAnInternalGap() async throws {
        let (track, _) = try await withInternalGap()
        #expect(track.emptySpans == [.init(start: 600, end: 1200)])
        // No frame in the gap.
        #expect(!track.times.contains { $0 >= 600 && $0 < 1200 })
        // The picture jumps from 30 to 220 across the gap; no change is
        // scored for it, and so it is not a cut candidate. The first frame
        // after the gap is a new baseline.
        let after = try #require(track.times.firstIndex { $0 >= 1200 })
        #expect(track.scores[after] == 0)
        #expect(cuts(track).isEmpty)
        #expect(try ChangeScoreTrack(decoding: track.encoded()) == track)
    }

    @Test func anInternalGapIsNotPlayableFootageForScenes() async throws {
        let (track, duration) = try await withInternalGap()
        var project = EditingProject.empty
        let asset = MediaClip(
            name: "Gap", kind: .video, url: nil, duration: duration, frameRate: 24, colorSpace: .rec709, codecName: "Test"
        )
        project.clips = [asset]

        let coverage = try #require(project.sceneCoverage(ofAsset: asset.id, track: track))

        // Two stretches of footage, a gap between that is not endpoint
        // clipping, and no scene across it.
        #expect(coverage.usable.map { [$0.start.seconds, $0.end.seconds] } == [[0, 1], [2, duration.seconds]])
        #expect(coverage.internalGaps.map { [$0.start.seconds, $0.end.seconds] } == [[1, 2]])
        #expect(coverage.uncovered.map { [$0.start.seconds, $0.end.seconds] } == [[1, 2]])
        #expect(coverage.scenes.allSatisfy { $0.end.seconds <= 1.0001 || $0.start.seconds >= 1.9999 })
    }

    @Test func aLateStartIsLeadingUncoveredTimeNotAnInternalGap() async throws {
        let frames = SceneFixture.constantRate(count: 48, start: CMTime(value: 1, timescale: 1)) { _ in SceneFixture.gray(150) }
        let (track, duration) = try await SceneFixture.score(frames)
        var project = EditingProject.empty
        let asset = MediaClip(name: "Late", kind: .video, url: nil, duration: duration, frameRate: 24, colorSpace: .rec709, codecName: "Test")
        project.clips = [asset]

        let coverage = try #require(project.sceneCoverage(ofAsset: asset.id, track: track))

        #expect(coverage.usable.map { [$0.start.seconds, $0.end.seconds] } == [[1, 3]])
        #expect(coverage.uncovered.map { [$0.start.seconds, $0.end.seconds] } == [[0, 1]])
        #expect(coverage.internalGaps.isEmpty)
        #expect(coverage.scenes.first?.start.seconds == 1)
    }
}

@Suite struct ScoreAlgorithmCompatibilityTests {
    private let stamp = FileStamp(byteCount: 100, modified: 1)
    private let track = ChangeScoreTrack(timescale: 600, times: [0, 25], scores: [0, 200])

    private func makePackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-algo-\(UUID().uuidString).amv")
        try ProjectStore.preparePackage(at: package)
        return package
    }

    private func setAlgorithm(_ id: UUID, _ kind: AnalysisKind, in package: URL, to value: Int) throws {
        let url = ProjectStore.referenceFolder(for: id, in: package).appending(path: ProjectStore.provenanceFileName)
        var raw = try JSONDecoder().decode([String: AnalysisProvenance].self, from: Data(contentsOf: url))
        raw[kind.rawValue]?.algorithm = value
        try JSONEncoder().encode(raw).write(to: url)
    }

    @Test func currentFileScoresFromTheEarlierAlgorithmAreMadeAgain() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeChangeScores(track, for: id, in: package, source: stamp)
        try setAlgorithm(id, .scores, in: package, to: 1)

        guard case .rejected(.differentAlgorithm) = ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stamp) else {
            Issue.record("scores with the false first cut were kept")
            return
        }
    }

    @Test func theOriginalsScoresFromTheEarlierAlgorithmStayUsable() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeOriginalScores(track, for: id, in: package, source: stamp)
        try setAlgorithm(id, .originalScores, in: package, to: 1)

        #expect(ProjectStore.readVerifiedOriginalScores(for: id, in: package).value == track)
    }

    @Test func aFutureAlgorithmIsNotUsedForTheOriginalEither() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeOriginalScores(track, for: id, in: package, source: stamp)
        try setAlgorithm(id, .originalScores, in: package, to: 3)

        guard case .rejected(.differentAlgorithm) = ProjectStore.readVerifiedOriginalScores(for: id, in: package) else {
            Issue.record("accepted an algorithm from the future")
            return
        }
    }

    @Test func missingDamagedAndIncompatibleOriginalsAreToldApart() {
        #expect(AnalysisRejection.damaged.originalScoresReason == .damaged)
        #expect(AnalysisRejection.differentSettings.originalScoresReason == .incompatible)
        #expect(AnalysisRejection.differentAlgorithm.originalScoresReason == .incompatible)
        #expect(AnalysisRejection.noProvenance.originalScoresReason == .unverified)
        #expect(AnalysisRejection.differentFile.originalScoresReason == .unverified)
        let sentences = [OriginalScoresUnavailable.forgotten, .notCaptured, .damaged, .incompatible, .unverified].map(\.sentence)
        #expect(Set(sentences).count == 5)
    }

    @MainActor
    @Test func aSavedButUnusableOriginalIsReportedAsThatNotAsMissing() async throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeOriginalScores(track, for: id, in: package, source: stamp)
        // Damage the file so its record no longer fits.
        try Data("garbage".utf8).write(to: ProjectStore.referenceFolder(for: id, in: package).appending(path: ProjectStore.originalScoresFileName))

        var project = EditingProject.empty
        var clip = MediaClip(
            name: "a", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: CMTime(seconds: 4, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Test", acceptedStamp: stamp
        )
        clip.id = id
        clip.previousPaths = ["/elsewhere"]
        project.clips = [clip]
        let analysis = AssetAnalysis()
        analysis.backend.scoreFrames = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.backend.observeFile = { _ in AssetAnalysis.FileObservation(exists: true, stamp: FileStamp(byteCount: 100, modified: 1)) }
        analysis.reset(packageURL: package)
        analysis.update(with: project)
        for _ in 0..<2000 where analysis.isLoadingSaved { try await Task.sleep(for: .milliseconds(2)) }

        #expect(analysis.resolveOriginalScores(for: clip) == .failure(.damaged))
    }
}
