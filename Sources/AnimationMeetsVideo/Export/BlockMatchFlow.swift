import CoreImage
import Foundation

/// A coarse optical flow for morphs where Vision can't measure one: each
/// 4-pixel block of a small gray copy of the picture before is matched to
/// where it fits best in the picture after, coarse to fine over three
/// sizes, so large moves are found cheaply. Plain areas, which match
/// anywhere, stay still. Less exact than Vision's, but it runs anywhere and
/// always gives the same answer.
enum BlockMatchFlow {
    /// The finest copy's width; the coarser ones are a half and a quarter.
    static let width = 96
    private static let block = 4

    /// How far each point moves, in output points: red across, green up.
    static func field(from before: CIImage, to after: CIImage, in bounds: CGRect) -> CIImage? {
        guard bounds.width >= 8, bounds.height >= 8 else { return nil }
        let height = max(block * 2, Int((Double(width) * bounds.height / bounds.width).rounded()))
        guard let a = gray(before, width: width, height: height, in: bounds),
              let b = gray(after, width: width, height: height, in: bounds)
        else { return nil }

        // Coarse to fine: each level starts from the coarser one's moves,
        // doubled, and looks a little around them.
        let levels = [(a, b), (a.halved, b.halved), (a.halved.halved, b.halved.halved)]
        var moves: Moves?
        for (index, level) in levels.enumerated().reversed() {
            let coarsest = index == levels.count - 1
            moves = match(level.0, level.1, guess: moves, reach: coarsest ? max(level.0.width / 3, 2) : 2)
        }
        guard let moves else { return nil }

        // Blocks to output points. The copies count rows from the top, so
        // a move down is a move down the output's y.
        let scaleX = Float(bounds.width) / Float(width), scaleY = Float(bounds.height) / Float(height)
        var pixels = [Float](repeating: 0, count: moves.columns * moves.rows * 4)
        for row in 0..<moves.rows {
            for col in 0..<moves.columns {
                let move = moves[col, row]
                let index = (row * moves.columns + col) * 4
                pixels[index] = Float(move.dx) * scaleX
                pixels[index + 1] = -Float(move.dy) * scaleY
                pixels[index + 3] = 1
            }
        }
        return FloatBitmap.image(pixels, width: moves.columns, height: moves.rows)
        .samplingLinear()
        .transformed(by: CGAffineTransform(scaleX: bounds.width / CGFloat(moves.columns), y: bounds.height / CGFloat(moves.rows))
            .concatenating(CGAffineTransform(translationX: bounds.minX, y: bounds.minY)))
        .cropped(to: bounds)
    }

    // MARK: - Pictures

    /// A small gray copy, rows from the top.
    struct Gray {
        var width: Int
        var height: Int
        var values: [Float]

        subscript(x: Int, y: Int) -> Float {
            values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }

        /// Half the size, each value the mean of four.
        var halved: Gray {
            let w = max(1, width / 2), h = max(1, height / 2)
            var out = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    out[y * w + x] = (self[2 * x, 2 * y] + self[2 * x + 1, 2 * y] + self[2 * x, 2 * y + 1] + self[2 * x + 1, 2 * y + 1]) / 4
                }
            }
            return Gray(width: w, height: h, values: out)
        }
    }

    private static func gray(_ image: CIImage, width: Int, height: Int, in bounds: CGRect) -> Gray? {
        let small = CGRect(x: 0, y: 0, width: width, height: height)
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
                .concatenating(CGAffineTransform(scaleX: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)))
            .composited(over: CIImage(color: .black))
            .cropped(to: small)
        let rgba = FloatBitmap.read(scaled, width: width, height: height)
        var values = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            values[i] = 0.2126 * rgba[i * 4] + 0.7152 * rgba[i * 4 + 1] + 0.0722 * rgba[i * 4 + 2]
        }
        return Gray(width: width, height: height, values: values)
    }

    // MARK: - Matching

    struct Moves {
        var columns: Int
        var rows: Int
        var values: [(dx: Int, dy: Int)]

        subscript(col: Int, row: Int) -> (dx: Int, dy: Int) {
            values[min(max(row, 0), rows - 1) * columns + min(max(col, 0), columns - 1)]
        }
    }

    /// Each block's best move within `reach` of its guess (the coarser
    /// level's move, doubled). A block whose cost hardly changes with the
    /// move, being plain, keeps the smallest move.
    private static func match(_ a: Gray, _ b: Gray, guess: Moves?, reach: Int) -> Moves {
        let columns = max(1, a.width / block), rows = max(1, a.height / block)
        var values: [(dx: Int, dy: Int)] = []
        values.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for col in 0..<columns {
                let start = guess.map { g -> (Int, Int) in
                    let coarse = g[col / 2, row / 2]
                    return (coarse.dx * 2, coarse.dy * 2)
                } ?? (0, 0)
                let x0 = col * block, y0 = row * block
                var best = (dx: start.0, dy: start.1)
                var bestCost = Float.greatestFiniteMagnitude
                var stillCost: Float = 0
                for dy in (start.1 - reach)...(start.1 + reach) {
                    for dx in (start.0 - reach)...(start.0 + reach) {
                        var cost: Float = 0
                        for y in y0..<(y0 + block) {
                            for x in x0..<(x0 + block) {
                                cost += abs(a[x, y] - b[x + dx, y + dy])
                            }
                        }
                        if dx == start.0, dy == start.1 { stillCost = cost }
                        // Ties go to the smaller move.
                        if cost < bestCost - 1e-4 || (abs(cost - bestCost) <= 1e-4 && dx * dx + dy * dy < best.dx * best.dx + best.dy * best.dy) {
                            bestCost = cost
                            best = (dx, dy)
                        }
                    }
                }
                // A plain block matches everywhere about equally.
                if stillCost - bestCost < 0.02 * Float(block * block) { best = (start.0, start.1) }
                values.append(best)
            }
        }
        return Moves(columns: columns, rows: rows, values: values)
    }
}
