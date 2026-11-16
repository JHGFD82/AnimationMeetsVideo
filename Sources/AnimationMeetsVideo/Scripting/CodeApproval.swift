import CryptoKit
import Foundation
import Observation

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
    static let shared = CodeApproval()

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

    init(file: URL = CodeApproval.defaultFile) {
        self.file = file
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            allowedHashes = Set(stored.code)
            allowedProjects = Set(stored.projects)
        }
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
        guard allowedHashes.insert(Self.hash(of: code)).inserted else { return }
        save()
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
            NSLog("Couldn't save the code allowed to run: \(error.localizedDescription)")
        }
    }
}
