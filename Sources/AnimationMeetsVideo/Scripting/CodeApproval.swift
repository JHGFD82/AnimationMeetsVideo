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
/// each piece of code allowed, and the projects whose scripts may run. A
/// project is known by its ID and where its package was when it was
/// allowed, so a copy arriving from elsewhere under the same ID asks again.
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

    /// A project whose scripts run without asking: one made on this Mac,
    /// or one whose scripts the person allowed.
    struct AllowedProject: Codable, Hashable, Sendable {
        var id: UUID
        var path: String
    }

    private struct Stored: Codable {
        var formatVersion = 1
        var code: [String] = []
        var projects: [AllowedProject] = []
    }

    private(set) var allowedHashes: Set<String> = []
    private(set) var allowedProjects: Set<AllowedProject> = []
    @ObservationIgnored private let file: URL
    /// Whether `allowsCode` reads this one's hashes: the app's own.
    @ObservationIgnored private let publishes: Bool

    init(file: URL = CodeApproval.defaultFile, publishes: Bool = false) {
        self.file = file
        self.publishes = publishes
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            allowedHashes = Set(stored.code)
            allowedProjects = Set(stored.projects)
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

    /// What allowing a script of a project's `Scripts/` allows: its text,
    /// and every other file in its folder by name and hash. The script
    /// runs with its folder first on Python's import path, so `import
    /// util` runs the `util.py` beside it: allowing only the chosen
    /// script's text let a sibling no one was shown run with it. Changing
    /// any file of the folder asks again; a script alone in its folder is
    /// allowed by its text alone, as before.
    nonisolated static func approvalCode(forScript text: String, at url: URL) -> String {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        let own = url.standardizedFileURL.path
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return text }
        var siblings: [String] = []
        for case let file as URL in walk {
            let path = file.standardizedFileURL.path
            guard path != own, file.lastPathComponent != ".DS_Store",
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let data = (try? Data(contentsOf: file)) ?? Data()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            siblings.append("\(path.dropFirst(folder.path.count)) \(digest)")
        }
        guard !siblings.isEmpty else { return text }
        return text + "\n\0beside it:\n" + siblings.sorted().joined(separator: "\n")
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

    // MARK: Projects

    /// Whether a project's scripts run without asking: it was made here,
    /// or its scripts were allowed, where its package is now.
    func allowsScripts(ofProject id: UUID, at packageURL: URL) -> Bool {
        allowedProjects.contains(AllowedProject(id: id, path: Self.path(of: packageURL)))
    }

    /// Whether a script of a project may run without asking: its project's
    /// scripts are allowed, or this text of it was.
    func mayRun(script text: String, ofProject id: UUID, at packageURL: URL) -> Bool {
        allowsScripts(ofProject: id, at: packageURL) || isAllowed(text)
    }

    /// Lets a project's scripts run without asking: one made here, or one
    /// the person chose Always Run This Project's Scripts for.
    func allowScripts(ofProject id: UUID, at packageURL: URL) {
        guard allowedProjects.insert(AllowedProject(id: id, path: Self.path(of: packageURL))).inserted else { return }
        save()
    }

    /// A project saved somewhere new (Save As) keeps what was allowed of
    /// it: the person moved it, it didn't arrive from elsewhere.
    func projectMoved(_ id: UUID, from old: URL, to new: URL) {
        guard allowsScripts(ofProject: id, at: old) else { return }
        allowScripts(ofProject: id, at: new)
    }

    /// Settings > Scripting's Forget Allowed Code: every hash and project.
    func forgetAll() {
        allowedHashes = []
        allowedProjects = []
        if publishes { Self.published.withLock { $0 = [] } }
        save()
    }

    var isEmpty: Bool { allowedHashes.isEmpty && allowedProjects.isEmpty }

    private static func path(of packageURL: URL) -> String {
        packageURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func save() {
        let stored = Stored(code: allowedHashes.sorted(), projects: allowedProjects.sorted { ($0.path, $0.id.uuidString) < ($1.path, $1.id.uuidString) })
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
