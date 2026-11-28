import Foundation
import os

/// Which effect packages from outside the app the person has approved to
/// run on this Mac (docs/effect-packages.md, "Safety"; decision D8 in
/// code-review-notes.md). A package's kernel is code compiled for and run
/// on the GPU, where a faulty or malicious one can stall graphics or make
/// the app unstable, so no external package's kernel is compiled until
/// the person approved that package as it is; changed, it asks again.
/// Packages that ship with the app need none.
///
/// Kept in `~/Library/Application Support/AnimationMeetsVideo/ApprovedEffects.json`,
/// never in a package or project, which could vouch for itself: each
/// approved package's `approvalHash`, the SHA-256 of its effect.json and
/// kernel. Read from any thread: render threads ask before compiling.
final class EffectApproval: Sendable {
    static let shared = EffectApproval()

    private struct Stored: Codable {
        var formatVersion = 1
        var packages: [String] = []
    }

    /// Nil for a list that is never saved.
    private let file: URL?
    private let approved: OSAllocatedUnfairLock<Set<String>>

    init(file: URL? = EffectApproval.defaultFile) {
        self.file = file
        var hashes = Set<String>()
        if let file, let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            hashes = Set(stored.packages)
        }
        approved = OSAllocatedUnfairLock(initialState: hashes)
    }

    static var defaultFile: URL {
        URL.applicationSupportDirectory
            .appending(path: "AnimationMeetsVideo", directoryHint: .isDirectory)
            .appending(path: "ApprovedEffects.json")
    }

    /// Whether `package`'s kernel may be compiled and run: it ships with
    /// the app, or the person approved it as it is now.
    func allows(_ package: EffectPackage) -> Bool {
        package.isBuiltIn || approved.withLock { $0.contains(package.approvalHash) }
    }

    /// Approves `package` as it is, and saves the list.
    func approve(_ package: EffectPackage) {
        guard !package.isBuiltIn, approved.withLock({ $0.insert(package.approvalHash).inserted }) else { return }
        save()
    }

    /// Approves content until the app quits, without saving it: for tests,
    /// which mustn't write the person's own list.
    func approveInSession(hash: String) {
        approved.withLock { _ = $0.insert(hash) }
    }

    /// Forgets every approval: each external package asks again.
    func forgetAll() {
        approved.withLock { $0 = [] }
        save()
    }

    var isEmpty: Bool { approved.withLock { $0.isEmpty } }

    private func save() {
        guard let file else { return }
        let stored = Stored(packages: approved.withLock { $0.sorted() })
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONFile.encode(stored).write(to: file, options: .atomic)
        } catch {
            NSLog("%@", "Couldn't save the approved effect packages: \(error.localizedDescription)")
        }
    }
}

/// Where an effect package came from, as far as the Mac recorded it, for
/// the approval question: the site it was downloaded from
/// (`kMDItemWhereFroms`), or that it was downloaded (the quarantine flag),
/// or the folder it is in.
enum EffectPackageOrigin {
    static func describe(_ url: URL) -> String {
        for item in [url, url.appending(path: EffectPackageStore.manifestName)] {
            if let host = downloadedFrom(item) { return "downloaded from \(host)" }
        }
        if [url, url.appending(path: EffectPackageStore.manifestName)].contains(where: { attribute("com.apple.quarantine", of: $0) != nil }) {
            return "downloaded from the internet"
        }
        let folder = url.deletingLastPathComponent().standardizedFileURL
        if folder == EffectPackageStore.defaultFolder.standardizedFileURL { return "in your Effects folder" }
        return "in \(folder.path)"
    }

    /// The host of the first web address the Mac recorded for `url`.
    static func downloadedFrom(_ url: URL) -> String? {
        guard let data = attribute("com.apple.metadata:kMDItemWhereFroms", of: url),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return nil }
        for entry in list {
            if let address = URL(string: entry), let scheme = address.scheme?.lowercased(), scheme == "https" || scheme == "http",
               let host = address.host(), !host.isEmpty {
                return host
            }
        }
        return nil
    }

    private static func attribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0, size <= 1 << 20 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read == size ? data : nil
        }
    }
}
