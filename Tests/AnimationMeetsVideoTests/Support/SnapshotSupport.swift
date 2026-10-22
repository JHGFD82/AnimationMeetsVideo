import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// Renders views to PNG files, for looking at a UI change without
/// launching the app. Used by `UISnapshots`, which runs only when
/// `SNAPSHOT_DIR` names a folder to write into:
///
///     SNAPSHOT_DIR=/tmp/snaps swift test --filter UISnapshots
///
/// Nothing is compared; the pictures are for a person (or an agent) to
/// read. Offscreen, a few things draw differently from a window on
/// screen: the window is never key, so prominent buttons draw unfilled,
/// and a Settings scene's toolbar tabs draw as a blank placeholder.
@MainActor
enum SnapshotSupport {
    nonisolated static var directory: URL? {
        ProcessInfo.processInfo.environment["SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    nonisolated static var isEnabled: Bool { directory != nil }

    /// Draws `view` at `size`, in the editor's dark appearance, to
    /// `<SNAPSHOT_DIR>/<name>.png`.
    static func render<V: View>(_ view: V, _ name: String, size: CGSize) throws {
        guard directory != nil else { return }
        let (window, host) = hosting(view, size: size)
        // Lets tasks started on appear (loading, measuring) land first.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try capture(host, name)
        _ = window
    }

    /// The same, after `settle` seconds of letting the main actor run. A
    /// view whose pictures load in tasks that finish on the main actor
    /// (thumbnails) needs this: running the run loop from a test, which is
    /// itself on the main actor, never lets them finish.
    static func render<V: View>(_ view: V, _ name: String, size: CGSize, settle: Duration) async throws {
        guard directory != nil else { return }
        let (window, host) = hosting(view, size: size)
        try await Task.sleep(for: settle)
        try capture(host, name)
        _ = window
    }

    private static func hosting<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private static func capture(_ host: NSView, _ name: String) throws {
        guard let directory else { return }
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// A song to draw: a click every half second (120 BPM) with every
    /// fourth one louder, over a quiet hum, written to `<name>.caf` in
    /// the snapshot folder. Each caller names its own file, so tests
    /// running side by side don't write over each other's.
    static func clickSong(named name: String, seconds: Double = 40) throws -> MediaClip {
        let directory = directory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".caf")
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)))
        buffer.frameLength = buffer.frameCapacity
        let data = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { data[index] = 0.02 * sin(Float(index) * 0.05) }
        var time = 0.25
        var count = 0
        while time < seconds - 0.1 {
            let start = Int(time * rate)
            let level: Float = count % 4 == 0 ? 0.9 : 0.5
            for offset in 0..<800 {
                let decay: Float = exp(-Float(offset) / 120)
                let ring: Float = sin(Float(offset) * 0.3)
                data[start + offset] += level * decay * ring
            }
            time += 0.5
            count += 1
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return MediaClip(
            name: "Song.caf", kind: .audio, url: url, duration: CMTime(seconds: seconds, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Test", acceptedStamp: FileStamp(url: url)
        )
    }
}
