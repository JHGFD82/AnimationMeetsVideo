import AVFoundation
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite(.serialized) struct AudioDevicesTests {
    @Test func devicesHaveNamesAndIDs() {
        for device in AudioDevices.outputs() {
            #expect(!device.uid.isEmpty)
            #expect(!device.name.isEmpty)
            #expect(AudioDevices.device(uid: device.uid) == device)
        }
        #expect(AudioDevices.device(uid: "no-such-device") == nil)
    }

    /// A chosen device that isn't plugged in plays out of the default, and
    /// the tick follows playback unless it has its own.
    @Test func anUnpluggedChoiceFallsBackToTheDefault() {
        let defaults = UserDefaults.standard
        let keys = [Preferences.playbackOutputDevice, Preferences.clickOutputDevice]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }

        defaults.set("no-such-device", forKey: Preferences.playbackOutputDevice)
        defaults.set("", forKey: Preferences.clickOutputDevice)
        #expect(AudioDevices.playbackUID == nil)
        #expect(AudioDevices.clicksUID == nil)

        guard let device = AudioDevices.outputs().first else { return }
        defaults.set(device.uid, forKey: Preferences.playbackOutputDevice)
        #expect(AudioDevices.playbackUID == device.uid)
        #expect(AudioDevices.clicksUID == device.uid)
    }

    /// Moving the tick doesn't wait for the device: a sleeping one can
    /// take seconds to wake. Only made-up and default devices here, so the
    /// tests don't wake the machine's own.
    @MainActor @Test func theTickMovesWithoutWaiting() async throws {
        let clicks = BeatClickPlayer(player: AVPlayer())
        clicks.isEnabled = true
        let start = Date()
        clicks.outputDeviceUID = "no-such-device"
        clicks.outputDeviceUID = nil
        #expect(Date().timeIntervalSince(start) < 0.5)
        try await Task.sleep(for: .milliseconds(300))
        clicks.isEnabled = false
    }
}
