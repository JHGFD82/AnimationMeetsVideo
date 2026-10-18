import CoreAudio
import Foundation
import Observation

/// A device sound can play out of, as Core Audio's hardware layer lists it.
struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    let id: AudioObjectID
    /// What stays the same across launches and replugging; what the
    /// preferences store.
    let uid: String
    let name: String
}

/// The machine's output devices, and which ones the editor's sound and its
/// beat tick are set to play out of. See docs/audio.md, "Output devices".
enum AudioDevices {
    /// Every device with somewhere to send sound, in the system's order.
    static func outputs() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // Hidden devices are the system's own, such as the aggregate it
            // makes for the default device.
            guard hasOutput(id), !isHidden(id), let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id)
            else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
    }

    /// The device with `uid`, if it is plugged in now.
    static func device(uid: String) -> AudioOutputDevice? {
        outputs().first { $0.uid == uid }
    }

    /// The device the editor's sound plays out of: the one chosen in
    /// Settings while it is plugged in, or nil for the system's default.
    static var playbackUID: String? {
        chosen(UserDefaults.standard.string(forKey: Preferences.playbackOutputDevice))
    }

    /// The device the beat tick plays out of: its own choice, or the
    /// editor's sound's.
    static var clicksUID: String? {
        chosen(UserDefaults.standard.string(forKey: Preferences.clickOutputDevice)) ?? playbackUID
    }

    private static func chosen(_ uid: String?) -> String? {
        guard let uid, !uid.isEmpty, device(uid: uid) != nil else { return nil }
        return uid
    }

    /// Calls `handler` on the main queue whenever a device is plugged in or
    /// out. Keep the returned token for as long as it should be called.
    static func observe(_ handler: @escaping @MainActor () -> Void) -> DeviceListObservation {
        DeviceListObservation(handler)
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Hears devices being plugged in and out until it is let go of.
final class DeviceListObservation {
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    private let block: AudioObjectPropertyListenerBlock

    fileprivate init(_ handler: @escaping @MainActor () -> Void) {
        block = { _, _ in MainActor.assumeIsolated { handler() } }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}

/// The output devices, kept up to date for a view to list.
@MainActor
@Observable
final class AudioDeviceList {
    private(set) var devices: [AudioOutputDevice] = AudioDevices.outputs()
    @ObservationIgnored private var observation: DeviceListObservation?

    init() {
        observation = AudioDevices.observe { [weak self] in self?.devices = AudioDevices.outputs() }
    }
}
