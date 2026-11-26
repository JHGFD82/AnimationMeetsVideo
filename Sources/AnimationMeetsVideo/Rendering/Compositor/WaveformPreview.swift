import CoreGraphics
import CoreMedia
import Foundation

/// Small pictures of each kind of Waveform graph (`WaveformGraph`), for
/// the Graph picker's buttons: each drawn by `WaveformDrawing` itself, as
/// a new Waveform set up as that graph draws it, from a made-up sound (a
/// low chord over partials spread across the spectrum, falling off
/// toward the highs, swelling twice a second, a little different on the
/// right), so the picture is what the graph will look like.
enum WaveformPreview {
    /// The frame the previews are drawn on.
    static let frame = CGSize(width: 160, height: 90)

    /// The shapes of `graph`'s picture on `frame`, each with how opaque it
    /// is. Worked out once a graph.
    static func shapes(of graph: WaveformGraph) -> [(path: CGPath, alpha: Double)] {
        lock.withLock {
            if let kept = drawn[graph] { return kept }
            let made = draw(graph)
            drawn[graph] = made
            return made
        }
    }

    nonisolated(unsafe) private static var drawn: [WaveformGraph: [(path: CGPath, alpha: Double)]] = [:]
    private static let lock = NSLock()

    private static let audio: WaveformAudio = {
        let audio = WaveformAudio()
        let rate = WaveformAudio.Samples.rate
        let count = Int(rate * seconds)
        var left = [Int16](repeating: 0, count: count), right = left
        // Partials from 40 Hz to 16 kHz, a third of an octave apart, each
        // quieter than the last, with phases that don't line up.
        let partials = (0..<28).map { k in (frequency: 40 * pow(2, Double(k) / 3), level: 0.18 / pow(1.12, Double(k)), phase: Double(k * k) * 0.7) }
        for i in 0..<count {
            let t = Double(i) / rate
            let swell = 0.55 + 0.45 * sin(2 * .pi * 2 * t)
            let chord = sin(2 * .pi * 110 * t) * 0.35 + sin(2 * .pi * 165 * t) * 0.2
            let spread = partials.reduce(0) { $0 + sin(2 * .pi * $1.frequency * t + $1.phase) * $1.level }
            left[i] = Int16(((chord + spread) * swell * 26_000).clamped(between: -32_000, and: 32_000))
            let other = sin(2 * .pi * 110 * t + 1.2) * 0.35 + partials.reduce(0) { $0 + cos(2 * .pi * $1.frequency * t + $1.phase) * $1.level }
            right[i] = Int16((other * swell * 26_000).clamped(between: -32_000, and: 32_000))
        }
        audio.store(WaveformAudio.Samples(channels: [left, right]), for: url)
        return audio
    }()

    private static let seconds = 4.0
    private static let url = URL(fileURLWithPath: "/amv-waveform-preview.wav")

    private static func draw(_ graph: WaveformGraph) -> [(path: CGPath, alpha: Double)] {
        var effect = Effect(kind: .waveform)
        effect.sizeShape(to: frame)
        graph.apply(to: &effect)
        // Every graph in one tone, its shading in how opaque it is.
        effect.changeControl(.fill) { $0.enabled = true; $0.number = AnimatedValue(ComponentValue(values: [1, 1, 1, 1])) }
        effect.changeControl(.stroke) { $0.number = AnimatedValue(ComponentValue(values: [1, 1, 1, 1])) }
        effect.changeControl(.strokeWidth) { $0.number = AnimatedValue(ComponentValue(values: [graph == .scope ? 2 : 4])) }
        effect.changeControl(.waveSamples) { $0.number = AnimatedValue(ComponentValue(values: [graph == .bars || graph == .rays ? 16 : 48])) }
        effect.changeControl(.waveWindow) { control in
            if graph != .spectrogram { control.number = AnimatedValue(ComponentValue(values: [graph == .scope ? 20 : 30])) }
        }
        effect.changeControl(.dotSize) { $0.number = AnimatedValue(ComponentValue(values: [8])) }
        let round: Set<WaveformGraph> = [.ring, .rays, .particles]
        effect.changeControl(.waveHeight) { control in
            let height = graph == .meter || graph == .spectrogram ? 70.0 : round.contains(graph) ? 14 : 70
            control.number = AnimatedValue(ComponentValue(values: [height]))
        }
        if graph == .meter { effect.changeControl(.waveGain) { $0.number = AnimatedValue(ComponentValue(values: [-4])) } }
        if graph == .spectrogram { effect.changeControl(.waveGain) { $0.number = AnimatedValue(ComponentValue(values: [12])) } }
        if graph == .spectrogram { effect.changeControl(.waveSamples) { $0.number = AnimatedValue(ComponentValue(values: [24])) } }
        if graph == .meter || graph == .spectrogram {
            // Up from near the bottom.
            effect.changeControl(.waveStart) { $0.number = AnimatedValue(ComponentValue(values: [-60, 35])) }
            effect.changeControl(.waveEnd) { $0.number = AnimatedValue(ComponentValue(values: [60, 35])) }
            effect.changeControl(.waveStereo) { $0.choice = WaveformStereo.split.rawValue }
        }
        if graph == .meter { effect.changeControl(.barWidth) { $0.number = AnimatedValue(ComponentValue(values: [30])) } }
        effect.changeControl(.waveRadius) { $0.number = AnimatedValue(ComponentValue(values: [24])) }
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        guard let setup = WaveformSetup(effect, at: .zero, center: center) else { return [] }
        let asset = MediaClip(
            name: "Preview", kind: .audio, url: url, duration: CMTime(seconds: seconds, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "PCM"
        )
        let clip = TimelineClip(
            source: .media(asset.id), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(seconds: seconds, preferredTimescale: 600),
            streams: .audio
        )
        let sound = WaveformSound(sources: [WaveformSound.Source(url: url, clip: clip, asset: asset, layerVolume: nil)], fingerprint: 0x9e37_79b9)
        let step = WaveformStep(effectID: effect.id, setup: setup, time: 3.1)
        return WaveformDrawing.paints(step, sound: sound, frame: CGRect(origin: .zero, size: frame), audio: audio).map { paint in
            (paint.area, paint.color.count == 4 ? paint.color[3] : 1)
        }
    }
}
