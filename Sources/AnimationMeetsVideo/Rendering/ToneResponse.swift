import CoreImage
import CoreMedia
import Foundation

/// What a look does to each tone, measured by drawing it: a row of grays
/// from black to reference white, drawn through the effect's own kernel in
/// a Rec. 709 timeline and read back as tones, each channel apart. A tone
/// graph draws this for an effect without curves of its own (Levels,
/// Threshold), so the line is what the kernel does, never a copy of its
/// math that could drift from it. Tones are the same in every color space
/// (see docs/effects-correction.md, "Where they work"), so one is enough.
enum ToneResponse {
    /// Grays measured, black and white among them.
    static let count = 129

    /// Each of `count` grays from black to white as `effect` leaves it at
    /// source time `time`: its red, green and blue tones. The grays
    /// themselves for an effect that draws nothing there (off, or mixed in
    /// at 0%); nil for one that isn't a look.
    static func measure(_ effect: Effect, at time: CMTime) -> [SIMD3<Double>]? {
        let grays = (0..<count).map { Double($0) / Double(count - 1) }
        guard effect.kind.isLook else { return nil }
        guard effect.enabled, let step = LookStep(effect, at: time) else { return grays.map { SIMD3(repeating: $0) } }
        let frame = CGRect(x: 0, y: 0, width: count, height: 1)
        let pixels = grays.flatMap { gray -> [Float] in
            let encoded = Float(encoded(tone: gray))
            return [encoded, encoded, encoded, 1]
        }
        let picture = FloatBitmap.image(pixels, width: count, height: 1)
        let drawn = LookRenderer.apply(step, to: picture, over: frame, canvas: frame, frame: frame, scale: 1, space: .rec709)
        let read = FloatBitmap.read(drawn, width: count, height: 1)
        return (0..<count).map { i in
            let alpha = Double(read[i * 4 + 3])
            let channel = { (offset: Int) in alpha > 0 ? tone(Double(read[i * 4 + offset]) / alpha) : 0 }
            return SIMD3(channel(0), channel(1), channel(2))
        }
    }

    // The prelude's `toTones` and `fromTones` for Rec. 709 (LookKernels),
    // in double precision.

    private static let logBlack = 0.0729055341958355, logWhite = 0.5547945

    private static func linear(_ e: Double) -> Double {
        let a = abs(e)
        return (e < 0 ? -1 : 1) * (a < 0.081 ? a / 4.5 : pow((a + 0.099) / 1.099, 1 / 0.45))
    }

    private static func encoded(linear l: Double) -> Double {
        let a = abs(l)
        return (l < 0 ? -1 : 1) * (a < 0.018 ? 4.5 * a : 1.099 * pow(a, 0.45) - 0.099)
    }

    static func tone(_ encoded: Double) -> Double {
        let l = linear(encoded)
        let log = l <= 0.0078125 ? 10.5402377416545 * l + logBlack : (log2(l) + 9.72) / 17.52
        return (log - logBlack) / (logWhite - logBlack)
    }

    static func encoded(tone t: Double) -> Double {
        let c = logBlack + t * (logWhite - logBlack)
        return encoded(linear: c <= 0.155251141552511 ? (c - logBlack) / 10.5402377416545 : exp2(c * 17.52 - 9.72))
    }
}
