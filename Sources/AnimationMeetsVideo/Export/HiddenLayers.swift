import CoreGraphics
import CoreMedia
import Foundation

// Leaving out of a stretch the layers a picture above hides completely, so
// two opaque pictures stacked full frame play from the top one's file
// instead of being rendered (see docs/rendering.md, "Render cache").
extension DrawClip {
    /// Whether it hides everything under it throughout `range`, in a
    /// timeline whose frame is `frameSize`: footage that can't be
    /// transparent, drawn the same way all along with nothing done to it,
    /// filling the frame without being enlarged. An enlarged picture's
    /// outermost pixels are mixed with the transparency past its edge, so
    /// what is under it shows faintly there.
    func hidesEverythingUnder(in frameSize: CGSize, over range: CMTimeRange, frame: CMTime) -> Bool {
        guard case .media(let media) = content, media.still == nil, let size = media.opaqueSize,
              media.nextFrame == nil, media.echoes.isEmpty, media.trails.isEmpty,
              stack.shutter.motionBlur == nil, stack.isNoOp(over: range, frame: frame),
              stack.resolve(atRoot: range.start).transition == nil, stack.transitionFrame(atRoot: range.start) == nil
        else { return false }
        let base = media.base
        let upright = abs(base.b) < 1e-9 && abs(base.c) < 1e-9
        let turned = abs(base.a) < 1e-9 && abs(base.d) < 1e-9
        guard upright || turned else { return false }
        let tolerance = 1e-6
        // Output pixels per stored pixel along each axis of the frame.
        let scales = upright ? (abs(base.a), abs(base.d)) : (abs(base.c), abs(base.b))
        guard scales.0 <= 1 + tolerance, scales.1 <= 1 + tolerance else { return false }
        let covered = CGRect(origin: .zero, size: size).applying(base).insetBy(dx: -tolerance, dy: -tolerance)
        return covered.contains(CGRect(origin: .zero, size: frameSize))
    }
}

extension Array where Element == DrawClip {
    /// The clips, top first, down to the first that hides everything under
    /// it; the rest aren't seen. Only this timeline's own clips are looked
    /// at, not those inside nested timelines or reached by adjustments.
    func withoutHidden(in frameSize: CGSize, over range: CMTimeRange, frame: CMTime) -> [DrawClip] {
        guard let index = firstIndex(where: { $0.hidesEverythingUnder(in: frameSize, over: range, frame: frame) }) else { return self }
        return Array(self[...index])
    }
}
