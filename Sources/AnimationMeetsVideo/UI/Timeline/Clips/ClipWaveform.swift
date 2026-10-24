import CoreMedia
import SwiftUI

/// A clip's sound, drawn faded behind its label once its layer is tall
/// enough to read one: below `minimumHeight` it isn't drawn at all, and it
/// fades in over the next `fadeRange` points of height, so vertical zoom
/// brings it up gradually rather than switching it on.
///
/// With `splitsChannels` (a layer showing its channels) each channel gets
/// a band of its own, left above right, at any height.
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
    var splitsChannels = false

    /// How strongly a layer `height` tall shows its waveform, 0 to 1.
    static func strength(atHeight height: CGFloat) -> Double {
        Double(((height - minimumHeight) / fadeRange).clamped(to: 0...1))
    }

    /// Names for the bands of a split waveform.
    static func channelName(_ channel: Int, of count: Int) -> String {
        guard count == 2 else { return count == 1 ? "M" : "\(channel + 1)" }
        return channel == 0 ? "L" : "R"
    }

    var body: some View {
        if let waveform = WaveformCache.shared.waveform(for: url), !waveform.peaks.isEmpty {
            let bands: [Int?] = splitsChannels ? waveform.channels.indices.map { $0 } : [nil]
            Canvas(rendersAsynchronously: true) { context, size in
                let bandHeight = size.height / CGFloat(bands.count)
                for (index, channel) in bands.enumerated() {
                    let band = CGRect(x: 0, y: CGFloat(index) * bandHeight, width: size.width, height: bandHeight)
                    context.fill(bars(of: waveform, channel: channel, in: band), with: .color(Design.textOnColor))
                    if index > 0 {
                        context.fill(Path(CGRect(x: 0, y: band.minY - 0.5, width: size.width, height: 1)), with: .color(.black.opacity(0.35)))
                    }
                }
            }
            .frame(width: width, height: height)
            .opacity(splitsChannels ? 0.45 : 0.32 * Self.strength(atHeight: height))
            .overlay(alignment: .topLeading) {
                if splitsChannels, bands.count > 1 {
                    VStack(spacing: 0) {
                        ForEach(bands.indices, id: \.self) { index in
                            Text(Self.channelName(index, of: bands.count))
                                .font(Design.Typeface.micro)
                                .foregroundStyle(Design.textOnColor.opacity(0.8))
                                .padding(.leading, Design.Space.tight)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                    }
                    .frame(width: width, height: height)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// One bar every two points, mirrored about the middle of `band`.
    private func bars(of waveform: Waveform, channel: Int?, in band: CGRect) -> Path {
        let step: CGFloat = 2
        let middle = band.midY
        let reach = max(1, band.height / 2 - 3)
        var path = Path()
        var x: CGFloat = 0
        while x < band.width {
            let start = fileStart + Double(x) * secondsPerPoint
            // Backwards, the file is read toward its start.
            let end = start + Double(step) * secondsPerPoint
            let peak = CGFloat(waveform.peak(from: min(start, end), to: max(start, end), channel: channel))
            let half = max(0.5, peak * reach)
            path.addRect(CGRect(x: x, y: middle - half, width: step - 0.6, height: half * 2))
            x += step
        }
        return path
    }
}
