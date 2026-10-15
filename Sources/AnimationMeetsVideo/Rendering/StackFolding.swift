import CoreGraphics
import CoreMedia
import Foundation

/// Where a clip's picture is and how opaque, after the Position, Scale,
/// Rotation and Opacity steps of its stack.
struct FoldedPlacement: Equatable {
    /// Maps the fitted picture to where it is drawn, in the frame's
    /// coordinates (pixels, origin top left, y down).
    var matrix = CGAffineTransform.identity
    var opacity = 1.0
    /// Where the anchor point is in the frame.
    var anchor: CGPoint

    /// Applies one Transform control. Steps work on the picture as it is on
    /// screen: Position moves along the screen's axes, and Scale and
    /// Rotation turn about the anchor, wherever it is.
    mutating func apply(_ control: EffectControl, movesAnchor: Bool, at time: CMTime) {
        guard control.enabled, !control.isNoOp else { return }
        let values = control.values(at: time)
        switch control.kind {
        case .position:
            guard values.count == 2 else { return }
            matrix = matrix.concatenating(CGAffineTransform(translationX: values[0], y: values[1]))
            if movesAnchor { anchor = CGPoint(x: anchor.x + values[0], y: anchor.y + values[1]) }
        case .scale:
            guard values.count == 2 else { return }
            matrix = aboutAnchor(CGAffineTransform(scaleX: values[0] / 100, y: values[1] / 100))
        case .rotation:
            guard let degrees = values.first else { return }
            matrix = aboutAnchor(CGAffineTransform(rotationAngle: degrees * .pi / 180))
        case .opacity:
            guard let percent = values.first else { return }
            opacity *= min(max(percent / 100, 0), 1)
        case .mode, .amount:
            break
        }
    }

    /// `matrix` followed by `change`, applied about the anchor.
    private func aboutAnchor(_ change: CGAffineTransform) -> CGAffineTransform {
        matrix
            .concatenating(CGAffineTransform(translationX: -anchor.x, y: -anchor.y))
            .concatenating(change)
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
    }
}

enum StackFolding {
    /// The placement the stack gives the fitted picture at source time
    /// `time`. `center` is the center of the picture, where the anchor
    /// point's offset is measured from. Only Transform effects move the
    /// picture; the rest are the pixel steps drawn by the compositor.
    static func fold(effects: [Effect], anchorPoint: AnimatedValue<Vector2>, at time: CMTime, center: CGPoint) -> FoldedPlacement {
        let offset = anchorPoint.value(at: time)
        var placement = FoldedPlacement(anchor: CGPoint(x: center.x + offset.x, y: center.y + offset.y))
        for effect in effects where effect.enabled && effect.kind == .transform {
            for control in effect.controls {
                placement.apply(control, movesAnchor: effect.movesAnchor, at: time)
            }
        }
        return placement
    }
}
