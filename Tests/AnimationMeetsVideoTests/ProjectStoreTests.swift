import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A scratch directory with a fake media file and a package location.
private struct Sandbox {
    let root: URL
    let mediaURL: URL
    let packageURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "amv-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        mediaURL = root.appending(path: "footage.mov")
        try Data("not really video".utf8).write(to: mediaURL)
        packageURL = root.appending(path: "Test.amv", directoryHint: .isDirectory)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    var projectJSON: URL { packageURL.appending(path: ProjectStore.projectFileName) }

    /// Stands in for `MediaImporter` so tests need no real footage.
    static let stubImporter: @Sendable (URL) async throws -> MediaClip = { url in
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return MediaClip(
            name: url.lastPathComponent,
            kind: .video,
            url: url,
            duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24,
            colorSpace: .rec709,
            codecName: "Stub"
        )
    }

    /// A project with one asset pointing at `mediaURL` and one clip using it,
    /// trimmed to an NTSC frame boundary that has no exact decimal form.
    func makeProject() -> (project: EditingProject, clipID: UUID, assetID: UUID) {
        var project = EditingProject.empty
        let asset = MediaClip(
            name: "footage.mov",
            kind: .video,
            url: mediaURL,
            duration: CMTime(seconds: 10, preferredTimescale: 600),
            frameRate: 24,
            colorSpace: .rec709,
            codecName: "Stub"
        )
        let ids = project.importClip(asset, intoTimeline: project.rootTimelineID)!
        let t = project.timelines.firstIndex { $0.id == project.rootTimelineID }!
        let l = project.timelines[t].layers.firstIndex { $0.id == ids.layerID }!
        let c = project.timelines[t].layers[l].clips.firstIndex { $0.id == ids.clipID }!
        project.timelines[t].layers[l].clips[c].trimStart = CMTime(value: 1001, timescale: 24000)
        project.timelines[t].layers[l].clips[c].startOffset = CMTime(value: 2002, timescale: 24000)
        return (project, ids.clipID, asset.id)
    }
}

