import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A clip turned off (V) stays on its layer but plays as a gap.
@Suite struct DisabledClipTests {
    @Test func aClipTurnedOffIsLeftOutAndTheTimelineKeepsItsLength() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 40, frames: 48)
        let top = try await fixture.addClip(luma: 200, frames: 96)
        fixture.project.editClip(top.clipID, in: fixture.timelineID) { $0.enabled = false }

        let composed = try await fixture.build(forPreview: true)
        let gray = try await grayLevel(of: composed, at: CMTime(value: 12, timescale: 24))
        #expect(abs(gray - 40) <= 8)
        // The clip turned off was the longer one: its time is still there.
        #expect(composed.composition.duration >= CMTime(value: 95, timescale: 24))
    }

    @Test func turningOffSeveralTurnsThemAllOffUnlessAllAreOff() throws {
        var project = EditingProject.empty
        let media = MediaClip(name: "A.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: CMTime(value: 2, timescale: 1),
                              frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let t = project.rootTimelineID
        let first = project.importClip(media, intoTimeline: t)
        let second = project.importClip(media, intoTimeline: t)
        let a = try #require(first).clipID
        let b = try #require(second).clipID
        func enabled(_ id: UUID) -> Bool { project.clipAndLayer(id, in: t)?.clip.enabled ?? true }

        project.editClip(a, in: t) { $0.enabled = false }
        let toggled = project.toggleEnabled(ofClips: [a, b], in: t)
        #expect(toggled)
        #expect(!enabled(a) && !enabled(b))
        project.toggleEnabled(ofClips: [a, b], in: t)
        #expect(enabled(a) && enabled(b))
        let missing = project.toggleEnabled(ofClips: [UUID()], in: t)
        #expect(!missing)
    }
}
