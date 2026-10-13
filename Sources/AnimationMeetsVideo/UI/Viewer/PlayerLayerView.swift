import AVFoundation
import SwiftUI

/// A minimal `AVPlayerLayer`-backed video view. AVKit's SwiftUI `VideoPlayer`
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
        // AVPlayerLayer already tone-maps HDR sources correctly by default;
        // requesting the full dynamic range just stops the system from
        // conservatively capping EDR headroom for Rec. 2020 PQ/HLG content.
        // SDR content is unaffected since its values never exceed 1.0.
        if #available(macOS 26.0, *) {
            playerLayer.preferredDynamicRange = .high
        }
        layer = playerLayer
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