@Suite struct ProjectStoreTests {
    @Test func roundTripKeepsStableIDsAndExactTimes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, clipID, assetID) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.missingMedia.isEmpty)
        #expect(loaded.project.id == project.id)
        #expect(loaded.project.rootTimelineID == project.rootTimelineID)
        #expect(loaded.project.clips.map(\.id) == [assetID])

        let timeline = try #require(loaded.project.timeline(id: project.rootTimelineID))
        let layer = try #require(timeline.layers.first)
        #expect(layer.id == project.timelines[0].layers[0].id)
        let clip = try #require(layer.clips.first { $0.id == clipID })
        #expect(clip.trimStart == CMTime(value: 1001, timescale: 24000))
        #expect(clip.startOffset == CMTime(value: 2002, timescale: 24000))
    }

    @Test func savingTwiceProducesIdenticalBytes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let first = try Data(contentsOf: sandbox.projectJSON)
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let second = try Data(contentsOf: sandbox.projectJSON)

        #expect(first == second)
        #expect(first.last == 0x0A)
    }

    @Test func writesTimesAsRationalStrings() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        #expect(text.contains("\"1001/24000s\""))
        #expect(text.contains("\"formatVersion\" : 1"))
    }

    @Test func acceptsHandWrittenWholeSecondTimes() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, clipID, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let edited = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
            .replacingOccurrences(of: "\"1001/24000s\"", with: "\"3s\"")
        try edited.write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        let clip = try #require(loaded.project.timelines[0].layers[0].clips.first { $0.id == clipID })
        #expect(clip.trimStart == CMTime(value: 3, timescale: 1))
    }

    @Test func rejectsMalformedTime() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let edited = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
            .replacingOccurrences(of: "\"1001/24000s\"", with: "\"soon\"")
        try edited.write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)

        await #expect(throws: ProjectStoreError.self) {
            try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        }
    }

    @Test func rejectsNewerAndMissingFormatVersions() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let original = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        try original
            .replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
            .write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)
        await #expect(throws: ProjectStoreError.self) {
            try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        }

        try original
            .replacingOccurrences(of: "\"formatVersion\" : 1,", with: "")
            .write(to: sandbox.projectJSON, atomically: true, encoding: .utf8)
        await #expect(throws: ProjectStoreError.self) {
            try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        }
    }

    @Test func rejectsFolderWithoutProjectFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        await #expect(throws: ProjectStoreError.self) {
            try await ProjectStore.load(from: sandbox.root, importMedia: Sandbox.stubImporter)
        }
    }

    @Test func createsPackageLayoutAndIgnoreFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)

        for folder in ["Media", "Reference", "Cache", "Backups"] {
            var isDirectory: ObjCBool = false
            let path = sandbox.packageURL.appending(path: folder).path
            #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
        let ignore = try String(contentsOf: sandbox.packageURL.appending(path: ".gitignore"), encoding: .utf8)
        #expect(ignore.contains("Cache/"))
    }

    @Test func copiedMediaIsStoredWithRelativePath() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()

        try ProjectStore.preparePackage(at: sandbox.packageURL)
        let candidates = ProjectStore.mediaToCopy(in: project, into: sandbox.packageURL)
        #expect(candidates.map(\.clipID) == [assetID])
        #expect(candidates.first?.byteCount == 16)

        let saved = try await ProjectStore.save(project, to: sandbox.packageURL, copying: [assetID])
        let copiedURL = try #require(saved.clips.first?.url)
        #expect(copiedURL.deletingLastPathComponent().lastPathComponent == "Media")
        #expect(FileManager.default.fileExists(atPath: copiedURL.path))
        #expect(FileManager.default.fileExists(atPath: sandbox.mediaURL.path))

        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        #expect(text.contains("\"Media/footage.mov\""))
        #expect(ProjectStore.mediaToCopy(in: saved, into: sandbox.packageURL).isEmpty)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.project.clips.first?.url?.lastPathComponent == "footage.mov")
        #expect(loaded.project.clips.first?.url?.deletingLastPathComponent().lastPathComponent == "Media")
    }

    @Test func copyingNeverOverwritesExistingMediaFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()

        try ProjectStore.preparePackage(at: sandbox.packageURL)
        let existing = sandbox.packageURL.appending(path: "Media/footage.mov")
        try Data("other".utf8).write(to: existing)

        let saved = try await ProjectStore.save(project, to: sandbox.packageURL, copying: [assetID])

        #expect(saved.clips.first?.url?.lastPathComponent == "footage 2.mov")
        #expect(try Data(contentsOf: existing) == Data("other".utf8))
    }

    @Test func referencedMediaOutsidePackageKeepsAbsolutePath() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        #expect(text.contains(sandbox.mediaURL.path))
    }

    @Test func missingMediaIsReportedAndItsClipsDropped() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        try FileManager.default.removeItem(at: sandbox.mediaURL)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.missingMedia.count == 1)
        #expect(loaded.project.clips.isEmpty)
        #expect(loaded.project.timelines[0].layers.allSatisfy { $0.clips.isEmpty })
    }

    @Test func packageURLAcceptsPackageOrProjectFile() {
        let package = URL(fileURLWithPath: "/tmp/My.amv", isDirectory: true)
        let file = package.appending(path: ProjectStore.projectFileName)
        #expect(ProjectStore.packageURL(forSelection: package) == package)
        #expect(ProjectStore.packageURL(forSelection: file).path == package.path)
    }

    @Test func backupGoesToBackupsFolderAndLeavesProjectFileAlone() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let savedBytes = try Data(contentsOf: sandbox.projectJSON)

        var edited = project
        edited.name = "Edited since save"
        let backup = try ProjectStore.writeBackup(of: edited, in: sandbox.packageURL)

        #expect(backup.deletingLastPathComponent().lastPathComponent == "Backups")
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("Edited since save"))
        #expect(try Data(contentsOf: sandbox.projectJSON) == savedBytes)
    }

    @Test func backupIsALoadablePackageFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)

        var edited = project
        edited.name = "Recovered"
        let backup = try ProjectStore.writeBackup(of: edited, in: sandbox.packageURL)
        try FileManager.default.removeItem(at: sandbox.projectJSON)
        try FileManager.default.copyItem(at: backup, to: sandbox.projectJSON)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.project.name == "Recovered")
    }

    @Test func oldestBackupsArePrunedBeyondTheLimit() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        for second in 0..<5 {
            try ProjectStore.writeBackup(
                of: project,
                in: sandbox.packageURL,
                now: Date(timeIntervalSince1970: 1_700_000_000 + Double(second)),
                keeping: 3
            )
        }

        let folder = sandbox.packageURL.appending(path: "Backups")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names.count == 3)
        let newest = ProjectStore.backupPrefix
        #expect(names.allSatisfy { $0.hasPrefix(newest) })

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let kept = (2..<5).map { "\(newest)\(formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))).json" }
        #expect(names == kept)
    }

    @Test func applyingMediaLocationsKeepsOtherEdits() {
        var live = EditingProject.empty
        let media = MediaClip(
            name: "A", kind: .video, url: URL(fileURLWithPath: "/old/a.mov"),
            duration: .init(seconds: 1, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
        live.clips = [media]
        var saved = live
        saved.clips[0].url = URL(fileURLWithPath: "/package/Media/a.mov")

        live.name = "Edited while saving"
        live.applyMediaLocations(from: saved)

        #expect(live.name == "Edited while saving")
        #expect(live.clips[0].url?.path == "/package/Media/a.mov")
    }
}

@Suite struct SceneDataPersistenceTests {
    private func sampleEdits() -> SceneEdits {
        SceneEdits(
            sensitivity: 0.7,
            regions: [SensitivityRegion(start: CMTime(value: 1001, timescale: 24000), end: CMTime(value: 5, timescale: 1), value: 0.9)],
            manualCuts: [CMTime(value: 2002, timescale: 24000)],
            ignoredCuts: [CMTime(value: 3, timescale: 1)]
        )
    }

    @Test func sceneEditsAndDefaultSensitivityRoundTrip() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        project.defaultSensitivity = 0.35
        let edits = sampleEdits()
        project.clips[0].sceneEdits = edits

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.project.defaultSensitivity == 0.35)
        #expect(loaded.project.mediaClip(id: assetID)?.sceneEdits == edits)
    }

    @Test func untouchedProjectsWriteNoSceneFields() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        #expect(!text.contains("sceneEdits"))
        #expect(!text.contains("defaultSensitivity"))
    }

    @Test func projectFilesFromBeforeSceneDetectionStillLoad() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.project.defaultSensitivity == SceneDetector.balancedSensitivity)
        #expect(loaded.project.mediaClip(id: assetID)?.sceneEdits == SceneEdits())
        #expect(loaded.changeScores.isEmpty)
    }

    @Test func changeScoresAreSavedInReferenceAndLoadedBack() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let track = ChangeScoreTrack(timescale: 600, times: [0, 25, 50], scores: [0, 200, 3])

        try await ProjectStore.save(project, to: sandbox.packageURL, changeScores: [assetID: track])

        let file = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
            .appending(path: ProjectStore.changeScoreFileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.changeScores[assetID] == track)
    }

    @Test func scoresForUnknownAssetsAreNotWritten() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        let stray = UUID()

        try await ProjectStore.save(
            project, to: sandbox.packageURL,
            changeScores: [stray: ChangeScoreTrack(timescale: 600, times: [0], scores: [0])]
        )

        let folder = ProjectStore.referenceFolder(for: stray, in: sandbox.packageURL)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aDamagedScoreFileJustMeansNotAnalyzed() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let track = ChangeScoreTrack(timescale: 600, times: [0, 25], scores: [0, 9])
        try await ProjectStore.save(project, to: sandbox.packageURL, changeScores: [assetID: track])
        let file = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
            .appending(path: ProjectStore.changeScoreFileName)
        try Data("garbage".utf8).write(to: file)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.changeScores[assetID] == nil)
        #expect(loaded.project.clips.count == 1)
    }
}

