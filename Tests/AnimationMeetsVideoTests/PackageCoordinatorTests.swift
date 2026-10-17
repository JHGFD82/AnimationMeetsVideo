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
            clip.acceptedStamp = FileStamp(byteCount: 1, modified: 1)
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
        analysis.update(with: video)
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
        analysis.update(with: video)
        try await settle { gate.arrived >= 1 && analysis.beats[id] != nil }

        // The audio is gone while its beats are being written.
        video.clips[0].hasAudio = false
        analysis.update(with: video)
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
        let stamp = FileStamp(byteCount: 1, modified: 1)
        try ProjectStore.writeBeats(.none(), for: droppedBeats, in: source, source: stamp)
        let analysis = analysis(holdingFirstWriteWith: gate)
        analysis.backend.detectBeats = { _, _ in .none() }
        // Only `scored` has anything left to analyze, so its write is the held one.
        analysis.reset(
            tracks: [droppedBeats: ChangeScoreTrack(timescale: 600, times: [0], scores: [1])],
            thumbnailed: [droppedBeats],
            beats: [droppedBeats: .none()],
            sources: AnalysisSources(scores: [droppedBeats: stamp], beats: [droppedBeats: stamp]),
            packageURL: source
        )
        analysis.update(with: video)
        try await settle { gate.arrived == 1 }

        // Queue behind the held write: a deletion in the source, then Save As.
        video.clips[1].hasAudio = false
        analysis.update(with: video)
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

    @Test func markingBackupsSeenWaitsForWhatIsAlreadyQueued() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let gate = Gate()
        let id = UUID()
        let video = project(ids: [id])
        try await ProjectStore.save(video, to: package)
        // An autosave newer than project.json: work that was never saved.
        let projectFile = package.appending(path: ProjectStore.projectFileName)
        let older = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: projectFile.path)
        var edited = video
        edited.name = "Edited"
        try ProjectStore.writeBackup(of: edited, in: package)
        #expect(ProjectStore.unsavedBackup(in: package) != nil)

        let held = Task { try await PackageCoordinator.shared.run(on: [package]) { await gate.wait() } }
        try await settle { gate.arrived == 1 }
        let marking = Task { await ProjectStore.markBackupsSeenQueued(in: package) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(ProjectStore.unsavedBackup(in: package) != nil)

        gate.open()
        try await held.value
        await marking.value
        #expect(ProjectStore.unsavedBackup(in: package) == nil)
    }

    @Test func replacingAPackageWaitsForWhatIsAlreadyQueued() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let gate = Gate()
        let held = Task { try await PackageCoordinator.shared.run(on: [package]) { await gate.wait() } }
        try await settle { gate.arrived == 1 }

        let trashing = Task { try await ProjectStore.trashPackage(at: package, checkingLock: false) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(exists(package))

        gate.open()
        try await held.value
        try await trashing.value
        #expect(!exists(package))
        // Leave the Trash as it was found.
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        for item in (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent == package.lastPathComponent {
            try? FileManager.default.removeItem(at: item)
        }
    }

    @Test func saveAsInOppositeDirectionsAtOnceDoesNotDeadlock() async throws {
        let first = try makePackage(), second = try makePackage()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let video = project(ids: [UUID()])
        let finished = Mutex(0)
        let toSecond = Task { try await ProjectStore.save(video, to: second, previousPackageURL: first); _ = finished.increment() }
        let toFirst = Task { try await ProjectStore.save(video, to: first, previousPackageURL: second); _ = finished.increment() }

        try await settle { finished.value == 2 }
        try await toSecond.value
        try await toFirst.value
    }
}
