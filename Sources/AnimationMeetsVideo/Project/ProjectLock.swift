import Darwin
import Foundation

/// Single-writer lock on a project package, so two windows or processes
/// can't save over each other.
///
/// It holds an exclusive `flock` on the package's `.lock` file. The operating
/// system drops the lock when the process exits or crashes, so a stale lock
/// file never blocks opening the project. The file's text only says who holds
/// it, for the error message.
///
/// Some volumes, such as certain network shares, don't support `flock` at
/// all. A project there opens without the lock rather than being reported
/// as open elsewhere.
final class ProjectLock {
    let packageURL: URL
    private var descriptor: Int32

    private init(packageURL: URL, descriptor: Int32) {
        self.packageURL = packageURL
        self.descriptor = descriptor
    }

    /// Takes the lock, or throws `ProjectStoreError.locked` if another
    /// instance holds it.
    static func acquire(at packageURL: URL) throws -> ProjectLock {
        let lockURL = packageURL.appending(path: ProjectStore.lockFileName)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            switch code {
            case EWOULDBLOCK:
                let holder = (try? String(contentsOf: lockURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                close(descriptor)
                throw ProjectStoreError.locked(holder?.isEmpty == false ? holder : nil)
            case ENOTSUP, EOPNOTSUPP:
                NSLog("The volume of \(packageURL.path) doesn't support file locks; opening the project without one.")
            default:
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }

        let description = "\(ProcessInfo.processInfo.processName) (process \(ProcessInfo.processInfo.processIdentifier)) on \(ProcessInfo.processInfo.hostName)\n"
        ftruncate(descriptor, 0)
        _ = description.withCString { pwrite(descriptor, $0, strlen($0), 0) }
        return ProjectLock(packageURL: packageURL, descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
