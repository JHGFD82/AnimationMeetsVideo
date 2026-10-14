import Foundation
import Testing
@testable import AnimationMeetsVideo

@Test func areaLayoutSurvivesTheTripThroughDefaults() throws {
    var layout = TimelineAreaLayout()
    layout.setShown(.music, false)
    layout.setLayerHeight(.sound, 96)
    layout.moveBoundary(above: .sound, by: 40, from: layout.heights(splitting: 400), available: 400)

    let restored = try #require(TimelineAreaLayout(rawValue: layout.rawValue))
    #expect(restored.hidden == layout.hidden)
    #expect(restored.layerHeights == layout.layerHeights)
    for kind in TimelineAreaLayout.order {
        #expect(abs((restored.shares[kind] ?? 0) - (layout.shares[kind] ?? 0)) < 1e-9)
    }
}

@Test func areaLayoutIgnoresUnreadableDefaults() {
    #expect(TimelineAreaLayout(rawValue: "not json") == nil)
}
