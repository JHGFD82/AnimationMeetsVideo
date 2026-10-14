import AppKit
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

    func makeNSView(context: Context) -> RailView {
        RailView()
    }

    func updateNSView(_ view: RailView, context: Context) {
        view.apply(
            playheadX: isPlayheadVisible ? playheadX : nil,
            snapX: snapX,
            height: height,
            headTop: headTop
        )
    }

    final class RailView: NSView {
        private let playheadLine = CALayer()
        private let playheadHead = CAShapeLayer()
        private let snapLine = CALayer()
        private var hasSnap = false
        private var headSize = CGSize.zero

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
            playheadLine.isHidden = true

            playheadHead.fillColor = NSColor(Design.playhead).cgColor
            playheadHead.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
            playheadHead.lineWidth = 0.5
            playheadHead.shadowColor = NSColor.black.cgColor
            playheadHead.shadowOpacity = 0.45
            playheadHead.shadowRadius = 2
            playheadHead.shadowOffset = CGSize(width: 0, height: 1)
            playheadHead.isHidden = true

            snapLine.backgroundColor = NSColor(Design.snap).cgColor
            snapLine.isHidden = true

            layer?.addSublayer(snapLine)
            layer?.addSublayer(playheadLine)
            layer?.addSublayer(playheadHead)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Top-left origin, so x and y match the SwiftUI layout around it.
        override var isFlipped: Bool { true }

        /// The rail is a readout, never a target: scrubbing and clip
        /// gestures belong to the views underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply(playheadX: CGFloat?, snapX: CGFloat?, height: CGFloat, headTop: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            if let playheadX {
                let x = (playheadX - 0.75).rounded() + 0.25
                playheadLine.frame = CGRect(x: x, y: 0, width: 1.5, height: height)
                playheadLine.isHidden = false
                let size = CGSize(width: Self.headWidth, height: Self.headHeight)
                if headSize != size {
                    headSize = size
                    playheadHead.path = Self.headPath(size: size)
                }
                playheadHead.frame = CGRect(
                    x: playheadX - Self.headWidth / 2,
                    y: headTop,
                    width: Self.headWidth,
                    height: Self.headHeight
                )
                playheadHead.isHidden = false
            } else {
                playheadLine.isHidden = true
                playheadHead.isHidden = true
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
