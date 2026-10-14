import CoreMedia
import SwiftUI

/// A clip's sound, drawn faded behind its label once its layer is tall
/// enough to read one: below `minimumHeight` it isn't drawn at all, and it
/// fades in over the next `fadeRange` points of height, so vertical zoom
/// brings it up gradually rather than switching it on.
struct ClipWaveform: View {
    static let minimumHeight: CGFloat = 64
    static let fadeRange: CGFloat = 32

    let url: URL
    /// The file time at the left edge of the drawn part of the clip, in
    /// seconds, and how many seconds of file each point covers.
    let fileStart: Double
    let secondsPerPoint: Double
    let width: CGFloat
    let height: CGFloat

    /// How strongly a layer `height` tall shows its waveform, 0 to 1.
    static func strength(atHeight height: CGFloat) -> Double {
        Double(min(max((height - minimumHeight) / fadeRange, 0), 1))
    }

    var body: some View {
        if let waveform = WaveformCache.shared.waveform(for: url), !waveform.peaks.isEmpty {
            Canvas(rendersAsynchronously: true) { context, size in
                // One bar every two points, mirrored about the middle.
                let step: CGFloat = 2
                let middle = size.height / 2
                let reach = middle - 3
                var path = Path()
                var x: CGFloat = 0
                while x < size.width {
                    let start = fileStart + Double(x) * secondsPerPoint
                    let peak = CGFloat(waveform.peak(from: start, to: start + Double(step) * secondsPerPoint))
                    let half = max(0.5, peak * reach)
                    path.addRect(CGRect(x: x, y: middle - half, width: step - 0.6, height: half * 2))
                    x += step
                }
                context.fill(path, with: .color(Design.textOnColor))
            }
            .frame(width: width, height: height)
            .opacity(0.32 * Self.strength(atHeight: height))
            .allowsHitTesting(false)
        }
    }
}
