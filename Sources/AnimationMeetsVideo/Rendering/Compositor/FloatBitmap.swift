import CoreImage
import Foundation

/// Moves pictures between Core Image and plain float arrays, rows from the
/// top. Which end Core Image's bitmaps start from is found once, by
/// drawing a known picture, rather than assumed.
enum FloatBitmap {
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// `image`'s red, green, blue and alpha in `width` by `height` from the
    /// origin, rows from the top.
    static func read(_ image: CIImage, width: Int, height: Int) -> [Float] {
        var rgba = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &rgba, rowBytes: width * 16,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: nil)
        return renderStartsAtTop ? rgba : flipped(rgba, width: width, height: height)
    }

    /// An image at the origin from red, green, blue and alpha, rows from
    /// the top.
    static func image(_ rgba: [Float], width: Int, height: Int) -> CIImage {
        let rows = bitmapStartsAtTop ? rgba : flipped(rgba, width: width, height: height)
        return CIImage(
            bitmapData: rows.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil
        )
    }

    private static func flipped(_ rgba: [Float], width: Int, height: Int) -> [Float] {
        var out = rgba
        let row = width * 4
        for y in 0..<height {
            let from = (height - 1 - y) * row
            out.replaceSubrange((y * row)..<((y + 1) * row), with: rgba[from..<(from + row)])
        }
        return out
    }

    /// Whether a rendered bitmap's first row is the top of the image:
    /// white drawn in the upper of two points shows which.
    private static let renderStartsAtTop: Bool = {
        let top = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 1, width: 1, height: 1))
        let picture = top.composited(over: CIImage(color: .black)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 2))
        var rgba = [Float](repeating: 0, count: 8)
        context.render(picture, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 2), format: .RGBAf, colorSpace: nil)
        return rgba[0] > 0.5
    }()

    /// Whether an image made from a bitmap takes its first row as the top.
    private static let bitmapStartsAtTop: Bool = {
        let rows: [Float] = [1, 1, 1, 1, 0, 0, 0, 1]
        let picture = CIImage(
            bitmapData: rows.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
            size: CGSize(width: 1, height: 2), format: .RGBAf, colorSpace: nil
        )
        // `read` gives rows from the top, so the first value is the top's.
        return read(picture, width: 1, height: 2)[0] > 0.5
    }()
}
