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

@Test func oneLayerCanBeSizedApartAndKeepsItsProportionWhenItsAreaZooms() {
    var layout = TimelineAreaLayout()
    layout.setLayerHeight(.video, 50)
    let a = UUID(), b = UUID()
    layout.setHeight(100, of: a, kind: .video)
    #expect(layout.height(of: a, kind: .video) == 100)
    #expect(layout.height(of: b, kind: .video) == 50)

    layout.setLayerHeight(.video, 60)
    #expect(abs(layout.height(of: a, kind: .video) - 120) < 1e-9)
}

@Test func sizingEveryLayerOfAnAreaDropsTheirOwnSizes() {
    var layout = TimelineAreaLayout()
    let a = UUID(), b = UUID(), other = UUID()
    layout.setHeight(150, of: a, kind: .video)
    layout.setHeight(30, of: other, kind: .sound)
    layout.setHeightOfAll(80, kind: .video, layers: [a, b])
    #expect(layout.height(of: a, kind: .video) == 80)
    #expect(layout.height(of: b, kind: .video) == 80)
    // Another area's layer keeps its own size.
    #expect(abs(layout.height(of: other, kind: .sound) - 30) < 1e-9)
}

@Test func sizingEveryShownLayerMakesThemAllAlike() {
    var layout = TimelineAreaLayout()
    layout.setShown(.music, false)
    layout.setLayerHeight(.music, 30)
    let a = UUID(), b = UUID()
    layout.setHeight(150, of: a, kind: .video)
    layout.setHeightOfAllShown(70, layers: [a, b])
    #expect(layout.height(of: a, kind: .video) == 70)
    #expect(layout.height(of: b, kind: .sound) == 70)
    // A hidden area is left as it was.
    #expect(layout.layerHeight(.music) == 30)
}

@Test func layerSizesAreKeptWithinTheRangeAndSurviveDefaults() throws {
    var layout = TimelineAreaLayout()
    let a = UUID()
    layout.setHeight(1000, of: a, kind: .video)
    #expect(layout.height(of: a, kind: .video) == TimelineAreaLayout.layerHeightRange.upperBound)

    let restored = try #require(TimelineAreaLayout(rawValue: layout.rawValue))
    #expect(restored.layerScales == layout.layerScales)
    // Layouts saved before layers had sizes of their own still load.
    let old = #"{"hidden":[],"layerHeights":["video",56,"sound",44,"music",44],"shares":["video",0.5,"sound",0.25,"music",0.25],"showsSections":true}"#
    #expect(TimelineAreaLayout(rawValue: old)?.layerScales.isEmpty == true)
}
