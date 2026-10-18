import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// The playhead and the snap indicator, drawn as Core Animation layers over
/// the track area.
///
/// These two move more than anything else in the editor — the playhead on
/// every playback tick and every pixel of a scrub, the snap line on every
/// frame of a drag. As SwiftUI `Shape`s they were re-built and re-rasterized
/// each time, inside the timeline's own view tree. Here they are three
/// `CALayer`s whose positions are written directly with implicit animation
/// turned off, so a move is a compositor transaction and nothing is
/// redrawn.
///
/// The snap line also does something a static indicator can't: it arrives
/// with a brief collapse onto the target. Snapping is invisible by nature —
/// the edge simply ends up somewhere you didn't drag it — and that flash is
/// what tells you it caught rather than that you missed.
///
/// Given `following`, the playhead runs on the player's own clock instead:
/// it sits in an `AVSynchronizedLayer` bound to the player's item, with one
/// linear animation across the whole timeline, so Core Animation moves it
/// on every display frame — in step with play, pause, rate changes and
/// seeks — and nothing on the main thread runs while it plays. Only a
/// change of zoom, scroll or item replaces the animation.
struct PlayheadRail: NSViewRepresentable {
    /// Where the playhead is, in the track area's visible coordinates.
    let playheadX: CGFloat
    /// False when the playhead is scrolled out of view.
    let isPlayheadVisible: Bool
    /// Where a drag in progress snapped, if it did.
    let snapX: CGFloat?
    /// How far down the rail runs: the ruler plus the visible layers.
    let height: CGFloat
    /// Where the top of the grabbable head sits, measured from the top of
    /// the rail — the ruler's own top, so the head reads as part of it.
    var headTop: CGFloat = 0
    /// While set, the playhead follows the player rather than `playheadX`.
    var following: Following?

    /// How player time maps onto the rail, for a playhead that follows the
    /// player on its own.
    struct Following {
        let player: AVPlayer
        /// Points per second of player time.
        let pixelsPerSecond: CGFloat
        /// Where time zero is drawn, in the rail's coordinates.
        let originX: CGFloat
        /// How many seconds the animation spans: at least the item's length.
        let seconds: Double
        /// Called with the player's time when the playhead leaves the rail's
        /// width (or is already outside it when following starts), so the
        /// view can page after it. Nil not to follow.
        var onLeaveView: ((CMTime) -> Void)?

        /// What the animation depends on; a change means a new animation.
        fileprivate var mapping: [Double] { [Double(pixelsPerSecond), Double(originX), seconds] }
    }

    func makeNSView(context: Context) -> RailView {
        RailView()
    }

    func updateNSView(_ view: RailView, context: Context) {
        view.apply(
            playheadX: isPlayheadVisible ? playheadX : nil,
            snapX: snapX,
            height: height,
            headTop: headTop,
            following: following
        )
    }

    final class RailView: NSView {
        /// Holds the playhead; bound to the player's item while following.
        private let synchronized = AVSynchronizedLayer()
        /// The line and the head together, positioned at the playhead's x.
        private let playhead = CALayer()
        private let playheadLine = CALayer()
        private let playheadHead = CAShapeLayer()
        private let snapLine = CALayer()
        private var hasSnap = false
        private var headSize = CGSize.zero

        private var following: Following?
        /// The player, item and mapping the running animation was made for.
        private var boundPlayer: AVPlayer?
        private var boundItem: AVPlayerItem?
        private var boundMapping: [Double] = []
        private var boundWidth: CGFloat = 0
        private var itemObservation: NSKeyValueObservation?
        private var boundaryObserver: Any?
        private var jumpObserver: NSObjectProtocol?

        /// The grabbable tab at the top of the playhead.
        static let headWidth: CGFloat = 13
        static let headHeight: CGFloat = 14

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true

            playheadLine.backgroundColor = NSColor(Design.playhead).cgColor
            // A dark edge under the line keeps it readable where it crosses
            // a pale clip or the lit top of a bevel.
            playheadLine.shadowColor = NSColor.black.cgColor
            playheadLine.shadowOpacity = 0.55
            playheadLine.shadowRadius = 1.5
            playheadLine.shadowOffset = .zero

            playheadHead.fillColor = NSColor(Design.playhead).cgColor
            playheadHead.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
            playheadHead.lineWidth = 0.5
            playheadHead.shadowColor = NSColor.black.cgColor
            playheadHead.shadowOpacity = 0.45
            playheadHead.shadowRadius = 2
            playheadHead.shadowOffset = CGSize(width: 0, height: 1)

            // Zero-sized at the playhead's x, so moving it is one value and
            // the animation can drive exactly that.
            playhead.anchorPoint = .zero
            playhead.bounds = .zero
            playhead.isHidden = true
            playhead.addSublayer(playheadLine)
            playhead.addSublayer(playheadHead)
            synchronized.addSublayer(playhead)

            snapLine.backgroundColor = NSColor(Design.snap).cgColor
            snapLine.isHidden = true

            layer?.addSublayer(snapLine)
            layer?.addSublayer(synchronized)
        }

        isolated deinit {
            unbind()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Top-left origin, so x and y match the SwiftUI layout around it.
        override var isFlipped: Bool { true }

        /// The rail is a readout, never a target: scrubbing and clip
        /// gestures belong to the views underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            synchronized.frame = bounds
            CATransaction.commit()
            if following != nil, bounds.width != boundWidth { refollow() }
        }

