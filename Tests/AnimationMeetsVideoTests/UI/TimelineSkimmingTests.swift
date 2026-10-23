import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

@MainActor private func runLoopPass() { RunLoop.main.run(until: Date()) }

/// Skimming the timeline in the editor as the app hosts it: the pointer
/// moving over the tracks (a mouse-moved event, as the window sends one)
/// shows its time in the viewer and leaves the playhead.
@MainActor
@Suite(.serialized) struct TimelineSkimmingTests {
    /// The editor in a window, playing a 4 s movie, with skimming on or
    /// off, and its timeline's input monitor.
    private func hostEditor(
        skimming: Bool, _ body: (PlaybackModel, NSWindow, NSView) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-timeline-hover-\(UUID().uuidString).mov")
        try await writeMovie(to: url, segments: [(0, 48), (255, 48)])
        defer { try? FileManager.default.removeItem(at: url) }
        var project = EditingProject.empty
        let clip = MediaClip(
            name: "Movie", kind: .video, url: url, duration: CMTime(seconds: 4, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        _ = project.importClip(clip, intoTimeline: project.rootTimelineID)

        let defaults = UserDefaults.standard
        let remembered = defaults.object(forKey: Preferences.timelineSkimming)
        defaults.set(skimming, forKey: Preferences.timelineSkimming)
        defer { defaults.set(remembered, forKey: Preferences.timelineSkimming) }

        let playback = PlaybackModel()
        let bounds = CGRect(x: 0, y: 0, width: 1500, height: 900)
        let host = NSHostingView(rootView: UIResponsivenessBenchmark.Host(
            state: ProjectState(project), history: ProjectHistory(project: project), analysis: AssetAnalysis(),
            replacement: MediaReplacementController(), selection: nil, playback: playback
        ).frame(width: bounds.width, height: bounds.height))
        host.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        NSApplication.shared.setActivationPolicy(.accessory)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        // Long enough for the editor to build its player.
        for _ in 0..<300 where playback.player.currentItem == nil {
            try await Task.sleep(for: .milliseconds(10))
            runLoopPass()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        func monitors(in view: NSView) -> [NSView] {
            (view is TimelineInputMonitor.MonitorView ? [view] : []) + view.subviews.flatMap(monitors)
        }
        let monitor = try #require(monitors(in: host).first)
        #expect(monitor.trackingAreas.contains { $0.options.contains(.mouseMoved) })
        try await body(playback, window, monitor)
    }

    /// Moves the pointer to `x` points into the monitor, halfway down.
    private func movePointer(to x: CGFloat, over monitor: NSView, in window: NSWindow) {
        let rect = monitor.convert(monitor.bounds, to: nil)
        let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: rect.minX + x, y: rect.midY), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        )
        NSApp.sendEvent(try! #require(event))
    }

    /// Clicks `x` points into the monitor, halfway down: a press and a
    /// release in place.
    private func click(at x: CGFloat, over monitor: NSView, in window: NSWindow, flags: NSEvent.ModifierFlags = []) {
        let rect = monitor.convert(monitor.bounds, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: rect.minX + x, y: rect.midY), modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
            NSApp.sendEvent(try! #require(event))
        }
        runLoopPass()
    }

    @Test func clickingInTheTracksMovesThePlayheadThere() async throws {
        try await hostEditor(skimming: true) { playback, window, monitor in
            // With Command, a click picks clips and leaves the playhead.
            click(at: 500, over: monitor, in: window, flags: .command)
            #expect(playback.currentTime == .zero)

            click(at: 500, over: monitor, in: window)
            let first = playback.currentTime
            #expect(first > .zero)
            click(at: 700, over: monitor, in: window)
            #expect(playback.currentTime > first)
        }
    }

    @Test func movingOverTheTracksSkimsAndLeavesThePlayhead() async throws {
        try await hostEditor(skimming: true) { playback, window, monitor in
            movePointer(to: 500, over: monitor, in: window)
            let first = try #require(playback.skimTime)
            movePointer(to: 700, over: monitor, in: window)
            let second = try #require(playback.skimTime)
            #expect(second > first)
            #expect(playback.currentTime == .zero)

            // The names column isn't the tracks.
            movePointer(to: 20, over: monitor, in: window)
            #expect(playback.skimTime == nil)
        }
    }

    @Test func withSkimmingOffThePointerShowsNothing() async throws {
        try await hostEditor(skimming: false) { playback, window, monitor in
            movePointer(to: 500, over: monitor, in: window)
            #expect(playback.skimTime == nil)
        }
    }
}
