import Foundation
import Testing
@testable import AnimationMeetsVideo

@Test func beatMarkerChoicesSurviveTheTripThroughDefaults() throws {
    let first = UUID(), second = UUID(), song = UUID()
    var choices = BeatMarkerChoices()
    choices.choose(song, for: first)

    let restored = try #require(BeatMarkerChoices(rawValue: choices.rawValue))
    #expect(restored.layer(for: first) == song)
    #expect(restored.layer(for: second) == nil)
}

@Test func choosingNoneTurnsATimelinesMarkersOff() {
    let timeline = UUID()
    var choices = BeatMarkerChoices()
    choices.choose(UUID(), for: timeline)
    choices.choose(nil, for: timeline)
    #expect(choices.layer(for: timeline) == nil)
    #expect(BeatMarkerChoices(rawValue: choices.rawValue) == BeatMarkerChoices())
}

@Test func beatMarkerChoicesIgnoreUnreadableDefaults() {
    #expect(BeatMarkerChoices(rawValue: "not json") == nil)
}
