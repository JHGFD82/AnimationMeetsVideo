import SwiftUI

/// Ends a browser skim once the person has gone back to the timeline: a
/// click in a panel other than the browser or the viewer (the viewer's own
/// transport plays the skim), or the timeline starting to play by any
/// route. The browser's own ending (the pointer leaving it, or it losing
/// the keyboard) misses a click on the timeline, which never takes the
/// keyboard, and so left the viewer frozen on the browser's frame while
/// the timeline played under it.
///
/// A modifier of its own, so only it, and not the whole surface, reads the
/// active panel and redraws when it changes (as `ActivePanelPublisher`).
struct BrowserSkimEnding: ViewModifier {
    let active: ActivePanel
    let playback: PlaybackModel
    @Environment(BrowserSkim.self) private var skim: BrowserSkim?

    func body(content: Content) -> some View {
        content
            .onChange(of: active.current) { _, panel in
                if Self.endsSkim(panel) { skim?.end() }
            }
            // Skimming stops the timeline's play (`ViewerPanel`); the
            // timeline playing again ends the skim, so the two never show
            // at once.
            .onChange(of: playback.isPlaying) { _, playing in
                if playing { skim?.end() }
            }
    }

    /// Whether making `panel` active ends a skim: every panel but the
    /// browser it came from and the viewer showing it.
    static func endsSkim(_ panel: EditorPanel) -> Bool {
        panel != .browser && panel != .viewer
    }
}
