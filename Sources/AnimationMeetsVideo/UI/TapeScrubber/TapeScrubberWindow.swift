import AppKit
import Observation
import SwiftUI

/// The Tape Scrubber's floating panel, opened from the Window menu. Its
/// sound engine runs while it is open (`PlaybackModel.openTape`), so the
/// dial is heard the moment it is grabbed.
@MainActor
@Observable
final class TapeScrubberWindow {
    /// Whether the editor shows the Main timeline, the only one the
    /// scrubber plays.
    var isMainTimeline = true
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var playback: PlaybackModel?
    @ObservationIgnored private var closeWatcher: CloseWatcher?

    /// Opens the panel, or brings it to the front.
    func show(playback: PlaybackModel) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: TapeScrubberView.slit.width + 64, height: TapeScrubberView.slit.height + 64),
            styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The box is all there is: the title is in the Window menu, not
        // over the box.
        panel.title = "Tape Scrubber"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = FirstMouseHostingView(rootView: TapeScrubberContent(window: self, playback: playback))
        let watcher = CloseWatcher { [weak self] in self?.didClose() }
        panel.delegate = watcher
        panel.center()
        panel.setFrameAutosaveName("TapeScrubber")
        self.panel = panel
        self.playback = playback
        closeWatcher = watcher
        playback.openTape()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    private func didClose() {
        playback?.closeTape()
        panel = nil
        playback = nil
        closeWatcher = nil
    }
}

/// Reads whether Main is open from the window, so the dial follows it.
private struct TapeScrubberContent: View {
    let window: TapeScrubberWindow
    let playback: PlaybackModel

    var body: some View {
        TapeScrubberView(playback: playback, isAvailable: window.isMainTimeline)
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }
}

/// A click on the dial turns it at once, even when the panel isn't the
/// key window yet.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class CloseWatcher: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
