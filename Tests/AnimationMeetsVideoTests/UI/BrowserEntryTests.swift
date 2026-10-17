import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct BrowserEntryTests {
    private func s(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private func scene(from start: Double, to end: Double) -> BrowserEntry {
        let clip = MediaClip(name: "A", kind: .video, url: nil, duration: s(60), frameRate: 24, colorSpace: .rec709, codecName: "T")
        return BrowserEntry(id: .scene(asset: clip.id, scene: "x"), clip: clip, start: s(start), duration: s(end - start))
    }

    @Test func usedRangesAreCutToTheSceneAndMeasuredFromItsStart() {
        let entry = scene(from: 10, to: 20)
        let used = entry.seconds(within: [CMTimeRange(start: s(5), end: s(12)), CMTimeRange(start: s(18), end: s(30))])
        #expect(used.map(\.start) == [0, 8])
        #expect(used.map(\.end) == [2, 10])
    }

    @Test func overlappingAndTouchingUsesAreOneStretch() {
        let entry = scene(from: 0, to: 20)
        let used = entry.seconds(within: [
            CMTimeRange(start: s(6), end: s(9)), CMTimeRange(start: s(2), end: s(5)),
            CMTimeRange(start: s(4), end: s(6)), CMTimeRange(start: s(15), end: s(16)),
        ])
        #expect(used.map(\.start) == [2, 15])
        #expect(used.map(\.end) == [9, 16])
    }

    @Test func usesOutsideTheSceneAreLeftOut() {
        let entry = scene(from: 10, to: 20)
        #expect(entry.seconds(within: [CMTimeRange(start: s(0), end: s(10)), CMTimeRange(start: s(20), end: s(25))]).isEmpty)
    }

    @Test func aRangeBecomesAPieceOfTheAssetInOriginalTime() {
        let entry = scene(from: 10, to: 20)
        let piece = entry.piece(from: 2, to: 5)
        #expect(piece.start.seconds == 12)
        #expect(piece.end.seconds == 15)
        #expect(entry.piece().end.seconds == 20)
    }
}
