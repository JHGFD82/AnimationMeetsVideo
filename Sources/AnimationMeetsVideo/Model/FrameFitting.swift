import CoreGraphics

extension CGAffineTransform {
    /// Scales `source` to fit inside `target`, keeping its shape, and
    /// centers it: how a clip's picture is placed in the frame before its
    /// stack. The identity when either size is empty.
    static func fitting(_ source: CGSize, into target: CGSize) -> CGAffineTransform {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .identity }
        let scale = min(target.width / source.width, target.height / source.height)
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
            translationX: (target.width - source.width * scale) / 2,
            y: (target.height - source.height * scale) / 2
        ))
    }
}
