import AVFoundation
import SwiftUI

/// The timeline's picture: a layer showing what `ViewerDisplay` shows,
/// the viewer's one painter. Several can show the same display, as the
/// synced external display does.
struct ViewerLayerView: NSViewRepresentable {
    let display: ViewerDisplay

    func makeNSView(context: Context) -> ViewerLayerHostView {
        ViewerLayerHostView(viewerDisplay: display)
    }

    func updateNSView(_ nsView: ViewerLayerHostView, context: Context) {
        nsView.viewerDisplay = display
    }
}

final class ViewerLayerHostView: NSView {
    private let pictureLayer = CALayer()

    var viewerDisplay: ViewerDisplay {
        didSet {
            guard viewerDisplay !== oldValue else { return }
            oldValue.detach(pictureLayer, host: self)
            if window != nil { viewerDisplay.attach(pictureLayer, host: self) }
        }
    }

    init(viewerDisplay: ViewerDisplay) {
        self.viewerDisplay = viewerDisplay
        super.init(frame: .zero)
        wantsLayer = true
        pictureLayer.contentsGravity = .resizeAspect
        // HDR timelines' frames carry values above 1.0.
        pictureLayer.wantsExtendedDynamicRangeContent = true
        layer = pictureLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            viewerDisplay.attach(pictureLayer, host: self)
        } else {
            viewerDisplay.detach(pictureLayer, host: self)
        }
    }
}

/// A minimal `AVPlayerLayer`-backed video view, for players other than the
/// timeline's (a clip skimmed in the browser). AVKit's SwiftUI `VideoPlayer`
/// wraps a private class that fails to load in this unbundled SwiftPM
/// executable (no .app bundle for the Objective-C runtime to resolve
/// against), so playback goes through the public `AVPlayerLayer` API instead.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        if #available(macOS 26.0, *) {
            playerLayer.preferredDynamicRange = .high
        }
        layer = playerLayer
    }
}
