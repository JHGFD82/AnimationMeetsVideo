import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Importing Matroska files: their reference movies are made in the
/// project's `Cache/References/` and opened in their place.
@Suite(.serialized) struct MatroskaImportTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "amv-mkv-import-\(UUID().uuidString)")

    private func makePackage() throws -> URL {
        let package = root.appending(path: "Project.amv")
        try ProjectStore.preparePackage(at: package)
        return package
    }

    private func makeMatroska(_ options: MatroskaFixture.Options = .init()) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "Footage-\(UUID().uuidString).mkv")
        let source = try await MatroskaFixture.write(to: url, options: options)
        try? FileManager.default.removeItem(at: source.movie)
        return url
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func importMakesTheMovieInThePackagesCache() async throws {
        defer { cleanUp() }
        let package = try makePackage()
        let mkv = try await makeMatroska()

        let clip = try await MediaImporter.importClip(at: mkv, packageURL: package)

        #expect(clip.url == mkv)
        #expect(clip.kind == .video)
        #expect(clip.codecName == "H.264")
        #expect(clip.hasAudio)
        #expect(clip.frameRate == Double(MatroskaFixture.fps))
        #expect(abs(clip.duration.seconds - 2) < 0.05)
        #expect(clip.acceptedStamp == FileStamp(url: mkv))

        let movie = MatroskaMedia.folder(in: package).appending(path: try #require(MatroskaMedia.movieName(for: mkv)))
        #expect(FileManager.default.fileExists(atPath: movie.path))
        #expect(MediaFile.readableURL(for: mkv) == movie)
    }

    @Test func compositionsAndAnalysisOpenTheMovie() async throws {
        defer { cleanUp() }
        let package = try makePackage()
        let mkv = try await makeMatroska()
        _ = try await MediaImporter.importClip(at: mkv, packageURL: package)

        let info = try await MediaTrackCache.shared.info(for: mkv)
        #expect(info.video != nil)
        #expect(info.audio != nil)
        #expect(info.orientedSize == CGSize(width: MatroskaFixture.width, height: MatroskaFixture.height))
        let waveform = try await Waveform.read(url: mkv)
        #expect(!waveform.peaks.isEmpty)
        await MediaTrackCache.shared.forget(mkv)
    }

    @MainActor
    @Test func aMatroskaClipIsSkimmedFromItsMovie() async throws {
        defer { cleanUp() }
        let package = try makePackage()
        let mkv = try await makeMatroska()
        let clip = try await MediaImporter.importClip(at: mkv, packageURL: package)
        let skim = BrowserSkim()
        defer { skim.end() }

        skim.skim(BrowserSkim.Target(item: "clip", clip: clip, start: .zero, duration: clip.duration), at: 1)

        let item = try #require(skim.player.currentItem)
        #expect((item.asset as? AVURLAsset)?.url == MediaFile.readableURL(for: mkv))
        for _ in 0..<200 where abs(skim.player.currentTime().seconds - 1) > 0.001 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(skim.player.currentTime().seconds - 1) < 0.001)
        for _ in 0..<300 where item.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
    }

    @Test func otherFilesOpenAsThemselves() {
        let movie = URL(fileURLWithPath: "/tmp/not-imported.mov")
        #expect(MediaFile.readableURL(for: movie) == movie)
    }

    @Test func savingAProjectImportedUnsavedMakesTheMovieInItsPackage() async throws {
        defer { cleanUp() }
        let mkv = try await makeMatroska()
        let clip = try await MediaImporter.importClip(at: mkv, packageURL: nil)
        let unsaved = MatroskaMedia.unsavedFolder.appending(path: try #require(MatroskaMedia.movieName(for: mkv)))
        #expect(MediaFile.readableURL(for: mkv) == unsaved)

        var project = EditingProject.empty
        project.addMedia(clip)
        let package = root.appending(path: "Saved.amv")
        try await ProjectStore.save(project, to: package)

        let movie = MatroskaMedia.folder(in: package).appending(path: unsaved.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: movie.path))
        #expect(MediaFile.readableURL(for: mkv) == movie)
        try? FileManager.default.removeItem(at: unsaved)
    }

    @Test func openingRemakesMissingMoviesAndDropsUnusedOnes() async throws {
        defer { cleanUp() }
        let package = try makePackage()
        let mkv = try await makeMatroska()
        var project = EditingProject.empty
        project.addMedia(try await MediaImporter.importClip(at: mkv, packageURL: package))
        try await ProjectStore.save(project, to: package)

        let folder = MatroskaMedia.folder(in: package)
        let movie = folder.appending(path: try #require(MatroskaMedia.movieName(for: mkv)))
        try FileManager.default.removeItem(at: movie)
        let stale = folder.appending(path: "0123456789abcdef.mov")
        try Data("left by a file since moved".utf8).write(to: stale)

        let loaded = try await ProjectStore.load(from: package)

        #expect(loaded.offlineMedia.isEmpty)
        #expect(loaded.project.clips.first?.codecName == "H.264")
        #expect(FileManager.default.fileExists(atPath: movie.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test func aChangedFileGetsANewMovie() async throws {
        defer { cleanUp() }
        let package = try makePackage()
        let mkv = try await makeMatroska()
        _ = try await MediaImporter.importClip(at: mkv, packageURL: package)
        let before = MediaFile.readableURL(for: mkv)

        // Written again differently, as if swapped for another version.
        let other = try await makeMatroska(.init(lacing: .xiph))
        try FileManager.default.removeItem(at: mkv)
        try FileManager.default.moveItem(at: other, to: mkv)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: mkv.path)

        let after = MediaFile.readableURL(for: mkv)
        #expect(after != before)
        #expect(after.deletingLastPathComponent() == MatroskaMedia.folder(in: package))
        #expect(FileManager.default.fileExists(atPath: after.path))
    }

    @Test func aFileWithNothingUsableIsRefused() async throws {
        defer { cleanUp() }
        let package = try makePackage()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let webm = root.appending(path: "VP9.webm")
        var file = EBMLWriter.element(0x1A45DFA3, [EBMLWriter.string(0x4282, "webm")])
        file.append(EBMLWriter.element(0x18538067, [
            EBMLWriter.element(0x1654AE6B, [EBMLWriter.element(0xAE, [
                EBMLWriter.unsigned(0xD7, 1), EBMLWriter.unsigned(0x83, 1), EBMLWriter.string(0x86, "V_VP9"),
            ])]),
        ]))
        try file.write(to: webm)

        await #expect(throws: MatroskaError.self) {
            try await MediaImporter.importClip(at: webm, packageURL: package)
        }
        let made = try? FileManager.default.contentsOfDirectory(atPath: MatroskaMedia.folder(in: package).path)
        #expect(made?.isEmpty ?? true)
    }
}
