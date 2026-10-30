import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The graph editors' skimming: on unless turned off, kept between
/// launches, and showing the frame asked for only while on.
@MainActor
@Suite(.serialized) struct KeyframeGraphSkimmingTests {
    @Test func skimmingIsOnByDefaultAndShowsTheFrameUnderThePointer() async throws {
        let defaults = UserDefaults.standard
        let remembered = defaults.object(forKey: Preferences.graphEditorSkimming)
        defer { defaults.set(remembered, forKey: Preferences.graphEditorSkimming) }
        defaults.removeObject(forKey: Preferences.graphEditorSkimming)

        let hud = KeyframeGraphHUDs()
        #expect(hud.skims)

        // Skimming shows a frame only once the player has an item: here ten
        // seconds of nothing.
        let playback = PlaybackModel()
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)))
        playback.player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        hud.playback = playback

        hud.skim(to: CMTime(value: 2, timescale: 1))
        #expect(playback.skimTime == CMTime(value: 2, timescale: 1))
        hud.skim(to: nil)
        #expect(playback.skimTime == nil)

        // Off, it shows nothing, and stays off for the next panel.
        hud.skims = false
        hud.skim(to: CMTime(value: 3, timescale: 1))
        #expect(playback.skimTime == nil)
        #expect(!KeyframeGraphHUDs().skims)
    }
}
