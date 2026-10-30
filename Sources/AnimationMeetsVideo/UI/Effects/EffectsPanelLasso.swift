import SwiftUI

/// A lasso dragged across the effects panel's lanes, in window coordinates.
struct KeyframeLasso: Equatable {
    var start: CGPoint
    var current: CGPoint
    /// Keyframes picked when it began, kept with Shift or Command.
    var kept: Set<LaneKeyframePicks.Key>
    /// Whether it began with Shift or Command, so a click doesn't let go.
    var adds: Bool

    var rect: CGRect {
        CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    /// Less than a few points of travel is a click.
    var isClick: Bool { rect.width < 4 && rect.height < 4 }
}

// Picking keyframes in the lanes with a lasso: a press in the lanes that
// isn't on a keyframe begins one, and a click there lets go of what is
// picked (see docs/effects.md, "Keyframes in the panel").
extension EffectsPanel {
    /// Where the lanes are across the stack, in window coordinates.
    private var lanesColumn: ClosedRange<CGFloat> {
        let start = stackFrame.minX + lanes.labelWidth + EffectsPanelMetrics.laneInset
        return start...max(start, stackFrame.maxX - EffectsPanelMetrics.laneInset)
    }

    var keyframeLassoMonitor: LassoMonitor {
        let picks = state.keyframes
        return LassoMonitor(
            onDown: { point, flags in
                guard stackFrame.contains(point), lanesColumn.contains(point.x), !picks.isNearKeyframe(point) else { return false }
                let adds = SelectClick.lassoAdds(flags)
                keyframeLasso = KeyframeLasso(start: point, current: point, kept: adds ? picks.picked.items : [], adds: adds)
                return true
            },
            onDrag: { point in
                guard var lasso = keyframeLasso else { return }
                lasso.current = point
                keyframeLasso = lasso
                if !lasso.isClick { picks.lasso(lasso.rect, keeping: lasso.kept) }
            },
            onUp: { _ in
                guard let lasso = keyframeLasso else { return }
                keyframeLasso = nil
                if lasso.isClick, !lasso.adds { picks.clear() }
            }
        )
    }

    /// What the lasso is drawn as, over the lanes.
    var keyframeLassoOverlay: some View {
        GeometryReader { proxy in
            if let lasso = keyframeLasso, !lasso.isClick {
                let origin = proxy.frame(in: .global).origin
                let rect = lasso.rect
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Design.accent.opacity(0.12))
                    .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Design.accent.opacity(0.9), lineWidth: 1) }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX - origin.x, y: rect.minY - origin.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
