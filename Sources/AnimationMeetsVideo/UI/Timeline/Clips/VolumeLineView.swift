import SwiftUI

/// A clip's volume as a line across the drawn part of its block, as on the
/// layer volume lane: mute at the bottom, +6 dB at the top, and a faint
/// line at 0 dB. Equatable on what it draws, so the canvas is drawn again
/// only when the level, the stretch shown or the size changes, not each
/// time the block is.
struct VolumeLineView: View, Equatable {
    let volume: AnimatedValue<Double>
    /// The clip's source time at the line's left edge, in seconds.
    let firstSeconds: Double
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat

    /// How far apart the line is read between keyframes, in points.
    nonisolated static let step: CGFloat = 6

    var body: some View {
        let points = Self.points(of: volume, firstSeconds: firstSeconds, pixelsPerSecond: pixelsPerSecond, width: width)
        Canvas { context, size in
            let unity = VolumeLane.y(ofLevel: 0, height: size.height)
            context.fill(Path(CGRect(x: 0, y: unity, width: size.width, height: 0.5)), with: .color(Design.textOnColor.opacity(0.35)))
            var line = Path()
            for (index, point) in points.enumerated() {
                let point = CGPoint(x: point.x, y: VolumeLane.y(ofLevel: point.level, height: size.height))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(Design.textOnColor.opacity(0.9)), lineWidth: 1.5)
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// Where the line goes, left to right, as x in points and level in dB:
    /// both ends when the level doesn't change across the width, otherwise
    /// a point every `step` and two at each keyframe in between, one on it
    /// and one just before, so its corner, or a hold's step, is drawn
    /// where it is.
    nonisolated static func points(
        of volume: AnimatedValue<Double>, firstSeconds: Double, pixelsPerSecond: CGFloat, width: CGFloat
    ) -> [(x: CGFloat, level: Double)] {
        guard width > 0, pixelsPerSecond > 0 else { return [] }
        let lastSeconds = firstSeconds + Double(width / pixelsPerSecond)
        // Constant outside its keyframes, so constant here unless they
        // reach into the width.
        guard let range = volume.animatedRange,
              range.upperBound.seconds > firstSeconds, range.lowerBound.seconds < lastSeconds
        else {
            let level = volume.value(atSeconds: firstSeconds)
            return [(x: 0, level: level), (x: width, level: level)]
        }
        var xs: [CGFloat] = Array(stride(from: 0, to: width, by: step))
        xs.append(width)
        for keyframe in volume.keyframes {
            let keyX = CGFloat(keyframe.time.seconds - firstSeconds) * pixelsPerSecond
            guard keyX > 0, keyX < width else { continue }
            xs += [max(0, keyX - 0.01), keyX]
        }
        xs.sort()
        return xs.map { pointX in
            (x: pointX, level: volume.value(atSeconds: firstSeconds + Double(pointX / pixelsPerSecond)))
        }
    }
}
