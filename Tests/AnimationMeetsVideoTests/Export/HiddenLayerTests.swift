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

    @Test func aLetterboxedPictureHidesNothing() async throws {
        // The 16:9 movies fit a square frame with bars above and below.
        var fixture = try DrawingFixture(frame: CGSize(width: 128, height: 128))
        defer { fixture.cleanUp() }
        try await fixture.addClip(luma: 40)
        try await fixture.addClip(luma: 200)

        let clips = try drawn(await fixture.build())
        #expect(clips.count == 2)
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
