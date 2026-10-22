import AppKit
import QuartzCore
import SwiftUI

/// How the editor moves.
///
/// Motion here has two jobs: to confirm that something you did took effect,
/// and to keep what you move, or what moves because you did, travelling
/// instead of jumping. A clip stays under the pointer and glides into place
/// when put down; the clips around it slide aside rather than snapping; a
/// lasso fades when let go. Nothing animates on its own and nothing moves
/// that you didn't cause. The other places it earns its keep are state
/// changes you can't otherwise see land (an edit committed, an edge caught
/// a snap) and panels changing size, where an instant jump reads as a
/// glitch.
///
/// Per-frame work — the playhead, the snap line — is driven through Core
/// Animation rather than SwiftUI state, so dragging and playback don't
/// re-evaluate the timeline's view tree sixty times a second. See
/// `PlayheadRail`.
extension Design {
    enum Motion {
        /// Panels opening, rows expanding: quick, barely overshooting.
        static let panel = Animation.spring(response: 0.28, dampingFraction: 0.86)
        /// Selection and focus: fast enough to feel like a click response.
        static let select = Animation.spring(response: 0.18, dampingFraction: 0.9)
        /// Value changes that should read as continuous, not stepped.
        static let value = Animation.easeOut(duration: 0.12)
        /// Something put down, or moved by an edit, going to its place: a
        /// clip dropped, clips making room, a landing mark following the
        /// pointer. Slower than `panel`, and settling without bounce, so
        /// it reads as travelling there, not as jumping.
        static let glide = Animation.spring(response: 0.34, dampingFraction: 0.92)
        /// Something the person pulled that can't go there, going back to
        /// where it was with a small bounce, so the refusal reads as one.
        static let springBack = Animation.spring(response: 0.3, dampingFraction: 0.45)
        /// A selection rectangle or other mark that has done its job.
        static let fade = Animation.easeOut(duration: 0.22)

        /// How long a confirmation flash lasts, in seconds.
        static let flashDuration: Double = 0.4

        /// Whether the person has asked the system for less movement.
        /// Checked at use, not cached: it can change while the app runs.
        @MainActor
        static var isReduced: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        /// An animation, or none when motion is reduced. Reduced motion
        /// still gets the state change — just instantly.
        @MainActor
        static func respecting(_ animation: Animation) -> Animation? {
            isReduced ? nil : animation
        }
    }
}

extension View {
    /// Animates a change the way the editor animates it, unless the person
    /// has asked for reduced motion.
    @MainActor
    func editorAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.animation(Design.Motion.respecting(animation), value: value)
    }
}

// MARK: - Confirmation flash

/// A rim light that runs once, over a shape, whenever `token` changes.
///
/// Edits in the timeline travel up to the project and back down before the
/// view sees them, so there is a moment where you have let go and nothing
/// has visibly happened. This is the acknowledgement: the clip's edge
/// catches the light for a third of a second as the edit lands. It is a
/// `CALayer` rather than SwiftUI state so it can run during a drag without
/// invalidating the row it sits in.
struct ConfirmFlash: NSViewRepresentable {
    /// Changes to run a flash. Equal values do nothing, so passing a
    /// counter of committed edits is enough.
    let token: Int
    var color: Color = Design.accent
    var cornerRadius: CGFloat = Design.Radius.chip
    var lineWidth: CGFloat = 1.5

    func makeNSView(context: Context) -> FlashView {
        let view = FlashView()
        view.lastToken = token
        return view
    }

    func updateNSView(_ view: FlashView, context: Context) {
        view.configure(color: NSColor(color), cornerRadius: cornerRadius, lineWidth: lineWidth)
        guard view.lastToken != token else { return }
        view.lastToken = token
        guard !Design.Motion.isReduced else { return }
        view.flash(duration: Design.Motion.flashDuration)
    }

    final class FlashView: NSView {
        var lastToken = 0
        private var rimColor: NSColor = .white

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.borderWidth = 0
            layer?.masksToBounds = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Purely decorative: clicks must reach the clip underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(color: NSColor, cornerRadius: CGFloat, lineWidth: CGFloat) {
            rimColor = color
            layer?.cornerRadius = cornerRadius
            layer?.borderWidth = lineWidth
            // Invisible until a flash runs.
            layer?.borderColor = color.withAlphaComponent(0).cgColor
        }

        func flash(duration: Double) {
            guard let layer else { return }
            let rim = CABasicAnimation(keyPath: "borderColor")
            rim.fromValue = rimColor.withAlphaComponent(0.95).cgColor
            rim.toValue = rimColor.withAlphaComponent(0).cgColor
            rim.duration = duration
            rim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(rim, forKey: "confirm")
        }
    }
}

extension View {
    /// Flashes a rim over this view when `token` changes. See `ConfirmFlash`.
    func confirmFlash(
        token: Int,
        color: Color = Design.accent,
        cornerRadius: CGFloat = Design.Radius.chip
    ) -> some View {
        overlay {
            ConfirmFlash(token: token, color: color, cornerRadius: cornerRadius)
                .allowsHitTesting(false)
        }
    }
}
