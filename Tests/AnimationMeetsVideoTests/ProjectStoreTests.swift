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
}
