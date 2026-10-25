import CoreGraphics
import Foundation

/// How much of a clip each thumbnail of its filmstrip stands for. Each step
/// is two to three times the next, so each notch of the slider changes the
/// view by a similar amount. See docs/browser.md, "Filmstrips".
enum ThumbnailInterval: Int, CaseIterable, Identifiable {
    case all, oneMinute, thirtySeconds, tenSeconds, fiveSeconds, twoSeconds, oneSecond

    var id: Self { self }

    /// Seconds per thumbnail; nil for one thumbnail per clip.
    var seconds: Double? {
        switch self {
        case .all: nil
        case .oneMinute: 60
        case .thirtySeconds: 30
        case .tenSeconds: 10
        case .fiveSeconds: 5
        case .twoSeconds: 2
        case .oneSecond: 1
        }
    }

    var title: String {
        switch self {
        case .all: "All"
        case .oneMinute: "1 min"
        case .thirtySeconds: "30 s"
        case .tenSeconds: "10 s"
        case .fiveSeconds: "5 s"
        case .twoSeconds: "2 s"
        case .oneSecond: "1 s"
        }
    }
}

/// How tall the browser draws thumbnails; widths follow each clip's shape.
enum ThumbnailSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    var height: CGFloat {
        switch self {
        case .small: 36
        case .medium: 54
        case .large: 76
        }
    }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// Where a clip's thumbnails go in a filmstrip that wraps onto further rows
/// once it is wider than the browser. Within a row the thumbnails touch.
/// Every thumbnail is full size, the last one included even when it stands
/// for less time, and so is a clip shorter than one interval: a shortened
/// thumbnail is too small to read.
struct FilmstripLayout: Equatable {
    struct Cell: Equatable {
        /// Seconds into the clip where the thumbnail's stretch starts, and
        /// how long the stretch is.
        var start: Double
        var duration: Double
        var row: Int
        var frame: CGRect

        var end: Double { start + duration }
    }

    /// Space between rows.
    static let rowSpacing: CGFloat = 2

    let cells: [Cell]
    let cellSize: CGSize
    let rowCount: Int
    let duration: Double

    var rowPitch: CGFloat { cellSize.height + Self.rowSpacing }
    var size: CGSize {
        CGSize(
            width: cells.map(\.frame.maxX).max() ?? 0,
            height: CGFloat(rowCount) * cellSize.height + CGFloat(max(rowCount - 1, 0)) * Self.rowSpacing
        )
    }

    init(duration: Double, interval: ThumbnailInterval, cellSize: CGSize, width: CGFloat) {
        self.cellSize = cellSize
        self.duration = max(duration, 0)
        var cells: [Cell] = []
        if let step = interval.seconds, self.duration > 0 {
            let count = max(1, Int((self.duration / step - 1e-9).rounded(.up)))
            var x: CGFloat = 0, row = 0
            for index in 0..<count {
                let start = Double(index) * step
                let length = min(step, self.duration - start)
                let w = cellSize.width
                if x > 0, x + w > width + 0.5 {
                    x = 0
                    row += 1
                }
                let y = CGFloat(row) * (cellSize.height + Self.rowSpacing)
                cells.append(Cell(start: start, duration: length, row: row, frame: CGRect(x: x, y: y, width: w, height: cellSize.height)))
                x += w
            }
        } else {
            cells = [Cell(start: 0, duration: self.duration, row: 0, frame: CGRect(origin: .zero, size: cellSize))]
        }
        self.cells = cells
        rowCount = (cells.last?.row ?? 0) + 1
    }

    func cells(inRow row: Int) -> ArraySlice<Cell> {
        guard let first = cells.firstIndex(where: { $0.row == row }) else { return [] }
        let end = cells[first...].firstIndex(where: { $0.row != row }) ?? cells.endIndex
        return cells[first..<end]
    }

    /// The time in the clip at `point`, reading the strip row by row: before
    /// a row's first thumbnail is its start, past its last is its end. Points
    /// above the strip are its start, below it its end, so a drag that
    /// leaves the strip stays at an edge.
    func seconds(at point: CGPoint) -> Double {
        guard !cells.isEmpty else { return 0 }
        if point.y < 0 { return 0 }
        let row = Int(point.y / rowPitch)
        if row >= rowCount { return duration }
        let rowCells = cells(inRow: row)
        guard let first = rowCells.first, let last = rowCells.last else { return 0 }
        if point.x <= first.frame.minX { return first.start }
        if point.x >= last.frame.maxX { return last.end }
        let cell = rowCells.first { point.x < $0.frame.maxX } ?? last
        let fraction = Double((point.x - cell.frame.minX) / cell.frame.width)
        return (cell.start + fraction * cell.duration).clamped(between: 0, and: duration)
    }

    /// Where `seconds` falls: the x in its thumbnail's row, and that row.
    func position(atSeconds seconds: Double) -> (x: CGFloat, row: Int) {
        guard let cell = cells.last(where: { $0.start <= seconds }) ?? cells.first else { return (0, 0) }
        let fraction = cell.duration > 0 ? CGFloat(((seconds - cell.start) / cell.duration).clamped(between: 0, and: 1)) : 0
        return (cell.frame.minX + fraction * cell.frame.width, cell.row)
    }

    /// The stretch from `start` to `end` as one horizontal span per row it
    /// crosses, each the full height of its row.
    func spans(from start: Double, to end: Double) -> [CGRect] {
        let start = max(start, 0), end = min(end, duration)
        guard end > start else { return [] }
        var spans: [CGRect] = []
        for cell in cells where cell.end > start && cell.start < end {
            let a = cell.duration > 0 ? CGFloat((max(start, cell.start) - cell.start) / cell.duration) : 0
            let b = cell.duration > 0 ? CGFloat((min(end, cell.end) - cell.start) / cell.duration) : 1
            let rect = CGRect(
                x: cell.frame.minX + a * cell.frame.width, y: cell.frame.minY,
                width: (b - a) * cell.frame.width, height: cell.frame.height
            )
            if let last = spans.last, abs(last.minY - rect.minY) < 0.5, abs(last.maxX - rect.minX) < 0.5 {
                spans[spans.count - 1] = last.union(rect)
            } else {
                spans.append(rect)
            }
        }
        return spans
    }
}

extension FilmstripLayout {
    /// `spans` in order, joined where they overlap or touch, leaving out
    /// empty ones: what a strip underlines as used.
    static func joined(_ spans: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        var joined: [(start: Double, end: Double)] = []
        for (a, b) in spans.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = joined.last, a <= last.end + 1e-6 {
                joined[joined.count - 1].end = max(last.end, b)
            } else {
                joined.append((a, b))
            }
        }
        return joined
    }
}
