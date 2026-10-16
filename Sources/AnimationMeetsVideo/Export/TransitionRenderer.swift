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
        case .matteWipe:
            // Brightest parts of the map first, as a film dissolve keys on
            // the picture itself. The ends are exact even where the map is
            // at full brightness.
            guard p > 0, p < 1 else { return p <= 0 ? a : b }
            let map = matteMap(options.matte, in: bounds)
            return reveal(b, over: a, mask: LayeredCompositor.revealMask(of: map, LumaReveal(progress: p, keysIncoming: true)))
        case .push:
            // Both move together, the next picture pushing the other off.
            let travel = offset(options.direction, in: bounds)
            let leaving = a.transformed(by: CGAffineTransform(translationX: travel.dx * p, y: travel.dy * p))
            let arriving = b.transformed(by: CGAffineTransform(translationX: travel.dx * (p - 1), y: travel.dy * (p - 1)))
            return arriving.composited(over: leaving).cropped(to: bounds)
        case .split:
            // The picture before opens in two halves, sideways for left or
            // right, up and down for up or down.
            var first = bounds, second = bounds
            let shift: CGVector
            if options.direction.isHorizontal {
                first.size.width = bounds.width / 2
                second = first.offsetBy(dx: bounds.width / 2, dy: 0)
                shift = CGVector(dx: bounds.width / 2 * p, dy: 0)
            } else {
                first.size.height = bounds.height / 2
                second = first.offsetBy(dx: 0, dy: bounds.height / 2)
                shift = CGVector(dx: 0, dy: bounds.height / 2 * p)
            }
            let lower = a.cropped(to: first).transformed(by: CGAffineTransform(translationX: -shift.dx, y: -shift.dy))
            let upper = a.cropped(to: second).transformed(by: CGAffineTransform(translationX: shift.dx, y: shift.dy))
            return upper.composited(over: lower).composited(over: b).cropped(to: bounds)
        case .crossZoom:
            // The picture before rushes toward the camera and the next one
            // settles out of the same rush, crossing in the middle.
            let center = point(options.center, in: bounds)
            let blur = options.amount * 0.08 * bounds.width * sin(.pi * p)
            let leaving = zoomBlurred(scaled(a, by: 1 + 3 * p * p, about: center), amount: blur, center: center, in: bounds)
            let arriving = zoomBlurred(scaled(b, by: 1 + 3 * (1 - p) * (1 - p), about: center), amount: blur, center: center, in: bounds)
            return mix(leaving, arriving, smoothstep(ramp(p, from: 0.35, to: 0.65)))
        case .flip:
            // A card turned half over about its middle: the picture before
            // on its front, the next one on its back.
            let sign = options.direction == .left || options.direction == .down ? -1.0 : 1.0
            let angle = sign * .pi * p
            let card = abs(angle) < .pi / 2
                ? turned(a, by: angle, horizontally: options.direction.isHorizontal, depth: 0, in: bounds)
                : turned(b, by: angle - sign * .pi, horizontally: options.direction.isHorizontal, depth: 0, in: bounds)
            return opaque(card, in: bounds)
        case .cube:
            // Two faces of a cube turning a quarter turn about its center,
            // half the frame's width (or height) behind the screen, so the
            // pictures travel in the direction set.
            let horizontal = options.direction.isHorizontal
            // Turning positively brings the next face in from the right,
            // or from the top.
            let sign = options.direction == .left || options.direction == .down ? 1.0 : -1.0
            let half = (horizontal ? bounds.width : bounds.height) / 2
            let angle = sign * .pi / 2 * p
            let leaving = turned(a, by: angle, horizontally: horizontal, depth: half, in: bounds)
            let arriving = turned(b, by: angle - sign * .pi / 2, horizontally: horizontal, depth: half, in: bounds)
            return opaque(leaving.composited(over: arriving), in: bounds)
        case .pageCurl:
            // The picture before peels away like a page, toward the
            // direction set.
            let angle: Double
            switch options.direction {
            case .left: angle = 0
            case .right: angle = .pi
            case .up: angle = .pi / 2
            case .down: angle = -.pi / 2
            }
            let shading = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.25)).cropped(to: bounds)
            return a.applyingFilter("CIPageCurlTransition", parameters: [
                kCIInputTargetImageKey: b,
                "inputBacksideImage": a,
                kCIInputShadingImageKey: shading,
                kCIInputExtentKey: CIVector(cgRect: bounds),
                kCIInputTimeKey: p,
                kCIInputAngleKey: angle,
                kCIInputRadiusKey: max(bounds.width, bounds.height) * 0.12,
            ]).cropped(to: bounds)
        case .pixelate:
            // Blocks grow to their largest halfway, where the pictures
            // change, then shrink away. Up to a tenth of the width at full
            // amount.
            let block = 1 + options.amount * 0.1 * bounds.width * (1 - abs(2 * p - 1))
            let picture = mix(a, b, smoothstep(ramp(p, from: 0.45, to: 0.55)))
            guard block >= 2 else { return picture }
            return picture.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: bounds.midX, y: bounds.midY),
                    kCIInputScaleKey: block,
                ])
                .cropped(to: bounds)
        case .ripple:
            if p <= 0 { return a }
            if p >= 1 { return b }
            let center = point(options.center, in: bounds)
            let shading = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.25)).cropped(to: bounds)
            return a.applyingFilter("CIRippleTransition", parameters: [
                kCIInputTargetImageKey: b,
                kCIInputShadingImageKey: shading,
                kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                kCIInputExtentKey: CIVector(cgRect: bounds),
                kCIInputTimeKey: p,
                kCIInputWidthKey: max(bounds.width, bounds.height) * 0.15,
                kCIInputScaleKey: options.amount * 0.1 * bounds.width,
            ]).cropped(to: bounds)
        case .glitch:
            return glitched(a, b, progress: p, amount: options.amount, in: bounds)
        case .morph:
            // Each picture is pulled part way along the motion between
            // them, the one before forward and the next one back, and they
            // dissolve. The amount scales how far they follow it. Without
            // a measured motion it is a plain dissolve.
            guard p > 0, p < 1 else { return p <= 0 ? a : b }
            if let field = MorphFlow.field(from: a, to: b, in: bounds),
               let leaving = MorphFlow.warped(a, along: field, by: -p * options.amount, in: bounds),
               let arriving = MorphFlow.warped(b, along: field, by: (1 - p) * options.amount, in: bounds) {
                return mix(leaving, arriving, p)
            }
            return mix(a, b, p)
        case .crossDissolve, .filmDissolve, .wipe, .slide, .zoom, .spin:
            // Drawn on the clip alone by the compositor; never asked for.
            return mix(a, b, p)
        }
    }

    // MARK: - Helpers

    /// The picture before until halfway and the next one after, broken up
    /// most in the middle: color channels pulled apart sideways and bands
    /// torn sideways, some of them from the other picture. The breaks
    /// change 24 times over the transition and are the same every time it
    /// plays.
    static func glitched(_ a: CIImage, _ b: CIImage, progress p: Double, amount: Double, in bounds: CGRect) -> CIImage {
        let intensity = amount * sin(.pi * p)
        let base = opaque(p < 0.5 ? a : b, in: bounds)
        guard intensity > 0.001 else { return base }
        let step = Int(p * 24)
        var draw = 0
        func random() -> Double {
            draw += 1
            return TransitionMasks.unitRandom(step * 101 + draw)
        }
        let shift = bounds.width * 0.02 * intensity
        let red = scaled(base, red: 1, green: 0, blue: 0).transformed(by: CGAffineTransform(translationX: shift, y: 0))
        let green = scaled(base, red: 0, green: 1, blue: 0)
        let blue = scaled(base, red: 0, green: 0, blue: 1).transformed(by: CGAffineTransform(translationX: -shift, y: 0))
        var output = add(add(green, red), blue).cropped(to: bounds)
        for _ in 0..<6 {
            let height = bounds.height * (0.02 + 0.1 * random())
            let y = bounds.minY + (bounds.height - height) * random()
            let dx = (random() - 0.5) * 2 * bounds.width * 0.1 * intensity
            let source = random() < p ? b : a
            let band = source.cropped(to: CGRect(x: bounds.minX, y: y, width: bounds.width, height: height))
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
            output = band.composited(over: output)
        }
        return output.cropped(to: bounds)
    }

    /// `image`, filling `bounds`, turned by `angle` about the middle line
    /// running across the way it moves (an upright line when
    /// `horizontally`), that line `depth` behind the screen, then seen in
    /// perspective from in front. Nothing when it is edge on or facing
    /// away.
    static func turned(_ image: CIImage, by angle: Double, horizontally: Bool, depth: Double, in bounds: CGRect) -> CIImage {
        let w = Double(bounds.width), h = Double(bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let camera = 2 * max(w, h)
        // The picture faces the camera when the axis's normal does.
        guard cos(angle) > 0.01 else { return CIImage.empty() }
        func project(_ x: Double, _ y: Double) -> CIVector {
            // In the picture's own plane, measured from its middle, which
            // sits `depth` in front of the turning axis.
            var (px, py, pz) = (x, y, -depth)
            if horizontally {
                (px, pz) = (px * cos(angle) + pz * sin(angle), -px * sin(angle) + pz * cos(angle))
            } else {
                (py, pz) = (py * cos(angle) + pz * sin(angle), -py * sin(angle) + pz * cos(angle))
            }
            let scale = camera / (camera + pz + depth)
            return CIVector(x: center.x + px * scale, y: center.y + py * scale)
        }
        return image.cropped(to: bounds).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": project(-w / 2, h / 2),
            "inputTopRight": project(w / 2, h / 2),
            "inputBottomRight": project(w / 2, -h / 2),
            "inputBottomLeft": project(-w / 2, -h / 2),
        ])
    }

    /// A whole frame's travel in `direction`, in the output's coordinates.
    static func offset(_ direction: TransitionDirection, in bounds: CGRect) -> CGVector {
        let step = direction.step
        // The timeline's frame measures y downward, the output upward.
        return CGVector(dx: step.dx * bounds.width, dy: -step.dy * bounds.height)
    }

    /// `image` scaled by `factor` about `center`.
    static func scaled(_ image: CIImage, by factor: Double, about center: CGPoint) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: factor, y: factor))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
    }

    /// `image` with a zoom blur of `amount` toward `center`, cut to `bounds`.
    static func zoomBlurred(_ image: CIImage, amount: Double, center: CGPoint, in bounds: CGRect) -> CIImage {
        let framed = image.cropped(to: bounds)
        guard amount > 0.5 else { return framed }
        return framed.clampedToExtent()
            .applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                kCIInputAmountKey: amount,
            ])
            .cropped(to: bounds)
    }

    /// A matte wipe's map, filling the output: a video's frame stretched to
    /// it, or fixed noise in small blocks, gray in every channel.
    static func matteMap(_ source: MatteSource, in bounds: CGRect) -> CIImage {
        if case .clip(let id) = source, let frame = MatteMaps.shared.image(for: id), frame.extent.width > 0, frame.extent.height > 0 {
            let extent = frame.extent
            return frame
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                    .concatenating(CGAffineTransform(scaleX: bounds.width / extent.width, y: bounds.height / extent.height))
                    .concatenating(CGAffineTransform(translationX: bounds.minX, y: bounds.minY)))
                .cropped(to: bounds)
        }
        let block = max(2, bounds.width / 160)
        let red = CIVector(x: 1, y: 0, z: 0, w: 0)
        return CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": red, "inputGVector": red, "inputBVector": red,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: block, y: block).concatenating(CGAffineTransform(translationX: bounds.minX, y: bounds.minY)))
            .cropped(to: bounds)
    }

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
