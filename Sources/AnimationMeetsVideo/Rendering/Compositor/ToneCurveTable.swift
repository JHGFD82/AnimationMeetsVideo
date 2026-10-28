import CoreImage
import Foundation
import Synchronization

/// A curve control as the picture a kernel reads it from (a package's
/// `curve` picture, read with the prelude's `curveTone`): one row of
/// `count` pixels, tones from black to white across, each holding in red
/// the tone it becomes and in green the slope the curve leaves white at.
/// Floats, without a color space, so nothing is matched or clamped.
enum ToneCurveTable {
    /// Enough that a line between neighbors stays within a ten-thousandth
    /// of any curve the editor can make.
    static let count = 512

    /// The tables made lately, by the curve's numbers, so a curve held
    /// still is the same image from frame to frame and Core Image's cache
    /// knows it.
    private static let made = Mutex<[[Double]: CIImage]>([:])

    static func image(_ curve: ToneCurve) -> CIImage {
        let values = curve.values
        if let image = made.withLock({ $0[values] }) { return image }
        let slope = Float(curve.slopeAtWhite)
        let image = FloatBitmap.image(curve.table(count: count).flatMap { [Float($0), slope, 0, 1] }, width: count, height: 1)
        made.withLock { made in
            if made.count >= 64 { made.removeAll() }
            made[values] = image
        }
        return image
    }
}
