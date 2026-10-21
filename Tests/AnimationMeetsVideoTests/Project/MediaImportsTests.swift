import Foundation
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// Files listed while they are imported, and the progress a Matroska file
/// reports on its way in.
@MainActor
@Suite(.serialized) struct MediaImportsTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "amv-imports-\(UUID().uuidString)")

    @Test func progressOnlyMovesForward() {
        let imports = MediaImports()
        let ids = imports.begin([URL(fileURLWithPath: "/a/Movie.mkv"), URL(fileURLWithPath: "/a/Song.wav")])
        #expect(imports.items.map(\.name) == ["Movie", "Song"])
        #expect(imports.items[0].fraction == nil)

        imports.update(ids[0], fraction: 0.5)
        imports.update(ids[0], fraction: 0.3)
        imports.update(ids[0], fraction: 0.501)
        #expect(imports.items[0].fraction == 0.5)
        imports.update(ids[0], fraction: 2)
        #expect(imports.items[0].fraction == 1)

        imports.end(ids[0])
        imports.update(ids[0], fraction: 0.9)
        #expect(imports.items.map(\.name) == ["Song"])
    }

    @Test func makingAMatroskaMovieReportsItsProgress() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mkv = root.appending(path: "Footage.mkv")
        let source = try await MatroskaFixture.write(to: mkv, options: .init())
        try? FileManager.default.removeItem(at: source.movie)

        // Reported on the calling thread, as the making runs.
        var seen: [Double] = []
        try MatroskaMedia.prepare(mkv, in: root.appending(path: "References")) { seen.append($0) }
        #expect(seen.count > 1)
        #expect(seen == seen.sorted())
        #expect(abs((seen.last ?? 0) - 1) < 1e-9)
    }

    @Test func anImportedFileIsNoLongerListed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mkv = root.appending(path: "Footage.mkv")
        let source = try await MatroskaFixture.write(to: mkv, options: .init())
        try? FileManager.default.removeItem(at: source.movie)
        let missing = root.appending(path: "Gone.mov")

        var project = EditingProject.empty
        let binding = Binding(get: { project }, set: { project = $0 })
        let imports = MediaImports()
        var errors: [String] = []
        let imported = await MediaImportFlow.importFiles(
            [mkv, missing], copying: [], packageURL: nil, project: binding, imports: imports, onError: { errors.append($0) }
        )

        #expect(imported.map(\.url) == [mkv])
        #expect(errors.count == 1)
        #expect(imports.items.isEmpty)
    }
}
