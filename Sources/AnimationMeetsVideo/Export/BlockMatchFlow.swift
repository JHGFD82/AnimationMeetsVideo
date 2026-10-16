import CoreImage
import Foundation

/// The motion a morph follows, measured for one frame of it: for each
/// 4-pixel block of that frame, the move that best lines up the picture
/// before, looked at back along the move by the share of it already made,
/// with the picture after, looked at forward along the rest. That is the
/// motion at each point of the frame being drawn, which a warp needs;
/// motion measured at each point of the picture before (as optical flow
/// usually is) leaves nothing where a shape is passing through.
///
/// It works on small gray copies, coarse to fine over four sizes so large
/// moves are found cheaply. Plain areas, which line up with anything, stay
/// still. It runs anywhere, without a GPU or Vision, and always gives the
/// same answer.
enum BlockMatchFlow {
    /// The finest copy's width; the coarser ones are a half, a quarter and
    /// an eighth.
    static let width = 192
    private static let block = 4

    /// The whole move from `before` to `after` at each point of the frame
    /// `progress` of the way between them, in output points: red across,
    /// green up.
    static func field(from before: CIImage, to after: CIImage, progress: Double, in bounds: CGRect) -> CIImage? {
        guard bounds.width >= 8, bounds.height >= 8 else { return nil }
        let height = max(block * 2, Int((Double(width) * bounds.height / bounds.width).rounded()))
        guard let a = gray(before, width: width, height: height, in: bounds),
              let b = gray(after, width: width, height: height, in: bounds)
        else { return nil }

        // Coarse to fine: each level starts from the coarser one's moves,
        // doubled, and looks a little around them.
        var levels = [(a, b)]
        for _ in 0..<3 { levels.append((levels[levels.count - 1].0.halved, levels[levels.count - 1].1.halved)) }
        var moves: Moves?
        for (index, level) in levels.enumerated().reversed() {
            let coarsest = index == levels.count - 1
            moves = match(level.0, level.1, progress: Float(min(max(progress, 0), 1)), guess: moves,
                          reach: coarsest ? max(level.0.width / 3, 2) : 2)
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
    /// level's move, doubled).
    ///
    /// A move scores by how badly the two pictures differ along it, less a
    /// quarter of how much what it lines up stands out from each picture's
    /// average. Where a shape passes over a plain background, "nothing
    /// moved" lines up background with background as well as the move
    /// lines up the shape, and this picks the shape. A block that scores
    /// about as well at its guess, being plain, keeps the guess.
    private static func match(_ a: Gray, _ b: Gray, progress: Float, guess: Moves?, reach: Int) -> Moves {
        let columns = max(1, a.width / block), rows = max(1, a.height / block)
        let meanA = a.values.reduce(0, +) / Float(max(a.values.count, 1))
        let meanB = b.values.reduce(0, +) / Float(max(b.values.count, 1))
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
                var bestScore = Float.greatestFiniteMagnitude
                var guessScore: Float = 0
                for dy in (start.1 - reach)...(start.1 + reach) {
                    for dx in (start.0 - reach)...(start.0 + reach) {
                        // Back along the share made, forward along the rest.
                        let backX = Int((progress * Float(dx)).rounded()), backY = Int((progress * Float(dy)).rounded())
                        var cost: Float = 0, standing: Float = 0
                        for y in y0..<(y0 + block) {
                            for x in x0..<(x0 + block) {
                                let before = a[x - backX, y - backY], after = b[x - backX + dx, y - backY + dy]
                                cost += abs(before - after)
                                standing += abs(before - meanA) + abs(after - meanB)
                            }
                        }
                        let score = cost - 0.25 * standing
                        if dx == start.0, dy == start.1 { guessScore = score }
                        // Ties go to the smaller move.
                        if score < bestScore - 1e-4
                            || (abs(score - bestScore) <= 1e-4 && dx * dx + dy * dy < best.dx * best.dx + best.dy * best.dy) {
                            bestScore = score
                            best = (dx, dy)
                        }
                    }
                }
                if guessScore - bestScore < 0.02 * Float(block * block) { best = (start.0, start.1) }
                values.append(best)
            }
        }
        return Moves(columns: columns, rows: rows, values: values)
    }
}
