import CoreImage
import Foundation

/// Draws the transitions that need both whole pictures, the one before and
/// the one after (`TransitionKind.drawsTwoPictures`), for
/// `LayeredCompositor`.
///
/// Both pictures fill the output, in its coordinates: Core Image's, from
/// the bottom left. Settings measured in the timeline's frame (a center,
/// a direction) are turned over to match. Like the compositor, it works on
/// the frames' encoded values.
enum TransitionRenderer {
    static func draw(_ frame: TransitionFrame, from before: CIImage, to after: CIImage, in bounds: CGRect) -> CIImage {
        let a = before.cropped(to: bounds)
        let b = after.cropped(to: bounds)
        let p = min(max(frame.progress, 0), 1)
        let options = frame.options
        switch frame.kind {
        case .dipToColor:
            let color = CIImage(color: CIColor(red: options.color.red, green: options.color.green, blue: options.color.blue))
                .cropped(to: bounds)
            return p < 0.5 ? mix(a, color, p * 2) : mix(color, b, p * 2 - 1)
        case .additiveDissolve:
            // Each picture is at full strength through its half, so the
            // middle is both added together, as a film lab's.
            let out = min(1, 2 * (1 - p)), into = min(1, 2 * p)
            return add(scaled(opaque(a, in: bounds), red: out, green: out, blue: out),
                       scaled(opaque(b, in: bounds), red: into, green: into, blue: into))
        case .channelDissolve:
            // Red crosses first and blue last.
            let red = ramp(p, from: 0, to: 0.6), green = ramp(p, from: 0.2, to: 0.8), blue = ramp(p, from: 0.4, to: 1)
            return add(scaled(opaque(a, in: bounds), red: 1 - red, green: 1 - green, blue: 1 - blue),
                       scaled(opaque(b, in: bounds), red: red, green: green, blue: blue))
        case .blurDissolve:
            // Up to 6% of the width at full amount, at its most halfway.
            let radius = 0.06 * bounds.width * options.amount * sin(.pi * p)
            return mix(blurred(a, radius: radius, in: bounds), blurred(b, radius: radius, in: bounds), smoothstep(p))
        case .iris:
            return reveal(b, over: a, mask: TransitionMasks.iris(options.shape, center: point(options.center, in: bounds), progress: p, in: bounds))
        case .clockWipe:
            return reveal(b, over: a, mask: TransitionMasks.clock(center: point(options.center, in: bounds), progress: p, in: bounds))
        case .blinds:
            return reveal(b, over: a, mask: TransitionMasks.blinds(options.direction, count: options.count, progress: p, in: bounds))
        case .grid:
            return reveal(b, over: a, mask: TransitionMasks.grid(columns: options.count, order: options.order, progress: p, in: bounds))
        case .crossDissolve, .filmDissolve, .wipe, .slide, .zoom:
            // Drawn on the clip alone by the compositor; never asked for.
            return mix(a, b, p)
        }
    }

    // MARK: - Helpers

    /// `b` where `mask` is white, `a` where it is black.
    static func reveal(_ b: CIImage, over a: CIImage, mask: CIImage) -> CIImage {
        b.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: a,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// A point given as fractions of the frame from its top left, in the
    /// output's coordinates, which measure from the bottom left.
    static func point(_ fraction: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + fraction.x * bounds.width, y: bounds.minY + (1 - fraction.y) * bounds.height)
    }

    /// `a` blended toward `b` by `t`.
    static func mix(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
        if t <= 0 { return a }
        if t >= 1 { return b }
        return a.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: b,
            kCIInputTimeKey: t,
        ])
    }

    /// `image` over black, so it has no transparent parts for color math.
    static func opaque(_ image: CIImage, in bounds: CGRect) -> CIImage {
        image.composited(over: CIImage(color: .black).cropped(to: bounds))
    }

    /// An opaque image with its color channels scaled.
    static func scaled(_ image: CIImage, red: Double, green: Double, blue: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0),
        ])
    }

    /// Two opaque images added together.
    static func add(_ a: CIImage, _ b: CIImage) -> CIImage {
        b.applyingFilter("CILinearDodgeBlendMode", parameters: [kCIInputBackgroundImageKey: a])
    }

    /// `image` blurred by `radius`, its edges carried out so they don't
    /// darken.
    static func blurred(_ image: CIImage, radius: Double, in bounds: CGRect) -> CIImage {
        guard radius > 0.5 else { return image }
        return image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: bounds)
    }

    /// 0 up to `from`, 1 from `to`, a straight line between.
    static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        guard to > from else { return value >= to ? 1 : 0 }
        return min(max((value - from) / (to - from), 0), 1)
    }

    /// An S-shaped 0 to 1, flat at both ends.
    static func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
