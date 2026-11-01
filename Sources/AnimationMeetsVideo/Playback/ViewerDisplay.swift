import AppKit
import AVFoundation
import CoreVideo
import QuartzCore

/// The viewer's one painter: the picture on screen, playing or paused, as a
/// pixel buffer shown by every layer attached (the editor's viewer, the
/// synced external display). Nothing else draws the picture, so nothing
/// can show through or be handed over to: a picture stays until a newer
/// one replaces it, and a new item, an emptied timeline or a slow frame
/// never shows black in between.
///
/// Its pictures come from the player's current item, through the
/// `AVPlayerItemVideoOutput` each item is given (`PlaybackModel.prepare`),
/// pulled each screen refresh while playing and whenever the output has a
/// new frame while paused; and from frames drawn again with new values
/// (`FrameRedrawer`), which `PlaybackModel` shows itself. Both are the
/// compositor's frames in its own format and tagging, so one replacing the
/// other changes nothing on screen but what was edited.
@MainActor
final class ViewerDisplay {
    /// The picture on screen, kept until a newer one replaces it.
    private(set) var buffer: CVPixelBuffer?
    /// Whether the player is playing: frames are then pulled for the time
    /// each refresh shows, and the display link runs throughout.
    var isPlaying = false {
        didSet { if isPlaying { wake() } }
    }
    /// Takes each frame the current item's output hands over, with its item
    /// time; without one the frame is shown as it is.
    var onOutputFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let layers = NSHashTable<CALayer>.weakObjects()
    private weak var linkHost: NSView?
    private var link: CADisplayLink?
    private var timer: Timer?
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private lazy var proxy = Proxy(display: self)
    /// The display link runs until then while paused, then waits for the
    /// output to say it has something (`outputMediaDataWillChange`).
    private var awakeUntil: CFTimeInterval = 0
    private var waiters: [UUID: (item: ObjectIdentifier, continuation: CheckedContinuation<Bool, Never>)] = [:]
    /// When the link or timer last stepped, and an output last handed over
    /// a frame, for the log when a swapped-in item doesn't draw.
    private var lastStep: CFTimeInterval?
    private var lastFrame: CFTimeInterval?

    /// Shows its pictures in `layer`, with `host`'s screen setting the pace
    /// of the display link.
    func attach(_ layer: CALayer, host: NSView) {
        layers.add(layer)
        setContents(of: layer, fade: false)
        if linkHost == nil || linkHost?.window == nil {
            linkHost = host
            rebuildLink()
        }
    }

    func detach(_ layer: CALayer, host: NSView) {
        layers.remove(layer)
        if linkHost === host {
            linkHost = nil
            rebuildLink()
        }
    }

    /// Puts `buffer` on screen, faded in over the last picture with `fade`
    /// (the first frame of a new item while playing).
    func show(_ buffer: CVPixelBuffer, fade: Bool = false) {
        self.buffer = buffer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers.allObjects { setContents(of: layer, fade: fade) }
        CATransaction.commit()
    }

    /// Follows `item`'s video output, which `PlaybackModel.prepare` gave it.
    /// The last picture stays until the output has a frame.
    func follow(_ item: AVPlayerItem?) {
        guard item !== self.item || output == nil && item != nil else { return }
        output?.setDelegate(nil, queue: nil)
        self.item = item
        output = item?.outputs.lazy.compactMap { $0 as? AVPlayerItemVideoOutput }.first
        output?.setDelegate(proxy, queue: .main)
        wake()
    }

    /// Looks for new frames for a while: after a seek, a new item or a
    /// changed composition, whose frame the output gets in a moment.
    func wake(for seconds: CFTimeInterval = 1) {
        awakeUntil = max(awakeUntil, CACurrentMediaTime() + seconds)
        if let link { link.isPaused = false } else if timer == nil { rebuildLink() }
    }

    /// Waits until `item`'s output hands over a frame, or `timeout` passes:
    /// true if it did. A swap waits on this before it counts as done, and
    /// until then the last picture stays.
    func firstFrame(of item: AVPlayerItem, within timeout: Duration) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = (ObjectIdentifier(item), continuation)
            wake(for: timeout.seconds)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolve(id, false)
            }
        }
    }

    private func resolve(_ id: UUID, _ shown: Bool) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: shown)
    }

    private func setContents(of layer: CALayer, fade: Bool) {
        if fade {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.08
            layer.add(transition, forKey: "swap")
        }
        layer.contents = buffer.map { CVPixelBufferGetIOSurface($0).map { $0.takeUnretainedValue() as Any } ?? $0 }
    }

    private func rebuildLink() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        if let linkHost {
            let link = linkHost.displayLink(target: proxy, selector: #selector(Proxy.step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else if isPlaying || !waiters.isEmpty || CACurrentMediaTime() < awakeUntil {
            // Nothing on screen to pace it, as in a window being closed:
            // frames are still looked for, for a swap waiting on one.
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step(targetTime: nil) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// What the display is doing about `item`: whether it follows that
    /// item's output, and whether its link is stepping and frames coming.
    /// A swap that never drew logs this.
    func diagnostics(for item: AVPlayerItem) -> String {
        let now = CACurrentMediaTime()
        func ago(_ time: CFTimeInterval?) -> String {
            time.map { String(format: "%.2f s ago", now - $0) } ?? "never"
        }
        let pacing = if let link {
            "link \(link.isPaused ? "paused" : "running")"
        } else if timer != nil {
            "timer"
        } else {
            "no link"
        }
        let host: String = if let window = linkHost?.window {
            "host window \(window.isVisible ? "visible" : "hidden"), \(window.occlusionState.contains(.visible) ? "unoccluded" : "occluded")"
        } else {
            linkHost == nil ? "no host" : "host off-window"
        }
        let followed = self.item === item
            ? "follows it, output \(output != nil)"
            : "follows \(self.item == nil ? "nothing" : "another item")"
        return [
            "display \(followed)", pacing, host,
            "waiters \(waiters.count), last step \(ago(lastStep)), last frame \(ago(lastFrame))",
        ].joined(separator: ", ")
    }

    fileprivate func step(targetTime: CFTimeInterval?) {
        let now = CACurrentMediaTime()
        lastStep = now
        if let item, let output {
            let time = isPlaying ? output.itemTime(forHostTime: targetTime ?? now) : item.currentTime()
            if time.isNumeric, output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                awakeUntil = max(awakeUntil, now + 0.5)
                lastFrame = now
                let id = ObjectIdentifier(item)
                for (key, waiter) in waiters where waiter.item == id { resolve(key, true) }
                if let onOutputFrame { onOutputFrame(buffer, time) } else { show(buffer) }
            }
        }
        guard !isPlaying, waiters.isEmpty, now > awakeUntil else { return }
        // Quiet: the link stops until the output has something.
        link?.isPaused = true
        timer?.invalidate()
        timer = nil
        output?.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.05)
    }

    /// The display link's and the output's Objective-C target.
    @MainActor
    private final class Proxy: NSObject, AVPlayerItemOutputPullDelegate {
        weak var display: ViewerDisplay?

        init(display: ViewerDisplay) {
            self.display = display
        }

        @objc func step(_ link: CADisplayLink) {
            display?.step(targetTime: link.targetTimestamp)
        }

        nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
            MainActor.assumeIsolated { display?.wake() }
        }
    }
}

private extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
