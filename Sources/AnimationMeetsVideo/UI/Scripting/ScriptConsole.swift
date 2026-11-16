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
            // A system text view: VoiceOver reads it as one text, by
            // character, word or line, and a selection spans entries. On
            // the well, where the error tone reads at 5.2:1.
            TranscriptView(entries: transcript.entries)
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
                    .accessibilityHint("Return runs it on the project in the front window. Up and down arrows step through earlier lines. Escape or Command-Period stops a line that is running.")
                    // Kept enabled while a line runs, so it keeps the
                    // keyboard and Escape reaches it; submit() waits.
                    .onExitCommand { if runner.isRunning { runner.stop() } }
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
            // What came of it is said, so it needn't be looked for.
            switch outcome {
            case .failed(let failure): AccessibilityNotification.Announcement("Error: \(failure.summary)").post()
            case .couldNotRun(let reason): AccessibilityNotification.Announcement("Couldn't run: \(reason)").post()
            case .projectChanged: AccessibilityNotification.Announcement("The project changed while it ran; nothing was kept").post()
            case .finished:
                let said = transcript.entries.last.flatMap { $0.kind == .input ? nil : $0.text }
                AccessibilityNotification.Announcement(said.map { String($0.prefix(300)) } ?? "Done").post()
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

/// The console's transcript, as a read-only system text view: lines typed
/// in the secondary tone after ">>> ", printed text and values in the
/// primary one, errors in the error tone, a problem the app reports
/// after "Error:", and notes in the warning tone. It scrolls to the end
/// as entries come.
private struct TranscriptView: NSViewRepresentable {
    let entries: [ScriptTranscript.Entry]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Design.Surface.well.color)
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = true
            text.backgroundColor = NSColor(Design.Surface.well.color)
            text.textContainerInset = NSSize(width: Design.Space.step, height: Design.Space.step)
            text.setAccessibilityLabel("Console output")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let ids = entries.map(\.id)
        // Most updates add to the end; a whole new text only when it changed.
        guard ids != context.coordinator.shown || entries.last?.text != context.coordinator.lastText else { return }
        context.coordinator.shown = ids
        context.coordinator.lastText = entries.last?.text
        text.textStorage?.setAttributedString(Self.attributed(entries))
        text.scrollToEndOfDocument(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: [UUID] = []
        var lastText: String?
    }

    static func attributed(_ entries: [ScriptTranscript.Entry]) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString()
        for entry in entries {
            var text = entry.text.hasSuffix("\n") ? String(entry.text.dropLast()) : entry.text
            let color: Color
            switch entry.kind {
            case .input:
                text = ">>> " + text
                color = Design.textSecondary
            case .output, .result: color = Design.textPrimary
            case .errorOutput: color = Design.statusDanger
            case .error:
                // A traceback ends naming its error; a problem says so.
                if !text.hasPrefix("Traceback"), !text.contains("Error:") { text = "Error: " + text }
                color = Design.statusDanger
            case .note: color = Design.statusWarning
            }
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: NSColor(color)]))
        }
        return result
    }
}
