import AppKit
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The viewer's picture follows its zoom and place as soon as they
/// change, with nothing else changing: a pinch, a scroll or a zoom key
/// is all there is to draw it again for.
@MainActor
@Suite(.serialized) struct ViewerFramingRedrawTests {
    private static let well = CGSize(width: 800, height: 450)
    private static let frame = CGSize(width: 1920, height: 1080)

    /// The picture's view in a window, and the framing that places it.
    private func show(_ framing: ViewerFraming) -> (window: NSWindow, picture: () -> NSView?) {
        let content = FramedPicture(playback: PlaybackModel(), frameRate: 24, frameSize: Self.frame, framing: framing)
            .frame(width: Self.well.width, height: Self.well.height)
        let view = NSHostingView(rootView: content)
        view.frame = CGRect(origin: .zero, size: Self.well)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        NSApplication.shared.setActivationPolicy(.accessory)
        window.orderFront(nil)
        func find(_ view: NSView) -> NSView? {
            if view is ViewerLayerHostView { return view }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return (window, { find(view) })
    }

    private func settle(seconds: Double = 0.3) async {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            try? await Task.sleep(for: .milliseconds(10))
            autoreleasepool { RunLoop.main.run(until: Date()) }
        } while Date() < end
    }

    @Test func thePictureFollowsAZoomAtOnce() async throws {
        let framing = ViewerFraming()
        let shown = show(framing)
        defer { shown.window.close() }
        await settle()
        let fitted = try #require(shown.picture()).frame.width
        let current = try #require(framing.current)
        framing.apply(current.zoomed(to: current.effectiveZoom * 2, about: CGPoint(x: Self.well.width / 2, y: Self.well.height / 2)))
        await settle()
        let zoomed = try #require(shown.picture()).frame.width
        #expect(abs(zoomed - fitted * 2) < 2, "\(fitted) → \(zoomed)")
    }

    @Test func thePictureFollowsAScrollAtOnce() async throws {
        let framing = ViewerFraming()
        let shown = show(framing)
        defer { shown.window.close() }
        await settle()
        let current = try #require(framing.current)
        framing.apply(current.zoomed(to: current.effectiveZoom * 2, about: CGPoint(x: Self.well.width / 2, y: Self.well.height / 2)))
        await settle()
        let before = try #require(shown.picture()).convert(CGPoint.zero, to: nil).x
        framing.apply(try #require(framing.current).scrolled(by: CGVector(dx: 40, dy: 0)))
        await settle()
        let after = try #require(shown.picture()).convert(CGPoint.zero, to: nil).x
        #expect(abs(after - before - 40) < 1, "\(before) → \(after)")
    }
}
