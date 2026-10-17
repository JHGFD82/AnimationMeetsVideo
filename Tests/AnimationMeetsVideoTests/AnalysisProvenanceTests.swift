import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct AnalysisProvenanceTests {
    private let stamp = FileStamp(byteCount: 100, modified: 1)
    private let other = FileStamp(byteCount: 200, modified: 2)
    private let track = ChangeScoreTrack(timescale: 600, times: [0, 25], scores: [0, 200])
    private let beats = BeatTrack(timescale: 1000, times: [100, 600], beatsPerMinute: 120)

    private func makePackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-prov-\(UUID().uuidString).amv")
        try ProjectStore.preparePackage(at: package)
        return package
    }

    private func folder(_ id: UUID, _ package: URL) -> URL { ProjectStore.referenceFolder(for: id, in: package) }

    private func rewriteProvenance(_ id: UUID, in package: URL, _ change: (inout [String: AnalysisProvenance]) -> Void) throws {
        let url = folder(id, package).appending(path: ProjectStore.provenanceFileName)
        var raw = try JSONDecoder().decode([String: AnalysisProvenance].self, from: Data(contentsOf: url))
        change(&raw)
        try JSONEncoder().encode(raw).write(to: url)
    }

    private func rejection<Value>(_ result: CachedResult<Value>) -> AnalysisRejection? {
        if case .rejected(let reason) = result { return reason }
        return nil
    }

    @Test func aResultMatchingItsRecordIsUsed() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeChangeScores(track, for: id, in: package, source: stamp)
        try ProjectStore.writeBeats(beats, for: id, in: package, source: stamp)

        #expect(ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stamp).value == track)
        #expect(ProjectStore.readVerifiedBeats(for: id, in: package, identity: stamp).value == beats)
    }

    @Test func resultsWithoutARecordAreRejectedNotAssumedCurrent() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeChangeScores(track, for: id, in: package)
        try ProjectStore.writeBeats(beats, for: id, in: package)

        #expect(rejection(ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stamp)) == .noProvenance)
        #expect(rejection(ProjectStore.readVerifiedBeats(for: id, in: package, identity: stamp)) == .noProvenance)
    }

    @Test func resultsFromAReplacedFileAreRejected() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeChangeScores(track, for: id, in: package, source: stamp)
        try ProjectStore.writeBeats(beats, for: id, in: package, source: stamp)

        #expect(rejection(ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: other)) == .differentFile)
        #expect(rejection(ProjectStore.readVerifiedBeats(for: id, in: package, identity: other)) == .differentFile)
    }

    @Test func aMissingStampOnEitherSideMeansUnverifiable() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeChangeScores(track, for: id, in: package, source: nil)
        #expect(rejection(ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stamp)) == .unverifiable)

        try ProjectStore.writeChangeScores(track, for: id, in: package, source: stamp)
        #expect(rejection(ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: nil)) == .unverifiable)
    }

    @Test func changedSettingsOrAlgorithmRetireTheCache() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeChangeScores(track, for: id, in: package, source: stamp)
        try ProjectStore.writeBeats(beats, for: id, in: package, source: stamp)

        try rewriteProvenance(id, in: package) { $0["scores"]?.settings = "sample=32x18" }
        try rewriteProvenance(id, in: package) { $0["beats"]?.algorithm = 0 }

        #expect(rejection(ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stamp)) == .differentSettings)
        #expect(rejection(ProjectStore.readVerifiedBeats(for: id, in: package, identity: stamp)) == .differentAlgorithm)
    }

    @Test func aResultFileThatIsNotTheOneRecordedIsRejected() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeChangeScores(track, for: id, in: package, source: stamp)
        // As if a newer result was written but its record never was.
        try ProjectStore.writeChangeScores(ChangeScoreTrack(timescale: 600, times: [0], scores: [9]), for: id, in: package)

        #expect(rejection(ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stamp)) == .damaged)
    }

    @Test func invalidatingDeletesTheFile() throws {
        let package = try makePackage(), id = UUID()
        defer { try? FileManager.default.removeItem(at: package) }
        try ProjectStore.writeChangeScores(track, for: id, in: package, source: stamp)

        try ProjectStore.invalidate(.scores, for: id, in: package)

        #expect(ProjectStore.readChangeScores(for: id, in: package) == nil)
        guard case .absent = ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stamp) else {
            Issue.record("expected the result to be gone")
            return
        }
    }

    @Test func aFileThatCannotBeDeletedIsRetiredByItsRecord() throws {
        let package = try makePackage(), id = UUID()
        let file = folder(id, package).appending(path: ProjectStore.changeScoreFileName)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: package)
        }
        try ProjectStore.writeChangeScores(track, for: id, in: package, source: stamp)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)

        try ProjectStore.invalidate(.scores, for: id, in: package)

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(rejection(ProjectStore.readVerifiedChangeScores(for: id, in: package, identity: stamp)) == .invalidated)
    }

    @Test func retiringFailsLoudlyWhenNeitherDeletionNorTheRecordCanBeDone() throws {
        let package = try makePackage(), id = UUID()
        let directory = folder(id, package)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: package)
        }
        try ProjectStore.writeChangeScores(track, for: id, in: package, source: stamp)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        #expect(throws: ProvenanceError.self) { try ProjectStore.invalidate(.scores, for: id, in: package) }
    }

    @Test func loadingSkipsRejectedResultsAndSaysWhy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-prov-load-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "song.wav")
        try Data("not really audio".utf8).write(to: media)
        let package = root.appending(path: "Test.amv", directoryHint: .isDirectory)
        var project = EditingProject.empty
        let asset = MediaClip(
            name: "song.wav", kind: .audio, url: media,
            duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "Stub", hasAudio: true
        )
        _ = project.importClip(asset, intoTimeline: project.rootTimelineID)
        let importer: @Sendable (URL) async throws -> MediaClip = { url in
            MediaClip(
                name: url.lastPathComponent, kind: .audio, url: url,
                duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 0,
                colorSpace: .rec709, codecName: "Stub", hasAudio: true
            )
        }
        let id = asset.id
        // Beats from the file as it was; scores with no record at all.
        try await ProjectStore.save(project, to: package, beats: [id: beats], sources: AnalysisSources(beats: [id: other]))
        try ProjectStore.writeChangeScores(track, for: id, in: package)

        let loaded = try await ProjectStore.load(from: package, importMedia: importer)

        #expect(loaded.beats[id] == nil)
        #expect(loaded.changeScores[id] == nil)
        #expect(loaded.rejectedAnalysis[id]?[.beats] == .differentFile)
        #expect(loaded.rejectedAnalysis[id]?[.scores] == .noProvenance)
    }

    @Test func copyingMediaIntoAPackageKeepsItsIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-prov-copy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "clip.mov")
        try Data(repeating: 7, count: 4096).write(to: media)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.25)], ofItemAtPath: media.path)
        let package = root.appending(path: "Test.amv", directoryHint: .isDirectory)
        try ProjectStore.preparePackage(at: package)

        let copy = try ProjectStore.copyIntoPackage(media, packageURL: package)

        #expect(FileStamp(url: copy) == FileStamp(url: media))
    }
}
