import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Package changes that overlap in time must still happen in the order they
/// were asked. Each test holds one analysis write open inside the
/// coordinator, as a slow disk would, and checks what the others do meanwhile.
@MainActor
@Suite struct PackageCoordinatorTests {
    private func makePackage() throws -> URL {
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-coord-\(UUID().uuidString).amv")
        try ProjectStore.preparePackage(at: package)
        return package
    }

    private func project(ids: [UUID]) -> EditingProject {
        var project = EditingProject.empty
        project.clips = ids.map {
            var clip = MediaClip(
                name: "a.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"),
                duration: CMTime(seconds: 1, preferredTimescale: 600),
                frameRate: 24, colorSpace: .rec709, codecName: "Test"
            )
            clip.id = $0
            clip.hasAudio = true
            return clip
        }
        return project
    }

    /// An analysis whose first package operation stays open until `gate` does.
    private func analysis(holdingFirstWriteWith gate: Gate) -> AssetAnalysis {
        let analysis = AssetAnalysis()
        let first = Mutex(0)
        analysis.backend.scoreFrames = { _, _ in ChangeScoreTrack(timescale: 600, times: [0], scores: [7]) }
        analysis.backend.captureReference = { _, _ in throw NSError(domain: "test", code: 1) }
        analysis.backend.capturePictures = { _, _, _ in ReferenceThumbnails(frames: []) }
        analysis.backend.detectBeats = { _, _ in BeatTrack(timescale: 1000, times: [100, 600], beatsPerMinute: 120) }
        analysis.backend.perform = { package, body in
            let isFirst = first.increment() == 1
            try await PackageCoordinator.shared.run(on: [package]) {
                if isFirst { await gate.wait() }
                try body(package)
            }
        }
        return analysis
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("condition never held")
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aSaveWaitsForAnAnalysisWriteAlreadyStarted() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let gate = Gate()
        let id = UUID()
        let video = project(ids: [id])
        let analysis = analysis(holdingFirstWriteWith: gate)
        analysis.reset(packageURL: package)
        analysis.analyzeMissing(in: video)
        try await settle { gate.arrived == 1 }

        let save = Task { try await ProjectStore.save(video, to: package) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!exists(package.appending(path: ProjectStore.projectFileName)))

        gate.open()
        _ = try await save.value
        try await settle { analysis.progress.isEmpty }
        #expect(exists(package.appending(path: ProjectStore.projectFileName)))
        #expect(ProjectStore.readChangeScores(for: id, in: package)?.scores == [7])
    }

    @Test func aDeletionWaitsForTheWriteBeforeItSoTheFileStaysGone() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let gate = Gate()
        let id = UUID()
        var video = project(ids: [id])
        let analysis = analysis(holdingFirstWriteWith: gate)
        // Beats only, so the held write is the beat write.
        analysis.backend.scoreFrames = { _, _ in throw NSError(domain: "test", code: 2) }
        analysis.reset(packageURL: package)
        analysis.analyzeMissing(in: video)
        try await settle { gate.arrived >= 1 && analysis.beats[id] != nil }

        // The audio is gone while its beats are being written.
        video.clips[0].hasAudio = false
        analysis.analyzeMissing(in: video)
        #expect(analysis.beats[id] == nil)
        gate.open()
        try await settle { analysis.discardedBeats.isEmpty && analysis.progress.isEmpty }

        #expect(ProjectStore.readBeats(for: id, in: package) == nil)
    }

    @Test func saveAsDuringAWriteAndADeletionCopiesTheSettledPackage() async throws {
        let source = try makePackage(), destination = try makePackage()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let gate = Gate()
        let scored = UUID(), droppedBeats = UUID()
        var video = project(ids: [scored, droppedBeats])
        try ProjectStore.writeBeats(.none(), for: droppedBeats, in: source)
        let analysis = analysis(holdingFirstWriteWith: gate)
        analysis.backend.detectBeats = { _, _ in .none() }
        analysis.reset(beats: [droppedBeats: .none()], packageURL: source)
        analysis.analyzeMissing(in: video)
        try await settle { gate.arrived == 1 }

        // Queue behind the held write: a deletion in the source, then Save As.
        video.clips[1].hasAudio = false
        analysis.analyzeMissing(in: video)
        let unsaved = analysis.unsavedResults()
        let saveAs = Task {
            try await ProjectStore.save(
                video, to: destination, changeScores: unsaved.changeScores,
                previousPackageURL: source
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!exists(destination.appending(path: ProjectStore.projectFileName)))

        gate.open()
        _ = try await saveAs.value

        // Everything queued before the copy had happened when it was made.
        #expect(ProjectStore.readBeats(for: droppedBeats, in: source) == nil)
        #expect(ProjectStore.readBeats(for: droppedBeats, in: destination) == nil)
        #expect(ProjectStore.readChangeScores(for: scored, in: destination)?.scores == [7])
    }
}
