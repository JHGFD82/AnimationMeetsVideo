import CryptoKit
import Foundation
import Observation
import os

/// What Python the person has allowed to run on this Mac (see
/// docs/python-scripting.md, "Safety"). Python in a project is code from
/// wherever the project came from, so nothing runs that wasn't allowed
/// here.
///
/// Kept in `~/Library/Application Support/AnimationMeetsVideo/AllowedCode.json`,
/// never in a project, which could then vouch for itself: the SHA-256 of
/// each piece of code allowed, and nothing else. Approval is of content,
/// never of a project (the owner's decision D5): a project's ID and path
/// say where code is, not what arrived there since, so a script that
/// changed, in the app or out of it, asks again.
@MainActor
@Observable
final class CodeApproval {
    static let shared = CodeApproval(publishes: true)

    /// The hashes `shared` allows, for the model to read off the main
    /// actor: an expression runs only if its code is allowed
    /// (`EditingProject.expressionIsAllowed`).
    private nonisolated static let published = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Whether this Mac allows `code`, read from anywhere.
    nonisolated static func allowsCode(_ code: String) -> Bool {
        let hash = hash(of: code)
        return published.withLock { $0.contains(hash) }
    }

    private struct Stored: Codable {
        var formatVersion = 2
        var code: [String] = []
    }

    private(set) var allowedHashes: Set<String> = []
    @ObservationIgnored private let file: URL
    /// Whether `allowsCode` reads this one's hashes: the app's own.
    @ObservationIgnored private let publishes: Bool

    init(file: URL = CodeApproval.defaultFile, publishes: Bool = false) {
        self.file = file
        self.publishes = publishes
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            allowedHashes = Set(stored.code)
        }
        publish()
    }

    /// Hands the hashes to `allowsCode`, for this one, the app's own.
    private func publish() {
        guard publishes else { return }
        let hashes = allowedHashes
        Self.published.withLock { $0.formUnion(hashes) }
    }

    /// Allows `code` until the app quits, without saving it: for tests,
    /// which mustn't write the person's own list.
    nonisolated static func allowInSession(_ code: String) {
        let hash = hash(of: code)
        published.withLock { _ = $0.insert(hash) }
    }

    nonisolated static var defaultFile: URL {
        URL.applicationSupportDirectory
            .appending(path: "AnimationMeetsVideo", directoryHint: .isDirectory)
            .appending(path: "AllowedCode.json")
    }

    /// The SHA-256 of a piece of code, in hex: changing one character
    /// makes it another.
    nonisolated static func hash(of code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Code

    func isAllowed(_ code: String) -> Bool {
        allowedHashes.contains(Self.hash(of: code))
    }

    /// Allows this exact code: typed by the person, or read and allowed.
    func allow(_ code: String) {
        allow([code])
    }

    /// Allows several at once (Allow All in This Project, Review
    /// Expressions), saved once. Posts `expressionsAllowed`, for the
    /// editors to run the expressions now allowed.
    func allow(_ codes: [String]) {
        let new = Set(codes.map(Self.hash(of:))).subtracting(allowedHashes)
        guard !new.isEmpty else { return }
        allowedHashes.formUnion(new)
        publish()
        save()
        NotificationCenter.default.post(name: .expressionsAllowed, object: self)
    }

    /// Settings > Scripting's Forget Allowed Code: every hash.
    func forgetAll() {
        allowedHashes = []
        if publishes { Self.published.withLock { $0 = [] } }
        save()
    }

    var isEmpty: Bool { allowedHashes.isEmpty }

    private func save() {
        let stored = Stored(code: allowedHashes.sorted())
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONFile.encode(stored).write(to: file, options: .atomic)
        } catch {
            NSLog("%@", "Couldn't save the code allowed to run: \(error.localizedDescription)")
        }
    }
}

extension Notification.Name {
    /// Code was allowed to run: expressions waiting on it can run now.
    static let expressionsAllowed = Notification.Name("expressionsAllowed")
}
