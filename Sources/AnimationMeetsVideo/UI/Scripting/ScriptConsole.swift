import AppKit
import Observation
import SwiftUI

extension EnvironmentValues {
    /// Where scripts read what a project's window shows (see
    /// `ScriptWindowState`); set only in the project's own window.
    @Entry var scriptWindow: ScriptWindowState?
}

/// The Python Console's floating panel (Scripts > Python Console): output
/// above, one input line below. Each line entered is a run of its own on
/// the project in the front window, so each is an undo step when it
/// changed something; names set on one line are there on the next. What
/// scripts print, and their tracebacks, come here too.
@MainActor
final class ScriptConsoleWindow {
    static let shared = ScriptConsoleWindow()

    private var panel: NSPanel?
    private var closeWatcher: ConsoleCloseWatcher?

    var isOpen: Bool { panel != nil }

    /// Opens the panel, or brings it to the front.
    func show() {
        UserDefaults.standard.set(true, forKey: Preferences.showsScriptConsole)
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Python Console"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 360, height: 200)
        panel.contentView = NSHostingView(rootView: ScriptConsole(transcript: .shared, runner: .shared))
        let watcher = ConsoleCloseWatcher { [weak self] in self?.didClose() }
        panel.delegate = watcher
        panel.center()
        panel.setFrameAutosaveName("PythonConsole")
        self.panel = panel
        closeWatcher = watcher
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    private func didClose() {
        UserDefaults.standard.set(false, forKey: Preferences.showsScriptConsole)
        panel = nil
        closeWatcher = nil
    }

    /// The project a line runs on: the one in the front editor window,
    /// which stays the main window while the console has the keyboard.
    static func frontSession() -> ProjectSession? {
        let sessions = ProjectWindows.shared.sessions.filter { !$0.isEmpty }
        if let main = NSApp.mainWindow, let session = sessions.first(where: { $0.editorWindow === main }) {
            return session
        }
        return sessions.first
    }
}

private final class ConsoleCloseWatcher: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}

/// The console's content.
struct ScriptConsole: View {
    let transcript: ScriptTranscript
    let runner: ScriptRunner
    @State private var line = ""
    /// Where the up and down arrows are in the history; nil on a new line.
    @State private var historyIndex: Int?
    /// Whether the next line starts the console's names afresh.
    @State private var fresh = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(transcript.entries) { entry in
                            EntryRow(entry: entry).id(entry.id)
                        }
                    }
                    .padding(Design.Space.step)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: transcript.entries.last?.id) { _, last in
                    if let last { scroller.scrollTo(last, anchor: .bottom) }
                }
            }
            .accessibilityLabel("Console output")
            Groove()
            HStack(spacing: Design.Space.step) {
                Text(verbatim: ">>>")
                    .font(Design.Typeface.numeric)
                    .foregroundStyle(Design.textSecondary)
                    .accessibilityHidden(true)
                TextField("Python", text: $line)
                    .textFieldStyle(.plain)
                    .font(Design.Typeface.numeric)
                    .foregroundStyle(Design.textPrimary)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { step(-1) }
                    .onKeyPress(.downArrow) { step(1) }
                    .accessibilityLabel("Python line")
                    .accessibilityHint("Return runs it on the project in the front window. Up and down arrows step through earlier lines.")
                    .disabled(runner.isRunning)
                if runner.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop", action: runner.stop)
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Clear") {
                        transcript.clear()
                        fresh = true
                    }
                    .help("Clears the output and forgets the names set so far")
                }
            }
            .padding(Design.Space.step)
        }
        .background(Design.Surface.floating.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        .onExitCommand { runner.stop() }
        .onAppear { inputFocused = true }
    }

    private func submit() {
        let code = line
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty, !runner.isRunning else { return }
        transcript.append(.input(code))
        line = ""
        historyIndex = nil
        guard let session = ScriptConsoleWindow.frontSession() else {
            transcript.append(.problem("Open a project to run Python on it."))
            return
        }
        let request = HelperRequest(kind: .line, code: code, freshConsole: fresh)
        fresh = false
        Task {
            let outcome = await runner.run(request, named: "Console", on: ScriptTarget(session: session))
            if case .failed(let failure) = outcome {
                AccessibilityNotification.Announcement(failure.summary).post()
            }
            inputFocused = true
        }
    }

    /// Steps through the lines typed before.
    private func step(_ direction: Int) -> KeyPress.Result {
        let history = transcript.history
        guard !history.isEmpty else { return .ignored }
        let next = (historyIndex ?? history.count) + direction
        if next >= history.count {
            historyIndex = nil
            line = ""
        } else {
            historyIndex = max(next, 0)
            line = history[historyIndex!]
        }
        return .handled
    }
}

/// One entry of the console's transcript.
private struct EntryRow: View {
    let entry: ScriptTranscript.Entry

    var body: some View {
        Text(verbatim: shown)
            .font(Design.Typeface.numeric)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(accessibilityText)
    }

    private var shown: String {
        let text = entry.text.hasSuffix("\n") ? String(entry.text.dropLast()) : entry.text
        return entry.kind == .input ? ">>> " + text : text
    }

    private var color: Color {
        switch entry.kind {
        case .input: Design.textSecondary
        case .output, .result: Design.textPrimary
        case .errorOutput, .error: Design.statusDanger
        case .note: Design.statusWarning
        }
    }

    private var accessibilityText: String {
        switch entry.kind {
        case .input: "You typed: \(entry.text)"
        case .error: "Error: \(entry.text)"
        case .note: "Note: \(entry.text)"
        default: entry.text
        }
    }
}
