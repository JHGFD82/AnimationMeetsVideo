import SwiftUI

/// How paths drawn with the pen are drawn over the picture (see
/// docs/pen-tool.md, "The path color"): a bright line in the path color
/// over a dark casing, never a difference blend, so it reads over dark,
/// bright, middle-gray and busy pictures alike and keeps a color of its
/// own. Points are 7 point squares, hollow, filled when picked; a
/// tangent's end is a 6 point dot at the end of a 1 point line. Shared by
/// the arrow's handles (`ViewerHandlesOverlay`) and the pen (`PenOverlay`).
enum PathDrawing {
    /// The path color a preference holds, magenta when it holds none.
    static func color(_ hex: String) -> Color {
        Design.color(BarColor(hex: hex) ?? BarColor(hex: Preferences.defaultPenColor)!)
    }

    private static let casing = Color.black.opacity(0.5)

    /// A path's line: 1.5 points over 3.5 of the casing.
    static func line(_ path: Path, color: Color, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(casing), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    /// The next stretch's preview: 1 point over 3.
    static func preview(_ path: Path, color: Color, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(casing), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
    }

    /// From a point to its tangent's end.
    static func tangentLine(_ path: Path, color: Color, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(casing), lineWidth: 2.5)
        context.stroke(path, with: .color(color), lineWidth: 1)
    }

    /// A point at `place` (view points): hollow, or filled when picked.
    static func vertex(at place: CGPoint, picked: Bool, color: Color, alpha: Double = 1, in context: inout GraphicsContext) {
        let side = 7.0
        let square = Path(CGRect(x: place.x - side / 2, y: place.y - side / 2, width: side, height: side))
        context.stroke(square, with: .color(casing.opacity(alpha)), lineWidth: 3)
        context.fill(square, with: .color((picked ? color : Color.black.opacity(0.75)).opacity(alpha)))
        context.stroke(square, with: .color(color.opacity(alpha)), lineWidth: 1)
    }

    /// The end of a tangent at `place`.
    static func tangentEnd(at place: CGPoint, color: Color, alpha: Double = 1, in context: inout GraphicsContext) {
        let dot = Path(ellipseIn: CGRect(x: place.x - 3, y: place.y - 3, width: 6, height: 6))
        context.stroke(dot, with: .color(casing.opacity(alpha)), lineWidth: 2.5)
        context.fill(dot, with: .color(color.opacity(alpha)))
    }

    /// The ring the first point wears while a click on it would close the
    /// path.
    static func closingRing(at place: CGPoint, color: Color, in context: inout GraphicsContext) {
        let ring = Path(ellipseIn: CGRect(x: place.x - 8, y: place.y - 8, width: 16, height: 16))
        context.stroke(ring, with: .color(casing), lineWidth: 3)
        context.stroke(ring, with: .color(color), lineWidth: 1.5)
    }
}
