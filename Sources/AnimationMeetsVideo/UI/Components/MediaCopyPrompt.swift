import AppKit

/// Asks before copying media into a project when the copy uses real disk
/// space because the files are on a different volume. Same-volume copies
/// are APFS clones that cost nothing, so they are never asked about.
enum MediaCopyPrompt {
    enum Choice {
        case copy, referenceInPlace
    }

    /// Nil when the person cancels.
    @MainActor
    static func ask(fileCount: Int, byteCount: Int64) -> Choice? {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Copy \(fileCount) media file\(fileCount == 1 ? "" : "s") into the project?"
        alert.informativeText = "\(size) will be copied because the files are on a different volume than the project, so it uses real disk space. You can leave them where they are and the project will reference them in place."
        alert.addButton(withTitle: "Copy \(size)")
        alert.addButton(withTitle: "Reference in Place")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .copy
        case .alertSecondButtonReturn: return .referenceInPlace
        default: return nil
        }
    }
}
