import AppKit
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Which open project the Python Console runs a line on
/// (code-review-notes.md, F35). It took the project whose own window was
/// the main window and otherwise the first project opened, so with a
/// timeline window in front a line edited another project, which
/// autosave then saved.
@MainActor
@Suite(.serialized) struct FrontProjectTests {
    @MainActor private final class Opened {
        let folder: URL
        let session = ProjectSession()
        let editor = FrontProjectTests.window()

        init(named name: String) async throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "amv-front-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "\(name).amv", directoryHint: .isDirectory)
            try ProjectStore.preparePackage(at: url)
            try await ProjectStore.save(.empty, to: url)
            #expect(await session.open(url))
            session.editorWindow = editor
        }

        func close() {
            session.close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A window that is never shown, standing in for a project's.
    fileprivate static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func chosen(_ front: ProjectWindows.FrontProject) -> ProjectSession? {
        if case .project(let session) = front { return session }
        return nil
    }

    @Test func aTimelineWindowInFrontRunsOnItsOwnProject() async throws {
        let first = try await Opened(named: "First")
        let second = try await Opened(named: "Second")
        defer { first.close(); second.close() }
        let timeline = Self.window()
        second.session.addTimelineWindow(timeline, showing: ScriptWindowState())
        let sessions = [first.session, second.session]

        // Before the fix this was the first project opened.
        #expect(chosen(ProjectWindows.frontProject(among: sessions, mainWindow: timeline)) === second.session)
        #expect(chosen(ProjectWindows.frontProject(among: sessions, mainWindow: first.editor)) === first.session)
        #expect(chosen(ProjectWindows.frontProject(among: sessions, mainWindow: second.editor)) === second.session)
        #expect(ScriptConsoleWindow.title(for: .project(second.session)) == "Python Console \u{2014} Second")
    }

    @Test func withSeveralOpenAndNoneOfTheirsInFrontNothingIsGuessed() async throws {
        let first = try await Opened(named: "First")
        let second = try await Opened(named: "Second")
        defer { first.close(); second.close() }
        let sessions = [first.session, second.session]

        for main in [Self.window(), nil] {
            guard case .unclear = ProjectWindows.frontProject(among: sessions, mainWindow: main) else {
                Issue.record("A project was chosen with none of theirs in front")
                continue
            }
        }
        #expect(ScriptConsoleWindow.problem(with: .unclear) != nil)
        #expect(ScriptConsoleWindow.title(for: .unclear) == "Python Console")
    }

    @Test func theOnlyOpenProjectIsChosenWhateverIsInFront() async throws {
        let only = try await Opened(named: "Only")
        defer { only.close() }
        let empty = ProjectSession()
        let sessions = [empty, only.session]

        #expect(chosen(ProjectWindows.frontProject(among: sessions, mainWindow: nil)) === only.session)
        #expect(chosen(ProjectWindows.frontProject(among: sessions, mainWindow: Self.window())) === only.session)
        guard case .none = ProjectWindows.frontProject(among: [empty], mainWindow: nil) else {
            Issue.record("A project was chosen with none open")
            return
        }
    }

    @Test func aTimelineWindowIsItsProjectsOnly() async throws {
        let first = try await Opened(named: "First")
        let second = try await Opened(named: "Second")
        defer { first.close(); second.close() }
        let timeline = Self.window()
        second.session.addTimelineWindow(timeline, showing: ScriptWindowState())
        second.session.addTimelineWindow(timeline, showing: ScriptWindowState())
        second.session.addTimelineWindow(nil, showing: ScriptWindowState())
        #expect(second.session.owns(timeline))
        #expect(!first.session.owns(timeline))
        #expect(!second.session.owns(Self.window()))
    }

    /// A line run with a timeline window in front acts on what is selected
    /// there, not in the project's own window.
    @Test func aTimelineWindowsRunReadsItsOwnSelection() async throws {
        let opened = try await Opened(named: "Cut")
        defer { opened.close() }
        let timeline = Self.window()
        let shown = ScriptWindowState()
        let picked = UUID()
        shown.groupSelection = [picked]
        opened.session.scriptWindow.groupSelection = [UUID()]
        opened.session.addTimelineWindow(timeline, showing: shown)

        #expect(opened.session.scriptWindow(in: timeline) === shown)
        #expect(opened.session.scriptWindow(in: opened.editor) === opened.session.scriptWindow)
        #expect(opened.session.scriptWindow(in: nil) === opened.session.scriptWindow)
        #expect(opened.session.scriptWindow(in: Self.window()) === opened.session.scriptWindow)
    }
}