@Suite struct ReferenceDataPersistenceTests {
    private func sampleReference() -> AssetReference {
        AssetReference(
            metadata: AssetMetadataSnapshot(
                fileName: "footage.mov", originalPath: "/Volumes/Footage/footage.mov", byteCount: 1234, modified: 1_700_000_000.5,
                isVideo: true, durationValue: 10010, durationTimescale: 1000, frameRate: 29.97, width: 3840, height: 2160,
                codecName: "HEVC", colorPrimaries: "ITU_R_2020", colorTransfer: "SMPTE_ST_2084_PQ", colorMatrix: "ITU_R_2020",
                audioSampleRate: 48000, capturedAt: 1_700_000_100
            ),
            audioEnvelope: AudioEnvelope(startWindow: 0, levels: [0, 40, 200, 255])
        )
    }

    @Test func referenceRoundTripsThroughThePackage() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let reference = sampleReference()

        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference])
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.references[assetID] == reference)
    }

    @Test func aFileWithoutAudioWritesNoEnvelope() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        var reference = sampleReference()
        reference.audioEnvelope = nil

        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference])

        let folder = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ProjectStore.audioEnvelopeFileName).path))
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.references[assetID] == reference)
    }

    @Test func aDamagedEnvelopeIsDroppedButTheSnapshotSurvives() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: sampleReference()])
        let folder = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
        try Data("garbage".utf8).write(to: folder.appending(path: ProjectStore.audioEnvelopeFileName))

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.references[assetID]?.metadata == sampleReference().metadata)
        #expect(loaded.references[assetID]?.audioEnvelope == nil)
    }

    @Test func aDamagedSnapshotMeansNoReference() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: sampleReference()])
        let folder = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
        try Data("{".utf8).write(to: folder.appending(path: ProjectStore.referenceMetadataFileName))

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.references[assetID] == nil)
    }

    @Test func referencesForUnknownAssetsAreNotWritten() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        let stray = UUID()

        try await ProjectStore.save(project, to: sandbox.packageURL, references: [stray: sampleReference()])

        #expect(!FileManager.default.fileExists(atPath: ProjectStore.referenceFolder(for: stray, in: sandbox.packageURL).path))
    }
}

