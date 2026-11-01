import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The video composition's instructions meet end to start whatever
/// timescales the clips' edges come in (`instructionTimescale`).
@Suite struct InstructionTilingTests {
    /// A retimed clip's edge in nanoseconds beside a frame edge in 24ths:
    /// their common timescale overflows CoreMedia's 32 bits, and the stretch
    /// between them was rounded past or short of the next one. AVFoundation
    /// then turned the whole composition down: renders failed and the
    /// player never drew.
    @Test(arguments: [true, false])
    func edgesInTimescalesWithoutACommonOneStillMeet(forPreview: Bool) async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 40, frames: 96)
        try await fixture.addClip(luma: 120, frames: 95)
        let top = try await fixture.addClip(luma: 200, frames: 48)
        fixture.project.editClip(top.clipID, in: fixture.timelineID) {
            $0.trimEnd = CMTime(value: 1_145_288_549, timescale: 1_000_000_000)
        }

        let composed = try await fixture.build(forPreview: forPreview)
        let videoComposition = try #require(composed.videoComposition)
        let ranges = videoComposition.instructions.map(\.timeRange)
        #expect(ranges.first?.start == .zero)
        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            #expect(CMTimeCompare(earlier.end, later.start) == 0, "\(earlier.end.value)/\(earlier.end.timescale) vs \(later.start.value)/\(later.start.timescale)")
        }
        let whole = CMTimeRange(start: .zero, duration: composed.composition.duration)
        #expect(try await videoComposition.isValid(for: composed.composition, timeRange: whole, validationDelegate: nil))
    }
}
