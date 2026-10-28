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
    /// Which file time each point across is.
    let fileTimes: WaveformFileTimes
    let width: CGFloat
    let height: CGFloat
    var splitsChannels = false
    /// Off, a waveform not read yet isn't read, until it is on again: for
    /// a clip being dragged.
    var loads = true

    init(url: URL, fileTimes: WaveformFileTimes, width: CGFloat, height: CGFloat, splitsChannels: Bool = false, loads: Bool = true) {
        self.url = url
        self.fileTimes = fileTimes
        self.width = width
        self.height = height
        self.splitsChannels = splitsChannels
        self.loads = loads
    }

    /// Sound read at one speed: `fileStart` (in seconds of the file) at
    /// the left edge, and `secondsPerPoint` more for each point across.
    init(url: URL, fileStart: Double, secondsPerPoint: Double, width: CGFloat, height: CGFloat, splitsChannels: Bool = false) {
        self.init(
            url: url, fileTimes: .linear(start: fileStart, secondsPerPoint: secondsPerPoint),
            width: width, height: height, splitsChannels: splitsChannels
        )
    }

    /// How strongly a layer `height` tall shows its waveform, 0 to 1.
    static func strength(atHeight height: CGFloat) -> Double {
        Double(((height - minimumHeight) / fadeRange).clamped(between: 0, and: 1))
    }

    /// Names for the bands of a split waveform.
    static func channelName(_ channel: Int, of count: Int) -> String {
        guard count == 2 else { return count == 1 ? "M" : "\(channel + 1)" }
        return channel == 0 ? "L" : "R"
    }

    var body: some View {
        let cache = WaveformCache.shared
        if let waveform = loads ? cache.waveform(for: url) : cache.loadedWaveform(for: url), !waveform.peaks.isEmpty {
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
            let start = fileTimes.seconds(atX: x)
            // Backwards, the file is read toward its start.
            let end = fileTimes.seconds(atX: x + step)
            let peak = CGFloat(waveform.peak(from: min(start, end), to: max(start, end), channel: channel))
            let half = max(0.5, peak * reach)
            path.addRect(CGRect(x: x, y: middle - half, width: step - 0.6, height: half * 2))
            x += step
        }
        return path
    }
}

/// Which time of a file each point across a waveform shows: straight
/// between anchors, and on along the last stretch past the ends. Two
/// anchors draw sound read at one speed; a clip whose speed changes along
/// it is anchored every few points, and where each speed is set.
struct WaveformFileTimes: Equatable, Sendable {
    struct Anchor: Equatable, Sendable {
        /// Points from the left edge.
        var x: CGFloat
        /// Seconds of the file.
        var seconds: Double
    }

    /// Sorted by `x`, at least two, apart.
    let anchors: [Anchor]

    init(anchors: [Anchor]) {
        var sorted = anchors.sorted { $0.x < $1.x }
        if sorted.count == 1 { sorted.append(Anchor(x: sorted[0].x + 1, seconds: sorted[0].seconds)) }
        self.anchors = sorted
    }

    static func linear(start: Double, secondsPerPoint: Double) -> WaveformFileTimes {
        WaveformFileTimes(anchors: [Anchor(x: 0, seconds: start), Anchor(x: 1, seconds: start + secondsPerPoint)])
    }

    func seconds(atX x: CGFloat) -> Double {
        guard anchors.count >= 2 else { return anchors.first?.seconds ?? 0 }
        // The stretch holding `x`, or the nearest end one.
        var low = 0, high = anchors.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if anchors[middle].x <= x { low = middle } else { high = middle }
        }
        let a = anchors[low], b = anchors[high]
        guard b.x > a.x else { return a.seconds }
        return a.seconds + (b.seconds - a.seconds) * Double((x - a.x) / (b.x - a.x))
    }
}
