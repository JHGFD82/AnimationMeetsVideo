import Foundation
@testable import AnimationMeetsVideo

/// Each timeline's encoding to linear light (1 is reference white) and
/// back, in double precision, as the kernels' prelude does it: Rec. 709,
/// PQ with reference white at 203 nits, and HLG at a 75% signal.
enum TransferCurves {
    static func sgn(_ x: Double) -> Double { x < 0 ? -1 : 1 }
    static func linear(_ e: Double, _ space: ProjectColorSpace) -> Double {
        let a = abs(e)
        switch space {
        case .rec709: return sgn(e) * (a < 0.081 ? a / 4.5 : pow((a + 0.099) / 1.099, 1 / 0.45))
        case .rec2020PQ:
            let p = pow(min(a, 1), 1 / 78.84375)
            return sgn(e) * pow(max(p - 0.8359375, 0) / (18.8515625 - 18.6875 * p), 1 / 0.1593017578125) * 10000 / 203
        case .rec2020HLG:
            let s = a <= 0.5 ? a * a / 3 : (exp((a - 0.55991073) / 0.17883277) + 0.28466892) / 12
            return sgn(e) * s / 0.26500502
        }
    }
    static func encoded(linear l: Double, _ space: ProjectColorSpace) -> Double {
        let a = abs(l)
        switch space {
        case .rec709: return sgn(l) * (a < 0.018 ? 4.5 * a : 1.099 * pow(a, 0.45) - 0.099)
        case .rec2020PQ:
            let p = pow(a * 203 / 10000, 0.1593017578125)
            return sgn(l) * pow((0.8359375 + 18.8515625 * p) / (1 + 18.6875 * p), 78.84375)
        case .rec2020HLG:
            let s = a * 0.26500502
            return sgn(l) * (s <= 1.0 / 12 ? (3 * s).squareRoot() : 0.17883277 * log(12 * s - 0.28466892) + 0.55991073)
        }
    }
}
