import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite struct ProjectFileMonitorTests {
    private func makePackage(_ contents: String) throws -> URL {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).amv")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: package.appending(path: ProjectStore.projectFileName))
        return package
    }

    private func write(_ contents: String, to package: URL) throws {
        try Data(contents.utf8).write(to: package.appending(path: ProjectStore.projectFileName), options: .atomic)
    }

    @Test func anUntouchedFileIsNotAChange() throws {
        let package = try makePackage("one")
        defer { try? FileManager.default.removeItem(at: package) }
        let monitor = ProjectFileMonitor()
        monitor.track(package: package)

        #expect(monitor.pendingChange() == nil)
    }

    @Test func differentContentsAreAChangeUntilAcknowledged() throws {
        let package = try makePackage("one")
        defer { try? FileManager.default.removeItem(at: package) }
        let monitor = ProjectFileMonitor()
        monitor.track(package: package)

        try write("two, which is longer", to: package)
        let change = try #require(monitor.pendingChange())
        // Still pending until someone deals with it.
        #expect(monitor.pendingChange() == change)

        monitor.acknowledge(change)
        #expect(monitor.pendingChange() == nil)
    }

    @Test func rewritingTheSameBytesIsNotAChange() throws {
        let package = try makePackage("same")
        defer { try? FileManager.default.removeItem(at: package) }
        let monitor = ProjectFileMonitor()
        monitor.track(package: package)

        try write("same", to: package)

        #expect(monitor.pendingChange() == nil)
    }

    @Test func aSaveByTheAppIsNotAChangeOnceItIsTracked() throws {
        let package = try makePackage("one")
        defer { try? FileManager.default.removeItem(at: package) }
        let monitor = ProjectFileMonitor()
        monitor.track(package: package)

        try write("saved by the app", to: package)
        monitor.track(package: package)

        #expect(monitor.pendingChange() == nil)
    }

    @Test func aMissingFileOrNoPackageIsIgnored() throws {
        let package = try makePackage("one")
        let monitor = ProjectFileMonitor()
        #expect(monitor.pendingChange() == nil)

        monitor.track(package: package)
        try FileManager.default.removeItem(at: package)
        #expect(monitor.pendingChange() == nil)
    }
}
