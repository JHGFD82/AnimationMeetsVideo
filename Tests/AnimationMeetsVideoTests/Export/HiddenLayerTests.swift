import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct HiddenLayerTests {
    /// The clips the first stretch's instruction draws.
    private func drawn(_ composed: ComposedTimeline) throws -> [DrawClip] {
        try #require(composed.videoComposition?.instructions.first as? LayeredInstruction).clips
    }

    @Test func anOpaquePictureFillingTheFrameHidesTheLayerUnderIt() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 40)
        let top = try await fixture.addClip(luma: 200)

        let exported = try await fixture.build()
        #expect(exported.segments.allSatisfy { !$0.needsRender })
        let instruction = try #require(exported.videoComposition?.instructions.first as? LayeredInstruction)
        #expect(instruction.passthroughTrackID != kCMPersistentTrackID_Invalid)
        #expect(instruction.requiredSourceTrackIDs?.count == 1)

        let viewer = try await fixture.build(forPreview: true)
        let clips = try drawn(viewer)
        #expect(clips.count == 1)
        #expect(clips.first?.owner == top.clipID)
        let gray = try await grayLevel(of: viewer, at: .zero)
        #expect(abs(gray - 200) <= 8)
    }

    @Test func aTopPictureWithOpacityLetsTheLayerUnderItShow() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 40)
        let top = try await fixture.addClip(luma: 200)
        fixture.project.setOpacity(50, ofClip: top.clipID, in: fixture.timelineID)

        let composed = try await fixture.build()
        let rendered = composed.segments.filter(\.needsRender)
        #expect(!rendered.isEmpty)
        let clips = try drawn(composed)
        #expect(clips.count == 2)
    }

    @Test func aMovedPictureHidesNothing() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 40)
        let top = try await fixture.addClip(luma: 200)
        fixture.setTransform([(.position, [8, 0])], ofClip: top.clipID)

        let clips = try drawn(await fixture.build())
        #expect(clips.count == 2)
    }

    @Test func aLetterboxedPictureHidesOneLetterboxedTheSameWay() async throws {
        // The 16:9 movies fit a square frame with bars above and below.
        var fixture = try DrawingFixture(frame: CGSize(width: 128, height: 128))
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 40)
        try await fixture.addClip(luma: 200)

        let composed = try await fixture.build()
        let clips = try drawn(composed)
        #expect(clips.count == 1)
        #expect(composed.segments.allSatisfy { !$0.needsRender })
    }

    /// A plain picture of footage `size` big placed by `base`, opaque
    /// unless said otherwise.
    private func picture(_ size: CGSize, _ base: CGAffineTransform, opaque: Bool = true) -> DrawClip {
        DrawClip(
            content: .media(MediaDraw(
                trackID: 1, base: base, url: URL(fileURLWithPath: "/dev/null"), sourceStart: .zero, segmentStart: .zero,
                opaqueSize: opaque ? size : nil
            )),
            stack: .none, range: CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)), owner: UUID()
        )
    }

    private func kept(_ clips: [DrawClip]) -> Int {
        clips.withoutHidden(
            in: CGSize(width: 1920, height: 1080), over: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)),
            frame: CMTime(value: 1, timescale: 24)
        ).count
    }

    @Test func aPictureHidesOnlyWhatLiesWithinItsSolidPixels() {
        let wide = CGSize(width: 1920, height: 1038)
        let bars = CGAffineTransform(translationX: 0, y: 21)
        let same = kept([picture(wide, bars), picture(wide, bars)])
        #expect(same == 1)
        // Taller than the picture over it, it shows above and below.
        let taller = kept([picture(wide, bars), picture(CGSize(width: 1920, height: 1080), .identity)])
        #expect(taller == 2)
        // Half a pixel off, the top's edge rows are only partly covered.
        let halfway = kept([picture(wide, CGAffineTransform(translationX: 0, y: 20.5)), picture(wide, CGAffineTransform(translationX: 0, y: 20.5))])
        #expect(halfway == 2)
        let transparent = kept([picture(wide, bars, opaque: false), picture(wide, bars)])
        #expect(transparent == 2)
        let enlarged = kept([picture(CGSize(width: 960, height: 519), CGAffineTransform(scaleX: 2, y: 2).translatedBy(x: 0, y: 10.5)), picture(wide, bars)])
        #expect(enlarged == 2)
        // Off the frame entirely, a picture draws nothing to keep.
        let offFrame = kept([picture(wide, bars), picture(wide, CGAffineTransform(translationX: 4000, y: 0))])
        #expect(offFrame == 1)
    }

    @Test func anEnlargedPictureHidesNothingButAShrunkOneDoes() async throws {
        // Enlarged, its edge pixels are mixed with transparency.
        var large = try DrawingFixture(frame: CGSize(width: 256, height: 144))
        defer { large.cleanUp() }
        try await large.addClip(luma: 40)
        try await large.addClip(luma: 200)
        let enlarged = try drawn(await large.build())
        #expect(enlarged.count == 2)

        var small = try DrawingFixture(frame: CGSize(width: 64, height: 36))
        defer { small.cleanUp() }
        try await small.addClip(luma: 40)
        try await small.addClip(luma: 200)
        let composed = try await small.build()
        let shrunk = try drawn(composed)
        #expect(shrunk.count == 1)
        #expect(composed.segments.allSatisfy { !$0.needsRender })
    }

    @Test func onlyFootageThatCantBeTransparentCountsAsOpaque() throws {
        func format(_ codec: CMVideoCodecType, depth: Int? = nil) throws -> CMFormatDescription {
            let extensions = depth.map { [kCMFormatDescriptionExtension_Depth: $0] as CFDictionary }
            var format: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: nil, codecType: codec, width: 128, height: 72, extensions: extensions, formatDescriptionOut: &format
            )
            #expect(status == noErr)
            return try #require(format)
        }
        let opaque = [
            try format(kCMVideoCodecType_H264),
            try format(kCMVideoCodecType_AppleProRes422),
            try format(kCMVideoCodecType_AppleProRes4444, depth: 24),
        ]
        let transparent = [
            try format(kCMVideoCodecType_AppleProRes4444, depth: 32),
            try format(kCMVideoCodecType_AppleProRes4444),
            try format(kCMVideoCodecType_HEVCWithAlpha),
        ]
        #expect(opaque.map(MediaTrackCache.isOpaque) == [true, true, true])
        #expect(transparent.map(MediaTrackCache.isOpaque) == [false, false, false])
    }
}