        func apply(playheadX: CGFloat?, snapX: CGFloat?, height: CGFloat, headTop: CGFloat, following: Following?) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            synchronized.frame = bounds
            playheadLine.frame = CGRect(x: -0.75, y: 0, width: 1.5, height: height)
            let size = CGSize(width: Self.headWidth, height: Self.headHeight)
            if headSize != size {
                headSize = size
                playheadHead.path = Self.headPath(size: size)
            }
            playheadHead.frame = CGRect(x: -Self.headWidth / 2, y: headTop, width: Self.headWidth, height: Self.headHeight)

            self.following = following
            if let following {
                // Outside the rail it is clipped, not hidden: the animation
                // carries it back in on its own.
                playhead.isHidden = false
                if following.player !== boundPlayer || following.player.currentItem !== boundItem
                    || following.mapping != boundMapping || bounds.width != boundWidth {
                    refollow()
                }
            } else {
                unbind()
                if let playheadX {
                    playhead.position = CGPoint(x: (playheadX - 0.75).rounded() + 1, y: 0)
                    playhead.isHidden = false
                } else {
                    playhead.isHidden = true
                }
            }

            if let snapX {
                snapLine.frame = CGRect(x: (snapX - 0.75).rounded() + 0.25, y: 0, width: 1.5, height: height)
                snapLine.isHidden = false
                if !hasSnap {
                    hasSnap = true
                    if !Design.Motion.isReduced { collapseOntoTarget() }
                }
            } else {
                snapLine.isHidden = true
                hasSnap = false
            }

            CATransaction.commit()
        }

        // MARK: Following the player

        /// Binds to the player's current item and lays one animation across
        /// the timeline. Called when following starts and whenever what it
        /// depends on changes.
        private func refollow() {
            guard let following else { return }
            let player = following.player
            if player !== boundPlayer {
                unbind()
                boundPlayer = player
                // A new item while playing gets a new binding.
                itemObservation = player.observe(\.currentItem) { [weak self] _, _ in
                    Task { @MainActor in self?.refollow() }
                }
            }
            let item = player.currentItem
            if item !== boundItem {
                if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
                jumpObserver = nil
                boundItem = item
                synchronized.playerItem = item
                // A seek can land the playhead anywhere, past the boundary
                // below or before the view.
                if let item {
                    jumpObserver = NotificationCenter.default.addObserver(
                        forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.checkInView() }
                    }
                }
            }
            boundMapping = following.mapping
            boundWidth = bounds.width

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let span = max(following.seconds, 1)
            let run = CABasicAnimation(keyPath: "position.x")
            run.fromValue = following.originX
            run.toValue = following.originX + following.pixelsPerSecond * CGFloat(span)
            // Zero would mean "now"; this means time zero of the item.
            run.beginTime = AVCoreAnimationBeginTimeAtZero
            run.duration = span
            run.timingFunction = CAMediaTimingFunction(name: .linear)
            run.fillMode = .both
            run.isRemovedOnCompletion = false
            playhead.add(run, forKey: "follow")
            CATransaction.commit()

            watchRightEdge()
            checkInView()
        }

        /// Asks the player to say when the playhead reaches the right edge,
        /// which is where it leaves the view while playing forward.
        private func watchRightEdge() {
            guard let player = boundPlayer else { return }
            if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
            boundaryObserver = nil
            guard let following, following.onLeaveView != nil, following.pixelsPerSecond > 0 else { return }
            let edge = Double((bounds.width - following.originX) / following.pixelsPerSecond)
            guard edge > player.currentTime().seconds else { return }
            let time = CMTime(seconds: edge, preferredTimescale: 600)
            boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.leftView() }
            }
        }

        /// Pages after the playhead if it is outside the view now.
        private func checkInView() {
            guard let following, following.onLeaveView != nil, let player = boundPlayer else { return }
            let x = following.originX + following.pixelsPerSecond * CGFloat(player.currentTime().seconds)
            if x < 0 || x > bounds.width { leftView() }
        }

        private func leftView() {
            guard let following, let player = boundPlayer else { return }
            following.onLeaveView?(player.currentTime())
        }

        private func unbind() {
            guard boundPlayer != nil else { return }
            if let boundaryObserver { boundPlayer?.removeTimeObserver(boundaryObserver) }
            if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
            boundaryObserver = nil
            jumpObserver = nil
            itemObservation = nil
            boundPlayer = nil
            boundItem = nil
            boundMapping = []
            playhead.removeAnimation(forKey: "follow")
            synchronized.playerItem = nil
        }

        /// The snap line's arrival: a wide, bright flash that narrows onto
        /// the edge it caught.
        private func collapseOntoTarget() {
            let widen = CABasicAnimation(keyPath: "transform.scale.x")
            widen.fromValue = 5
            widen.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.3
            fade.toValue = 1

            let group = CAAnimationGroup()
            group.animations = [widen, fade]
            group.duration = 0.16
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            snapLine.add(group, forKey: "caught")
        }

        /// A downward-pointing tab: square shoulders over a point that sits
        /// exactly on the frame the playhead is parked at.
        private static func headPath(size: CGSize) -> CGPath {
            let path = CGMutablePath()
            let shoulder = size.height * 0.55
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: shoulder))
            path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: shoulder))
            path.closeSubpath()
            return path
        }
    }
}