@Suite struct ReferenceThumbnailPersistenceTests {
    private func sample() -> ReferenceThumbnails {
        ReferenceThumbnails(frames: [
            ReferenceFrame(time: CMTime(value: 0, timescale: 600), jpeg: Data([1, 2, 3])),
            ReferenceFrame(time: CMTime(value: 1001, timescale: 24000), jpeg: Data([4, 5])),
            ReferenceFrame(time: CMTime(value: 7, timescale: 1), jpeg: Data([6])),
        ])
    }

    @Test func picturesRoundTripInTimeOrder() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL, thumbnails: [assetID: sample()])

        #expect(ProjectStore.readThumbnails(for: assetID, in: sandbox.packageURL) == sample())
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.assetsWithThumbnails == [assetID])
    }

    @Test func aLeftoverPartialFolderCountsAsNotCaptured() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let partial = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
            .appending(path: "thumbs.partial", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data([1]).write(to: partial.appending(path: "0_600.jpg"))

        #expect(!ProjectStore.hasThumbnails(for: assetID, in: sandbox.packageURL))
        try await ProjectStore.save(project, to: sandbox.packageURL, thumbnails: [assetID: sample()])
        #expect(ProjectStore.readThumbnails(for: assetID, in: sandbox.packageURL) == sample())
    }

    @Test func savedPicturesAreNeverOverwritten() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, thumbnails: [assetID: sample()])

        let other = ReferenceThumbnails(frames: [ReferenceFrame(time: .zero, jpeg: Data([9]))])
        try await ProjectStore.save(project, to: sandbox.packageURL, thumbnails: [assetID: other])

        #expect(ProjectStore.readThumbnails(for: assetID, in: sandbox.packageURL) == sample())
    }

    @Test func fileNamesCarryTheExactTime() {
        let time = CMTime(value: 1001, timescale: 24000)
        #expect(ProjectStore.thumbnailFileName(for: time) == "1001_24000.jpg")
        #expect(ProjectStore.thumbnailTime(fromFileName: "1001_24000.jpg") == time)
        #expect(ProjectStore.thumbnailTime(fromFileName: "notes.txt") == nil)
        #expect(ProjectStore.thumbnailTime(fromFileName: "1_0.jpg") == nil)
    }
}

