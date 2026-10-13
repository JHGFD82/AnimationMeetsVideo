import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct ProjectLockTests {
    private func makePackage() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-lock-\(UUID().uuidString).amv", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func secondAcquireFailsWhileFirstIsHeld() throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }

        let first = try ProjectLock.acquire(at: package)
        defer { first.release() }

        #expect {
            try ProjectLock.acquire(at: package)
        } throws: { error in
            guard case ProjectStoreError.locked(let holder) = error else { return false }
            return holder?.contains("process \(ProcessInfo.processInfo.processIdentifier)") == true
        }
    }

    @Test func canAcquireAgainAfterRelease() throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }

        let first = try ProjectLock.acquire(at: package)
        first.release()

        let second = try ProjectLock.acquire(at: package)
        second.release()
    }

    @Test func lockIsReleasedWhenDeallocated() throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }

        do {
            _ = try ProjectLock.acquire(at: package)
        }
        let again = try ProjectLock.acquire(at: package)
        again.release()
    }

    @Test func staleLockFileDoesNotBlock() throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        try "Crashed (process 1) on somewhere\n".write(
            to: package.appending(path: ProjectStore.lockFileName), atomically: true, encoding: .utf8
        )

        let lock = try ProjectLock.acquire(at: package)
        lock.release()
    }

    @Test func notAProjectFolderIsRejectedBeforeLocking() throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }

        #expect(throws: ProjectStoreError.self) {
            try ProjectStore.validatePackage(at: package)
        }
        #expect(!FileManager.default.fileExists(atPath: package.appending(path: ProjectStore.lockFileName).path))
    }
}
