import CoreMedia
import Foundation
import Observation
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// What the viewer panel's own body reads from the player. The time
/// changes 30 times a second while playing, so the panel must leave it to
/// the small views that show it, or every tick rebuilds the whole panel.
@MainActor
@Suite struct ViewerPanelTrackingTests {
    /// Evaluates the panel's body (not its children's) and says whether
    /// `change` would make SwiftUI evaluate it again.
    private func bodyIsInvalidated(by change: (PlaybackModel) -> Void) -> Bool {
        let playback = PlaybackModel()
        let panel = ViewerPanel(
            playback: playback, hasContent: true, frameSize: CGSize(width: 1920, height: 1080),
            frameRate: 24, buildError: nil, trimPreview: TrimPreviewModel()
        )
        let invalidated = Flag()
        withObservationTracking {
            _ = panel.body
        } onChange: {
            invalidated.isSet = true
        }
        change(playback)
        return invalidated.isSet
    }

    /// Set from the tracking callback, which runs synchronously on the
    /// change, here on the main thread.
    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    @Test func theTimeMovingLeavesThePanelAlone() {
        let invalidated = bodyIsInvalidated { $0.seek(to: CMTime(value: 5, timescale: 1)) }
        #expect(!invalidated)
    }

    /// The check above means something only if the panel does follow
    /// what it reads itself, such as the quality.
    @Test func whatThePanelShowsStillUpdatesIt() {
        let key = Preferences.previewQuality
        let remembered = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(remembered, forKey: key) }
        let invalidated = bodyIsInvalidated { playback in
            playback.quality = playback.quality == .auto ? .full : .auto
        }
        #expect(invalidated)
    }
}
