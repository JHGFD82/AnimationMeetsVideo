import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The loop bar drawn, moved, resized and clicked with real events (see
/// `EventHarness`; run with `UI_EVENTS=1`). The bar maps 40 points to a
/// second, over a 24 fps timeline twelve seconds long.
@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled), .eventsOneAtATime)
struct LoopBarInteractionTests {
    private static let size = CGSize(width: 480, height: LoopBar.height)
    private static let pointsPerSecond: CGFloat = 40
    /// Across the middle of the bar.
    private static let y = LoopBar.height / 2

    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    /// What the bar asked for.
    @MainActor
    private final class Calls {
        var drawn: [LoopRegion] = []
        var adjusted: [LoopRegion] = []
        var toggles = 0
    }

    private struct Host: View {
        let region: LoopRegion?
        let calls: Calls
        /// The one snap target, caught within a fifth of a second.
        var snapTarget: CMTime?

        var body: some View {
            LoopBar(
                region: region, timeline: EditingProject.empty.timelines[0],
                limits: CMTimeRange(start: .zero, end: CMTime(value: 12, timescale: 1)),
                x: { CGFloat($0.seconds) * LoopBarInteractionTests.pointsPerSecond },
                time: { CMTime(seconds: Double($0 / LoopBarInteractionTests.pointsPerSecond), preferredTimescale: 600) },
                snap: { time in
                    snapTarget.flatMap { abs(CMTimeSubtract($0, time).seconds) < 0.2 ? $0 : nil }
                },
                onSnapIndicator: { _ in },
                onDraw: { calls.drawn.append($0) },
                onAdjust: { calls.adjusted.append($0) },
                onRemove: {},
                onToggle: { calls.toggles += 1 }
            )
        }
    }

    private func drag(_ harness: EventHarness, from: CGFloat, to: CGFloat) async throws {
        try await harness.press(at: CGPoint(x: from, y: Self.y), dragTo: CGPoint(x: to, y: Self.y))
        harness.mouse(.leftMouseUp, at: CGPoint(x: to, y: Self.y))
        try await harness.settle(250)
    }

    @Test func aDragAcrossEmptyBarDrawsARegion() async throws {
        let calls = Calls()
        let harness = EventHarness(Host(region: nil, calls: calls), size: Self.size)
        try await harness.settle()
        // Right to left works too: 6 s back to 2 s.
        try await drag(harness, from: 240, to: 80)
        #expect(calls.drawn == [LoopRegion(start: seconds(2), end: seconds(6))])
        #expect(calls.toggles == 0)
    }

    @Test func aClickTogglesAndADragMovesWithoutToggling() async throws {
        let calls = Calls()
        let region = LoopRegion(start: seconds(2), end: seconds(6))
        let harness = EventHarness(Host(region: region, calls: calls), size: Self.size)
        try await harness.settle()

        try await harness.click(at: CGPoint(x: 160, y: Self.y))
        #expect(calls.toggles == 1)
        // On an edge, a click toggles too.
        try await harness.click(at: CGPoint(x: 240, y: Self.y))
        #expect(calls.toggles == 2)

        // The middle dragged a second later moves it, its length kept.
        try await drag(harness, from: 160, to: 200)
        #expect(calls.adjusted == [LoopRegion(start: seconds(3), end: seconds(7))])
        #expect(calls.toggles == 2)
        #expect(calls.drawn.isEmpty)
    }

    @Test func anEdgeDragResizesAndSnaps() async throws {
        let calls = Calls()
        let region = LoopRegion(start: seconds(2), end: seconds(6))
        let harness = EventHarness(Host(region: region, calls: calls, snapTarget: seconds(9)), size: Self.size)
        try await harness.settle()
        // To 8.875 s, an eighth short of the target at 9.
        try await drag(harness, from: 240, to: 355)
        #expect(calls.adjusted == [LoopRegion(start: seconds(2), end: seconds(9))])
        #expect(calls.toggles == 0)
    }

    @Test func escapeCancelsADraw() async throws {
        let calls = Calls()
        let harness = EventHarness(Host(region: nil, calls: calls), size: Self.size)
        try await harness.settle()
        try await harness.press(at: CGPoint(x: 80, y: Self.y), dragTo: CGPoint(x: 240, y: Self.y))
        harness.escape()
        try await harness.settle()
        harness.mouse(.leftMouseUp, at: CGPoint(x: 240, y: Self.y))
        try await harness.settle(250)
        #expect(calls.drawn.isEmpty)
        #expect(calls.toggles == 0)
    }
}
