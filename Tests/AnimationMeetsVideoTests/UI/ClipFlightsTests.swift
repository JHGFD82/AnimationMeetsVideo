import CoreGraphics
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Where a clip dropped on another layer was let go, for its new block to
/// arrive from.
@MainActor
struct ClipFlightsTests {
    @Test func aClipArrivesFromWhereItWasLetGoOnce() {
        let flights = ClipFlights()
        let clip = UUID()
        #expect(flights.arrive(clip) == nil)
        flights.depart(clip, from: CGRect(x: 10, y: 20, width: 100, height: 40))
        #expect(flights.arrive(clip) == CGRect(x: 10, y: 20, width: 100, height: 40))
        #expect(flights.arrive(clip) == nil)
    }

    @Test func aFlightIsForItsOwnClip() {
        let flights = ClipFlights()
        flights.depart(UUID(), from: CGRect(x: 1, y: 2, width: 3, height: 4))
        #expect(flights.arrive(UUID()) == nil)
    }
}
