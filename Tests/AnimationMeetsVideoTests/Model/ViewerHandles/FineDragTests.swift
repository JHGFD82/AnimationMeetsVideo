import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The loupe's slowed pointer (`FineDrag`) and what a fine drag does to
/// the handles that round or catch.
@Suite struct FineDragTests {
    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
    }

    @Test func theDragGoesAtAQuarterOfThePointer() {
        let fine = FineDrag(at: CGPoint(x: 100, y: 100))
        #expect(close(fine.effective(CGPoint(x: 100, y: 100)), CGPoint(x: 100, y: 100)))
        #expect(close(fine.effective(CGPoint(x: 140, y: 80)), CGPoint(x: 110, y: 95)))
    }

    @Test func optionSlowsItFurtherWithoutAJump() {
        var fine = FineDrag(at: CGPoint(x: 0, y: 0))
        let before = fine.effective(CGPoint(x: 40, y: 0))
        fine.setFiner(true, pointer: CGPoint(x: 40, y: 0))
        // Where it was when Option went down, then a sixteenth from there.
        #expect(close(fine.effective(CGPoint(x: 40, y: 0)), before))
        #expect(close(fine.effective(CGPoint(x: 72, y: 0)), CGPoint(x: 12, y: 0)))
        fine.setFiner(false, pointer: CGPoint(x: 72, y: 0))
        #expect(close(fine.effective(CGPoint(x: 76, y: 0)), CGPoint(x: 13, y: 0)))
    }

    @Test func aFineAnchorDragGoesInTenthsAndDoesntCatch() {
        let frame = CGSize(width: 1920, height: 1080)
        let clip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 10, timescale: 1))
        let context = HandleContext(clip: clip, sourceTime: .zero, frameSize: frame, pictureRect: CGRect(origin: .zero, size: frame))
        var drag = HandleDrag(handle: .anchor, start: CGPoint(x: 960, y: 540))
        // Near the top right corner, which an ordinary drag catches on.
        drag.move(to: CGPoint(x: 1916.33, y: 3.27), about: nil, holdingWithin: 10)
        drag.fine = true
        let moved = TransformHandles().edit(drag, context)?.applied(to: clip)
        let anchor = moved?.anchorPoint.value
        #expect(anchor.map { abs($0.x - 956.3) < 1e-6 && abs($0.y + 536.7) < 1e-6 } == true)
    }
}
