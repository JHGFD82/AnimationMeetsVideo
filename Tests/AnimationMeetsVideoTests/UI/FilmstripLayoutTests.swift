import CoreGraphics
import Testing
@testable import AnimationMeetsVideo

@Suite struct FilmstripLayoutTests {
    private let cell = CGSize(width: 96, height: 54)

    @Test func allIsOneThumbnailWhateverTheLength() {
        let layout = FilmstripLayout(duration: 600, interval: .all, cellSize: cell, width: 300)
        #expect(layout.cells.count == 1)
        #expect(layout.cells[0].duration == 600)
        #expect(layout.size == cell)
    }

    @Test func eachThumbnailStandsForOneIntervalAndTheLastIsNarrowerInProportion() {
        let layout = FilmstripLayout(duration: 12.5, interval: .fiveSeconds, cellSize: cell, width: 1000)
        #expect(layout.cells.map(\.start) == [0, 5, 10])
        #expect(layout.cells.map(\.duration) == [5, 5, 2.5])
        #expect(layout.cells.map(\.frame.width) == [96, 96, 48])
        #expect(layout.rowCount == 1)
    }

    @Test func anExactMultipleHasNoSliverAtTheEnd() {
        let layout = FilmstripLayout(duration: 10, interval: .fiveSeconds, cellSize: cell, width: 1000)
        #expect(layout.cells.count == 2)
    }

    @Test func aStripWiderThanTheBrowserWrapsOntoMoreRows() {
        // Three thumbnails fit in 300 points.
        let layout = FilmstripLayout(duration: 8, interval: .oneSecond, cellSize: cell, width: 300)
        #expect(layout.rowCount == 3)
        #expect(layout.cells(inRow: 0).count == 3)
        #expect(layout.cells(inRow: 2).count == 2)
        #expect(layout.cells[3].frame.origin == CGPoint(x: 0, y: 54 + FilmstripLayout.rowSpacing))
        #expect(layout.size.height == 3 * 54 + 2 * FilmstripLayout.rowSpacing)
    }

    @Test func aNarrowBrowserStillShowsOneThumbnailPerRow() {
        let layout = FilmstripLayout(duration: 3, interval: .oneSecond, cellSize: cell, width: 40)
        #expect(layout.rowCount == 3)
    }

    @Test func pointsReadAsTimeRowByRow() {
        let layout = FilmstripLayout(duration: 8, interval: .oneSecond, cellSize: cell, width: 300)
        #expect(layout.seconds(at: CGPoint(x: 48, y: 10)) == 0.5)
        // Second row, half way into its second thumbnail: 4.5 s.
        #expect(layout.seconds(at: CGPoint(x: 144, y: 60)) == 4.5)
        // Past the end of the last row's thumbnails.
        #expect(layout.seconds(at: CGPoint(x: 290, y: 120)) == 8)
        // Above and below the strip.
        #expect(layout.seconds(at: CGPoint(x: 100, y: -5)) == 0)
        #expect(layout.seconds(at: CGPoint(x: 0, y: 500)) == 8)
    }

    @Test func positionsAndPointsAgree() {
        let layout = FilmstripLayout(duration: 8, interval: .oneSecond, cellSize: cell, width: 300)
        let position = layout.position(atSeconds: 4.25)
        #expect(position.row == 1)
        #expect(layout.seconds(at: CGPoint(x: position.x, y: CGFloat(position.row) * layout.rowPitch + 5)) == 4.25)
    }

    @Test func aStretchIsOneSpanPerRowItCrosses() {
        let layout = FilmstripLayout(duration: 8, interval: .oneSecond, cellSize: cell, width: 300)
        let spans = layout.spans(from: 1.5, to: 4.5)
        #expect(spans.count == 2)
        #expect(spans[0] == CGRect(x: 144, y: 0, width: 144, height: 54))
        #expect(spans[1] == CGRect(x: 0, y: layout.rowPitch, width: 144, height: 54))
        #expect(layout.spans(from: 3, to: 3).isEmpty)
    }
}
