import Foundation

/// The projects opened or saved most recently, newest first, for File >
/// Open Recent and the start sheet. Kept as a JSON list of paths in one
/// defaults string (`Preferences.recentProjects`), so a view can follow it
/// with `@AppStorage`.
struct RecentProjects: Equatable {
    static let limit = 10

    private(set) var paths: [String]

    init(paths: [String] = []) {
        self.paths = Array(paths.prefix(Self.limit))
    }

    /// Reads what `stored` wrote; anything unreadable is an empty list.
    init(stored: String) {
        let decoded = stored.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        self.init(paths: decoded ?? [])
    }

    var stored: String {
        (try? JSONEncoder().encode(paths)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    var urls: [URL] {
        paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Puts `url` first, once, dropping the oldest past the limit.
    mutating func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
    }

    mutating func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        paths.removeAll { $0 == path }
    }

    /// The name a project is shown by: its package's, without `.amv`.
    static func name(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Where a project is, for telling two of the same name apart: its
    /// folder, with the home folder as ~.
    static func location(of url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}
