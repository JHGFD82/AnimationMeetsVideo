import AVFoundation
import SwiftUI

/// A minimal `AVPlayerLayer`-backed video view. AVKit's SwiftUI `VideoPlayer`
/// wraps a private class that fails to load in this unbundled SwiftPM
/// executable (no .app bundle for the Objective-C runtime to resolve
/// against), so playback goes through the public `AVPlayerLayer` API instead.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    /// A full-size picture of the paused frame, shown over the video.
    var still: CGImage?

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.player = player
        view.still = still
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.player = player
        nsView.still = still
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
    /// Shows `still` above both the video and the held frame.
    private let stillLayer = CALayer()
    private var readyObservation: NSKeyValueObservation?

    /// How long a frame is held before the new item is nudged to draw.
    /// A paused player holds back a new item's first picture until its
    /// sound is ready, about half a second for a clip with sound and
    /// longer on some audio devices (prerolling usually gets it there at
    /// once), so this is generous: an uncovered layer shows nothing at
    /// all, and after a render the held frame is the same picture anyway.
    private static let maxHold: CFTimeInterval = 5
    /// Whether the new item has been nudged; if it still hasn't drawn by
    /// the next timeout, the frame is let go.
    private var nudged = false

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

    var still: CGImage? {
        didSet {
            guard still !== oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillLayer.contents = still
            stillLayer.isHidden = still == nil
            CATransaction.commit()
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
        stillLayer.contentsGravity = .resizeAspect
        stillLayer.zPosition = 2
        // HDR timelines' stills carry values above 1.0, like the video.
        stillLayer.wantsExtendedDynamicRangeContent = true
        stillLayer.isHidden = true
        playerLayer.addSublayer(stillLayer)
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
        stillLayer.frame = playerLayer.bounds
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
        nudged = false
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
    /// or playback starts, or there is no item to wait for. A new item
    /// that hasn't drawn by `maxHold` is seeked to where it is and
    /// prerolled, which makes a paused player draw; uncovering it instead
    /// would show black until the next play or scrub. Only if that fails
    /// too is the frame let go.
    private func releaseFrameIfReplaced() {
        guard let heldBuffer else { return }
        let playing = (playerLayer.player?.rate ?? 0) != 0
        let shown = playerLayer.displayedPixelBuffer()
        if playing || playerLayer.player?.currentItem == nil || (shown != nil && shown !== heldBuffer) {
            releaseFrame()
            return
        }
        guard CACurrentMediaTime() - heldSince > Self.maxHold else { return }
        if !nudged, let item = playerLayer.player?.currentItem {
            NSLog("Viewer: a swapped-in item hadn't drawn after \(Self.maxHold) s; seeking it to redraw")
            nudged = true
            heldSince = CACurrentMediaTime()
            item.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                guard finished else { return }
                Task { @MainActor in
                    guard let player = self?.playerLayer.player, player.currentItem === item, player.rate == 0,
                          player.status == .readyToPlay, item.status == .readyToPlay
                    else { return }
                    player.preroll(atRate: 1)
                }
            }
        } else {
            NSLog("Viewer: a swapped-in item never drew; showing the player as it is")
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
