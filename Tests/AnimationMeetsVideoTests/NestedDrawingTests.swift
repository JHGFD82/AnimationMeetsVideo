import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Nested timelines are closed groups: drawn on their own, as one picture,
/// unless they pass through.
@Suite struct NestedDrawingTests {
    /// A root with a luma-100 clip at the bottom and, over it, a nested
    /// timeline whose two layers are luma 200 over luma 50, with Opacity
    /// 50% on the nested clip.
    private func fixture(passThrough: Bool) async throws -> (DrawingFixture, UUID) {
        var fixture = try DrawingFixture()
        _ = try await fixture.addClip(luma: 100)

        let nestedID = fixture.project.addTimeline(
            name: "Inner", frameSize: fixture.project.timelines[0].frameSize, frameRate: 24, colorSpace: .rec709
        )
        _ = try await fixture.addClip(luma: 50, to: nestedID)
        _ = try await fixture.addClip(luma: 200, to: nestedID)
        let embedded = fixture.project.embedTimeline(nestedID, intoTimeline: fixture.timelineID)
        let placed = try #require(embedded)
        fixture.setTransform([(.opacity, [50])], ofClip: placed.clipID)
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.passThrough = passThrough }
        return (fixture, placed.clipID)
    }

    @Test func aNestedTimelineIsOnePictureThatFadesAsAWhole() async throws {
        var (closed, _) = try await fixture(passThrough: false)
        defer { closed.cleanUp() }
        var (through, _) = try await fixture(passThrough: true)
        defer { through.cleanUp() }
        let whole = try await grayLevel(of: closed.build(), at: .zero)
        let layerByLayer = try await grayLevel(of: through.build(), at: .zero)
        // As one picture the bright layer hides the dark one before the
        // group fades: half bright over the clip underneath. Layer by layer
        // the dark one fades over it first, so the bright one lands on
        // something darker.
        #expect(whole > layerByLayer + 4)
    }

    @Test func nothingInsideSeesWhatIsUnderIt() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.addClip(luma: 220)
        let nestedID = fixture.project.addTimeline(
            name: "Inner", frameSize: fixture.project.timelines[0].frameSize, frameRate: 24, colorSpace: .rec709
        )
        let inner = try await fixture.addClip(luma: 100, to: nestedID)
        // Inside the group, a quarter-size clip leaves the rest transparent.
        fixture.setTransform([(.scale, [50, 50])], ofClip: inner.clipID, in: nestedID)
        _ = fixture.project.embedTimeline(nestedID, intoTimeline: fixture.timelineID)

        let composed = try await fixture.build()
        let underneath = try await grayLevel(of: composed, at: .zero, x: 0.05, y: 0.05)
        let inside = try await grayLevel(of: composed, at: .zero)
        // The corner shows the clip below through the group's transparency;
        // the middle shows the nested clip.
        #expect(underneath > inside + 20)
    }

    @Test func aNestedTimelineMovesAsOnePicture() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let nestedID = fixture.project.addTimeline(
            name: "Inner", frameSize: fixture.project.timelines[0].frameSize, frameRate: 24, colorSpace: .rec709
        )
        _ = try await fixture.addClip(luma: 200, to: nestedID)
        let embedded = fixture.project.embedTimeline(nestedID, intoTimeline: fixture.timelineID)
        let placed = try #require(embedded)
        let plain = try await grayLevel(of: fixture.build(), at: .zero)
        fixture.setTransform([(.position, [64, 0])], ofClip: placed.clipID)
        let composed = try await fixture.build()
        #expect(try await grayLevel(of: composed, at: .zero, x: 0.25) <= 2)
        #expect(abs(try await grayLevel(of: composed, at: .zero, x: 0.75) - plain) <= 4)
    }

    @Test func passingThroughChangesTheRenderKey() async throws {
        var (closed, closedID) = try await fixture(passThrough: false)
        defer { closed.cleanUp() }
        let before = try await closed.build().segments.first(where: \.needsRender)?.key
        closed.project.editClip(closedID, in: closed.timelineID) { $0.passThrough = true }
        let after = try await closed.build().segments.first(where: \.needsRender)?.key
        #expect(before != nil && after != nil && before != after)
    }
}
