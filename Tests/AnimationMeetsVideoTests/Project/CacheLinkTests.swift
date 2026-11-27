import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A package's cache folders are cleared freely, so a project that
/// arrives with one linked out of it (zip and AirDrop keep links) must
/// never have what the link points at cleared.
@Suite struct CacheLinkTests {
    private struct Sandbox {
        let root: URL
        let package: URL
        let elsewhere: URL
        let theirs: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "amv-links-\(UUID().uuidString)", directoryHint: .isDirectory)
            package = root.appending(path: "Cut.amv", directoryHint: .isDirectory)
            elsewhere = root.appending(path: "Someone's folder", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: package.appending(path: "Cache"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            theirs = elsewhere.appending(path: "Holiday.mov")
            try Data("not a render".utf8).write(to: theirs)
        }

        func link(_ name: String) throws {
            try FileManager.default.createSymbolicLink(
                at: package.appending(path: "Cache/\(name)"), withDestinationURL: elsewhere
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func unusedReferenceMoviesAreNotClearedThroughALink() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.link(MatroskaMedia.folder(in: sandbox.package).lastPathComponent)
        MatroskaMedia.removeUnused(in: sandbox.package, keeping: [])
        #expect(FileManager.default.fileExists(atPath: sandbox.theirs.path))
    }

    @Test func rendersAreNotEvictedThroughALink() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.link(RenderCache.folderName)
        let cache = RenderCache(packageURL: sandbox.package)
        cache.evict(toFit: 0)
        cache.removePartials()
        #expect(FileManager.default.fileExists(atPath: sandbox.theirs.path))
    }

    @Test func thePackagesOwnRendersAreStillEvicted() throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let cache = RenderCache(packageURL: sandbox.package)
        try FileManager.default.createDirectory(at: cache.folder, withIntermediateDirectories: true)
        try Data("render".utf8).write(to: cache.url(for: "old"))
        cache.evict(toFit: 0)
        #expect(cache.file(for: "old") == nil)
    }
}