@Suite struct MediaReplacementPersistenceTests {
    @Test func alignmentAndPreviousPathsRoundTrip() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        project.clips[0].alignmentOffset = CMTime(value: -1001, timescale: 24000)
        project.clips[0].previousPaths = ["/Volumes/Cards/proxy.mov", "Media/older.mov"]

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        let clip = try #require(loaded.project.mediaClip(id: assetID))
        #expect(clip.alignmentOffset == CMTime(value: -1001, timescale: 24000))
        #expect(clip.previousPaths == ["/Volumes/Cards/proxy.mov", "Media/older.mov"])
    }

    @Test func untouchedAssetsWriteNoReplacementFields() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)

        #expect(!text.contains("alignmentOffset"))
        #expect(!text.contains("previousPaths"))
    }

    @Test func aSwappedFileIsReportedOnLoad() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        project.clips[0].acceptedStamp = FileStamp(url: sandbox.mediaURL)
        try await ProjectStore.save(project, to: sandbox.packageURL)

        let unchanged = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(unchanged.changedMedia.isEmpty)

        try Data("a different, longer file".utf8).write(to: sandbox.mediaURL)
        let changed = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(changed.changedMedia == [assetID])
    }

    @Test func projectsWithoutAStampAreNotReportedAsChanged() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, _) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL)

        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)

        #expect(loaded.changedMedia.isEmpty)
        #expect(loaded.project.clips[0].acceptedStamp != nil)
    }

    @Test func copyingIntoThePackageStampsTheCopy() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()

        let saved = try await ProjectStore.save(project, to: sandbox.packageURL, copying: [assetID])
        let copy = try #require(saved.mediaClip(id: assetID)?.url)

        #expect(saved.mediaClip(id: assetID)?.acceptedStamp == FileStamp(url: copy))
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.changedMedia.isEmpty)
    }
}

@Suite struct ForgetOriginalTests {
    private func reference() -> AssetReference {
        AssetReference(
            metadata: AssetMetadataSnapshot(
                fileName: "footage.mov", originalPath: "/tmp/footage.mov", byteCount: 1, modified: 1,
                isVideo: true, durationValue: 10, durationTimescale: 1, frameRate: 24, width: 1920, height: 1080,
                codecName: "H.264", colorPrimaries: nil, colorTransfer: nil, colorMatrix: nil,
                audioSampleRate: 48000, capturedAt: 1
            ),
            audioEnvelope: AudioEnvelope(startWindow: 0, levels: [1, 2, 3])
        )
    }

    @Test func theFlagSurvivesSaveAndLoadAndIsOmittedWhenFalse() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()

        try await ProjectStore.save(project, to: sandbox.packageURL)
        let text = try String(contentsOf: sandbox.projectJSON, encoding: .utf8)
        #expect(!text.contains("referenceForgotten"))

