import Foundation

/// A name made fit to be one file's name in a folder the app chose: no
/// path separators or colons (a name of `../../Desktop/x` made a package
/// copy outside the Effects folder), no leading or trailing dots or spaces
/// (`..`, or a hidden file), and never empty. Names come from projects,
/// packages and backups the person may not have made (code-review-notes.md,
/// F51).
enum SafeFileName {
    static func make(_ name: String, fallback: String) -> String {
        let cleaned = String(name.map { "/:\\".contains($0) ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? fallback : cleaned
    }
}
