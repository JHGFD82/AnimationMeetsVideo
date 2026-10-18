import AppKit
import CoreAudio
import Foundation

/// A running app whose sound can be recorded: every process of it that
/// Core Audio knows, helpers included, since a browser plays from its
/// helpers rather than the app itself.
struct AudioApp: Identifiable, Hashable, Sendable {
    /// The app's bundle path, which stays the same while it runs.
    let id: String
    let name: String
    /// Core Audio's objects for its processes.
    let processes: [AudioObjectID]
    /// Whether it is making sound now.
    let isPlaying: Bool
}

/// The apps Core Audio knows as making or able to make sound.
enum AudioApps {
    static func list() -> [AudioApp] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        let own = ProcessInfo.processInfo.processIdentifier
        var byApp: [String: (name: String, processes: [AudioObjectID], playing: Bool)] = [:]
        for object in objects {
            guard let pid = value(kAudioProcessPropertyPID, of: object, as: pid_t.self), pid != own,
                  let app = NSRunningApplication(processIdentifier: pid), let path = app.bundleURL?.path
            else { continue }
            // A helper inside an app counts as the app.
            let appPath = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
            let name = (FileManager.default.displayName(atPath: appPath) as NSString).deletingPathExtension
            let playing = (value(kAudioProcessPropertyIsRunningOutput, of: object, as: UInt32.self) ?? 0) != 0
            var entry = byApp[appPath] ?? (name, [], false)
            entry.processes.append(object)
            entry.playing = entry.playing || playing
            byApp[appPath] = entry
        }
        return byApp.map { AudioApp(id: $0.key, name: $0.value.name, processes: $0.value.processes, isPlaying: $0.value.playing) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.localizedLowercase) < ($1.isPlaying ? 0 : 1, $1.name.localizedLowercase) }
    }

    private static func value<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, as _: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }
}
