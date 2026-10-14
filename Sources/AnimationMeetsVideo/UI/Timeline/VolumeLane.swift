import CoreMedia
import SwiftUI

/// A layer's volume under its clips: the level as a line, high for loud
/// (the top is +6 dB, the bottom mute, a faint line marks 0 dB), with the
/// keyframes as diamonds on the lane to click, drag and delete as on a
/// transform property.
struct VolumeLane: View {
    static let height: CGFloat = 34

    let volume: AnimatedValue<Double>
    let currentTime: CMTime
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    /// The on-screen part of the lane, in its own x coordinates.
    let visibleX: ClosedRange<CGFloat>
    let snap: (CMTime) -> CMTime
    let onSeek: (CMTime) -> Void
    let onMove: (CMTime, CMTime) -> Void
    let onDelete: (CMTime) -> Void

    /// Where a level sits in the lane, 0 at the top.
    static func y(ofLevel decibels: Double, height: CGFloat) -> CGFloat {
        let range = AudioLevel.range
        let fraction = (AudioLevel.clamped(decibels) - range.lowerBound) / (range.upperBound - range.lowerBound)
        let inset: CGFloat = 4
        return inset + (height - inset * 2) * CGFloat(1 - fraction)
    }

    var body: some View {
        KeyframeLane(
            times: volume.keyframes.map(\.time),
            currentTime: currentTime,
            pixelsPerSecond: pixelsPerSecond,
            width: width,
            height: Self.height,
            snap: snap,
            onSeek: onSeek,
            onMove: onMove,
            onDelete: onDelete
        )
        .overlay(alignment: .topLeading) {
            // Drawn only across what is on screen: the lane spans the whole
            // timeline, which zoomed in is far too wide for one canvas.
            let minX = max(0, visibleX.lowerBound)
            let maxX = min(width, visibleX.upperBound)
            if maxX > minX {
                Canvas { context, size in
                    let unity = Self.y(ofLevel: 0, height: size.height)
                    context.fill(Path(CGRect(x: 0, y: unity, width: size.width, height: 0.5)), with: .color(Design.textTertiary.opacity(0.5)))
                    var line = Path()
                    var x: CGFloat = 0
                    while x <= size.width + 2 {
                        let time = CMTime(seconds: Double((minX + x) / pixelsPerSecond), preferredTimescale: 600)
                        let point = CGPoint(x: x, y: Self.y(ofLevel: volume.value(at: time), height: size.height))
                        if line.isEmpty { line.move(to: point) } else { line.addLine(to: point) }
                        x += 2
                    }
                    context.stroke(line, with: .color(Design.ClipTone.audio.color), lineWidth: 1.5)
                }
                .frame(width: maxX - minX, height: Self.height)
                .offset(x: minX)
                .allowsHitTesting(false)
            }
        }
    }
}
