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

@Test func layerHeightSliderZoomsShownAreasByTheSameRatio() {
    var layout = TimelineAreaLayout()
    layout.setShown(.music, false)
    layout.setLayerHeight(.video, 48)
    layout.setLayerHeight(.sound, 24)
    layout.setLayerHeight(.music, 100)

    let start = layout.shownLayerHeightFraction
    layout.setShownLayerHeightFraction(start + 0.1)

    #expect(abs(layout.shownLayerHeightFraction - (start + 0.1)) < 1e-9)
    // Each moved by the same ratio, so they keep theirs.
    #expect(abs(layout.layerHeight(.video) / layout.layerHeight(.sound) - 2) < 1e-6)
    // A hidden area keeps its height.
    #expect(layout.layerHeight(.music) == 100)
}

@Test func layerHeightSliderStopsAtTheEndsOfTheRange() {
    var layout = TimelineAreaLayout()
    layout.setShownLayerHeightFraction(1)
    for kind in TimelineAreaLayout.order {
        #expect(abs(layout.layerHeight(kind) - TimelineAreaLayout.layerHeightRange.upperBound) < 1e-6)
    }
    layout.setShownLayerHeightFraction(0)
    for kind in TimelineAreaLayout.order {
        #expect(abs(layout.layerHeight(kind) - TimelineAreaLayout.layerHeightRange.lowerBound) < 1e-6)
    }
}
