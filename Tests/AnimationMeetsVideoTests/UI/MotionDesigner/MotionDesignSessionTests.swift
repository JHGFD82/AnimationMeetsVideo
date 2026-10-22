import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite(.serialized) struct MotionDesignSessionTests {
    /// Waits for `condition`, up to `seconds`.
    private func wait(_ seconds: Double = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// The mean of a picture's middle pixel's channels, 0 to 1.
    private static func brightness(of image: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }

    @Test func thePlayerPlaysTheDraftAndFollowsEdits() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-motion-session-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, segments: [(60, 96), (200, 96)])
        let footage = MediaClip(
            name: "Shot", kind: .video, url: url, duration: CMTime(value: 8, timescale: 1),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        var project = EditingProject.empty
        project.addMedia(footage)
        let clip = TimelineClip(source: .media(footage.id), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        let run = try MotionRun.opening([clip.id], in: project.rootTimelineID, of: project).get()
        let session = MotionDesignSession(run: run, project: project)
        defer { session.end() }

        // The first build replaces the music-only start with the draft.
        try await wait { session.showsDraft && !session.isUpdatingPreview }
        #expect(session.showsDraft)
        #expect(session.previewError == nil)
        let first = try #require(session.player.currentItem)
        #expect(abs(first.asset.duration.seconds - 4) < 0.05)

        // Paused frames are drawn from the draft: 1 s in is the dark
        // footage, 5 s in (once trimmed out) the bright.
        let dark = try #require(await session.draftFrame(at: 1))
        #expect(Self.brightness(of: dark) < 0.4)
        #expect(session.lastDraftFrame != nil)

        // An edit rebuilds it: the end trimmed out to 6 s.
        session.perform("Trim Clip") { $0.trim(clip.id, edge: .end, to: CMTime(value: 6, timescale: 1)) }
        #expect(session.isUpdatingPreview)
        try await wait { session.player.currentItem !== first && !session.isUpdatingPreview }
        let rebuilt = try #require(session.player.currentItem)
        #expect(rebuilt !== first)
        #expect(abs(rebuilt.asset.duration.seconds - 6) < 0.05)
        #expect(rebuilt.videoComposition != nil)

        let bright = try #require(await session.draftFrame(at: 5))
        #expect(Self.brightness(of: bright) > 0.6)

        // What it plays is what Done would write.
        let draft = session.draftProject
        #expect(abs((draft.timeline(id: draft.rootTimelineID)?.duration.seconds ?? 0) - 6) < 0.05)
    }
}
