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
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.player = player
    }
}

final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    /// The outgoing item's last frame, shown over the video while a paused
    /// player swaps items. Between the swap and the new item's first frame
    /// the layer has no picture, so without it every rebuild (each
    /// finished background render, each edit) blinks the viewer.
    private let heldFrame = CALayer()
    private var heldBuffer: CVPixelBuffer?
    private var heldSince: CFTimeInterval = 0
    private var releaseTimer: Timer?
    private var itemObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?

    /// The longest a frame is held, in case the new item never shows one.
    private static let maxHold: CFTimeInterval = 1

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            guard newValue !== playerLayer.player else { return }
            releaseFrame()
            playerLayer.player = newValue
            // The prior notification arrives before the item changes,
            // while the old frame is still on screen.
            itemObservation = newValue?.observe(\.currentItem, options: [.prior]) { [weak self] _, change in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated {
                    if change.isPrior { self?.holdFrame() } else { self?.releaseFrameIfReplaced() }
                }
            }
        }
    }

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
        heldFrame.contentsGravity = .resizeAspect
        heldFrame.zPosition = 1
        heldFrame.isHidden = true
        playerLayer.addSublayer(heldFrame)
        readyObservation = playerLayer.observe(\.isReadyForDisplay) { [weak self] _, _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated { self?.releaseFrameIfReplaced() }
        }
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heldFrame.frame = playerLayer.bounds
        CATransaction.commit()
    }

    /// Covers the video with the frame it shows now. Only while paused:
    /// the layer hands out its frame only then, and a playing swap is
    /// already a visible jump.
    private func holdFrame() {
        guard let player = playerLayer.player, player.rate == 0,
              let buffer = playerLayer.displayedPixelBuffer(),
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue()
        else { return }
        heldBuffer = buffer
        heldSince = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heldFrame.contents = surface
        heldFrame.isHidden = false
        CATransaction.commit()
        // The layer doesn't say when it shows a new frame, so check each
        // screen refresh until it does.
        if releaseTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseFrameIfReplaced() }
            }
            RunLoop.main.add(timer, forMode: .common)
            releaseTimer = timer
        }
    }

    /// Uncovers the video once it shows a frame other than the held one,
    /// or playback starts, or the hold has gone on too long.
    private func releaseFrameIfReplaced() {
        guard let heldBuffer else { return }
        let playing = (playerLayer.player?.rate ?? 0) != 0
        let shown = playerLayer.displayedPixelBuffer()
        if playing || playerLayer.player == nil
            || CACurrentMediaTime() - heldSince > Self.maxHold
            || (shown != nil && shown !== heldBuffer) {
            releaseFrame()
        }
    }

    private func releaseFrame() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        heldBuffer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heldFrame.isHidden = true
        heldFrame.contents = nil
        CATransaction.commit()
    }
}
