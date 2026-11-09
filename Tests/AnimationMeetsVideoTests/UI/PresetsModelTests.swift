import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Undoing a preset's deletion puts its file back from the Trash. The
/// Trash itself isn't used here, so nothing lands in the person's.
@MainActor
@Suite struct PresetsModelTests {
    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func undoingADeletionPutsThePresetBackAndCanBeRedone() throws {
        let presets = try folder("presets"), trash = try folder("trash")
        defer {
            try? FileManager.default.removeItem(at: presets)
            try? FileManager.default.removeItem(at: trash)
        }
        let original = presets.appending(path: "Look.json")
        let trashed = trash.appending(path: "Look.json")
        try Data("{}".utf8).write(to: trashed)
        let model = PresetsModel(folder: presets)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        model.untrash(trashed, to: original, undoManager: undoManager)
        undoManager.endUndoGrouping()

        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
        // Redone, it goes back to the Trash.
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "Delete Preset")
    }

    @Test func aPresetThatCantGoBackIsLeftWhereItIs() throws {
        let presets = try folder("presets"), trash = try folder("trash")
        defer {
            try? FileManager.default.removeItem(at: presets)
            try? FileManager.default.removeItem(at: trash)
        }
        // Another preset has its name now.
        let original = presets.appending(path: "Look.json")
        try Data("{}".utf8).write(to: original)
        let trashed = trash.appending(path: "Look.json")
        try Data("{}".utf8).write(to: trashed)
        let model = PresetsModel(folder: presets)
        let undoManager = UndoManager()

        model.untrash(trashed, to: original, undoManager: undoManager)

        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(!undoManager.canUndo)
    }
}