        project.markReferenceForgotten(forAsset: assetID)
        try await ProjectStore.save(project, to: sandbox.packageURL)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.project.mediaClip(id: assetID)?.referenceForgotten == true)
    }

    @Test func forgettingDeletesTheReferenceButKeepsTheScores() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let track = ChangeScoreTrack(timescale: 600, times: [0, 25], scores: [0, 200])
        try await ProjectStore.save(
            project, to: sandbox.packageURL,
            changeScores: [assetID: track], references: [assetID: reference()]
        )
        let folder = ProjectStore.referenceFolder(for: assetID, in: sandbox.packageURL)
        let thumbs = folder.appending(path: ProjectStore.thumbnailFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        try Data([1]).write(to: thumbs.appending(path: "0.jpg"))

        try ProjectStore.forgetReference(for: assetID, in: sandbox.packageURL)

        let fileManager = FileManager.default
        #expect(!fileManager.fileExists(atPath: folder.appending(path: ProjectStore.referenceMetadataFileName).path))
        #expect(!fileManager.fileExists(atPath: folder.appending(path: ProjectStore.audioEnvelopeFileName).path))
        #expect(!fileManager.fileExists(atPath: thumbs.path))
        #expect(ProjectStore.readReference(for: assetID, in: sandbox.packageURL) == nil)
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.changeScores[assetID] == track)
    }

    @Test func savingAForgottenOriginalDeletesItsDataAndWritesNoNewData() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference()])
        #expect(ProjectStore.readReference(for: assetID, in: sandbox.packageURL) != nil)

        project.markReferenceForgotten(forAsset: assetID)
        let pictures = ReferenceThumbnails(frames: [ReferenceFrame(time: .zero, jpeg: Data([1]))])
        try await ProjectStore.save(
            project, to: sandbox.packageURL,
            references: [assetID: reference()], thumbnails: [assetID: pictures]
        )

        #expect(ProjectStore.readReference(for: assetID, in: sandbox.packageURL) == nil)
        #expect(!ProjectStore.hasThumbnails(for: assetID, in: sandbox.packageURL))
        let loaded = try await ProjectStore.load(from: sandbox.packageURL, importMedia: Sandbox.stubImporter)
        #expect(loaded.references[assetID] == nil)
    }

    @Test func saveAsCarriesTheSavedReferenceDataToTheNewPackage() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        let track = ChangeScoreTrack(timescale: 600, times: [0, 25], scores: [0, 200])
        let pictures = ReferenceThumbnails(frames: [ReferenceFrame(time: .zero, jpeg: Data([1]))])
        try await ProjectStore.save(
            project, to: sandbox.packageURL,
            changeScores: [assetID: track], references: [assetID: reference()], thumbnails: [assetID: pictures]
        )

        let copy = sandbox.root.appending(path: "Copy.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(project, to: copy, previousPackageURL: sandbox.packageURL)

        #expect(ProjectStore.readReference(for: assetID, in: copy) == reference())
        #expect(ProjectStore.readChangeScores(for: assetID, in: copy) == track)
        #expect(ProjectStore.readThumbnails(for: assetID, in: copy) == pictures)
    }

    @Test func saveAsLeavesAForgottenOriginalBehind() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        var (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference()])

        project.markReferenceForgotten(forAsset: assetID)
        let copy = sandbox.root.appending(path: "Copy.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(project, to: copy, previousPackageURL: sandbox.packageURL)

        #expect(ProjectStore.readReference(for: assetID, in: copy) == nil)
    }

    @Test func savingInPlaceWithItselfAsThePreviousPackageChangesNothing() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let (project, _, assetID) = sandbox.makeProject()
        try await ProjectStore.save(project, to: sandbox.packageURL, references: [assetID: reference()])

        try await ProjectStore.save(project, to: sandbox.packageURL, previousPackageURL: sandbox.packageURL)

        #expect(ProjectStore.readReference(for: assetID, in: sandbox.packageURL) == reference())
    }

    @Test func forgettingWhenNothingWasSavedIsHarmless() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try ProjectStore.forgetReference(for: UUID(), in: sandbox.packageURL)
    }
}
