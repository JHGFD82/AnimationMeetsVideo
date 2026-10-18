import CoreGraphics
import CoreMedia
import Foundation

// Leaving out of a stretch the layers pictures above hide completely, so
// two opaque pictures stacked in the same place play from the top one's
// file instead of being rendered (see docs/rendering.md, "Render cache").
extension DrawClip {
    /// The pixels of a timeline whose frame is `frameSize` that it covers
    /// solidly throughout `range`: footage that can't be transparent, drawn
    /// the same way all along with nothing done to it and not enlarged,
    /// less the pixels its edges only partly cover. An enlarged picture's
    /// outermost pixels are mixed with the transparency past its edge, so
    /// it covers nothing for certain. Nil when it may cover nothing.
    func solidRect(in frameSize: CGSize, over range: CMTimeRange, frame: CMTime) -> CGRect? {
        guard case .media(let media) = content, media.still == nil, let size = media.opaqueSize,
              drawnPlainly(over: range, frame: frame)
        else { return nil }
        let base = media.base
        let upright = abs(base.b) < 1e-9 && abs(base.c) < 1e-9
        let turned = abs(base.a) < 1e-9 && abs(base.d) < 1e-9
        guard upright || turned else { return nil }
        let tolerance = 1e-6
        // Output pixels per stored pixel along each axis of the frame.
        let scales = upright ? (abs(base.a), abs(base.d)) : (abs(base.c), abs(base.b))
        guard scales.0 <= 1 + tolerance, scales.1 <= 1 + tolerance else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(base).intersection(CGRect(origin: .zero, size: frameSize))
        let minX = (rect.minX - tolerance).rounded(.up), minY = (rect.minY - tolerance).rounded(.up)
        let maxX = (rect.maxX + tolerance).rounded(.down), maxY = (rect.maxY + tolerance).rounded(.down)
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The pixels of the frame it may draw on throughout `range`, edges
    /// included. Nil when that isn't known, such as when its stack moves
    /// it or works on its pixels.
    func drawnRect(in frameSize: CGSize, over range: CMTimeRange, frame: CMTime) -> CGRect? {
        guard case .media(let media) = content, let size = media.opaqueSize ?? media.still?.size,
              drawnPlainly(over: range, frame: frame)
        else { return nil }
        return CGRect(origin: .zero, size: size).applying(media.base)
            .intersection(CGRect(origin: .zero, size: frameSize)).integral
    }

    /// Whether its picture is drawn once, as it is, in the same place
    /// throughout `range`.
    private func drawnPlainly(over range: CMTimeRange, frame: CMTime) -> Bool {
        guard case .media(let media) = content else { return false }
        return media.nextFrame == nil && media.echoes.isEmpty && media.trails.isEmpty
            && stack.shutter.motionBlur == nil && stack.isNoOp(over: range, frame: frame)
            && stack.resolve(atRoot: range.start).transition == nil && stack.transitionFrame(atRoot: range.start) == nil
    }
}

extension Array where Element == DrawClip {
    /// The clips, top first, without those that draw only where a picture
    /// above them covers solidly, or only off the frame. Only this
    /// timeline's own clips are looked at, not those inside nested
    /// timelines or reached by adjustments.
    func withoutHidden(in frameSize: CGSize, over range: CMTimeRange, frame: CMTime) -> [DrawClip] {
        var covers: [CGRect] = []
        var kept: [DrawClip] = []
        for clip in self {
            if let drawn = clip.drawnRect(in: frameSize, over: range, frame: frame),
               drawn.isEmpty || covers.contains(where: { $0.contains(drawn) }) {
                continue
            }
            kept.append(clip)
            if let solid = clip.solidRect(in: frameSize, over: range, frame: frame) {
                covers.append(solid)
            }
        }
        return kept
    }
}
