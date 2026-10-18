import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnimationMeetsVideo

/// Writes a picture `width` by `height` whose pixels `color` gives (gray,
/// alpha, from the top left), as `type`, with an EXIF orientation when
/// one is given.
func writeStill(
    to url: URL, width: Int = 64, height: Int = 36, type: UTType = .png, orientation: Int? = nil,
    color: (Int, Int) -> (gray: UInt8, alpha: UInt8)
) throws {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (gray, alpha) = color(x, y)
            // Premultiplied, as the context takes it.
            let value = UInt8(Int(gray) * Int(alpha) / 255)
            let offset = (y * width + x) * 4
            pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value; pixels[offset + 3] = alpha
        }
    }
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

extension DrawingFixture {
    /// Puts a still on a new layer at the top of the root timeline, for
    /// `seconds`.
    @discardableResult
    mutating func addStill(
        named name: String = "still-\(UUID().uuidString).png", seconds: Double = 2, type: UTType = .png, orientation: Int? = nil,
        color: (Int, Int) -> (gray: UInt8, alpha: UInt8)
    ) async throws -> (layerID: UUID, clipID: UUID, url: URL) {
        let url = directory.appending(path: name)
        try writeStill(to: url, type: type, orientation: orientation, color: color)
        let media = try MediaImporter.importStill(at: url)
        let imported = project.importClip(media, intoTimeline: timelineID)
        let placed = try #require(imported)
        project.editClip(placed.clipID, in: timelineID) { $0.trimEnd = CMTime(seconds: seconds, preferredTimescale: 600) }
        return (placed.layerID, placed.clipID, url)
    }
}

@Suite struct StillTests {
    @Test func importingAPictureMakesAStill() async throws {
        let fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let url = fixture.directory.appending(path: "logo.png")
        try writeStill(to: url) { _, _ in (200, 255) }

        #expect(MediaImporter.isImage(url))
        let still = try await MediaImporter.importClip(at: url)
        #expect(still.kind == .image)
        #expect(still.duration == MediaClip.stillLength)
        #expect(still.codecName == "PNG")
        #expect(still.colorSpace == .rec709)
        #expect(!still.hasAudio)
    }

    @Test func aStillAloneIsDrawnOverBlack() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        // Bright on the left, transparent on the right.
        try await fixture.addStill { x, _ in x < 32 ? (220, 255) : (0, 0) }

        let composed = try await fixture.build()
        #expect(composed.hasPictures)
        #expect(composed.composition.duration >= CMTime(seconds: 2, preferredTimescale: 600))
        let left = try await grayLevel(of: composed, at: CMTime(seconds: 1, preferredTimescale: 600), x: 0.25)
        let right = try await grayLevel(of: composed, at: CMTime(seconds: 1, preferredTimescale: 600), x: 0.75)
        #expect(left > 190)
        #expect(right < 10)
    }

    @Test func aStillsTransparencyShowsTheFootageBelow() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.addClip(luma: 100)
        try await fixture.addStill(seconds: 1) { x, _ in x < 32 ? (230, 255) : (0, 0) }

        let composed = try await fixture.build()
        let left = try await grayLevel(of: composed, at: .zero, x: 0.25)
        let right = try await grayLevel(of: composed, at: .zero, x: 0.75)
        // The footage on its own, once the still has ended.
        let bare = try await grayLevel(of: composed, at: CMTime(seconds: 1.5, preferredTimescale: 600), x: 0.75)
        #expect(left > 200)
        #expect(abs(right - bare) < 4)
    }

    @Test func aStillIsUprightAsItsOrientationSays() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        // Stored wide, bright on the left; orientation 6 turns it a quarter
        // clockwise to show, so the bright half is on top.
        let placed = try await fixture.addStill(type: .jpeg, orientation: 6) { x, _ in x < 32 ? (230, 255) : (20, 255) }
        #expect(MediaImporter.stillSize(at: placed.url) == CGSize(width: 36, height: 64))

        let composed = try await fixture.build()
        let top = try await grayLevel(of: composed, at: .zero, x: 0.5, y: 0.2)
        let bottom = try await grayLevel(of: composed, at: .zero, x: 0.5, y: 0.8)
        #expect(top > bottom + 100)
        // Upright, it is taller than it is wide, so it doesn't reach the
        // sides of a wide frame.
        let side = try await grayLevel(of: composed, at: .zero, x: 0.1, y: 0.2)
        #expect(side < 10)
    }

    @Test func movingAStillKeepsItsRender() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await fixture.addStill { _, _ in (180, 255) }
        // Graded, so its stretch is rendered.
        var exposure = EffectControl(kind: .exposure)
        exposure.number = AnimatedValue(ComponentValue(values: [1]))
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.effects = [Effect(kind: .color, controls: [exposure])] }

        let before = try await fixture.build().segments.filter(\.needsRender)
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.startOffset = CMTime(seconds: 1, preferredTimescale: 24) }
        let after = try await fixture.build().segments.filter(\.needsRender)
        #expect(!before.isEmpty)
        #expect(before.map(\.key) == after.map(\.key))
    }

    @Test func aStillCanBeTrimmedPastItsPlacedLength() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await fixture.addStill(seconds: 30) { _, _ in (180, 255) }
        let clip = try #require(fixture.project.timelines[0].layers.flatMap(\.clips).first { $0.id == placed.clipID })
        #expect(fixture.project.sourceDuration(for: clip.source) ?? .zero > CMTime(seconds: 30, preferredTimescale: 600))

        let composed = try await fixture.build()
        let late = try await grayLevel(of: composed, at: CMTime(seconds: 25, preferredTimescale: 600))
        #expect(late > 150)
    }

    /// Footage then a still on one layer, cut at one second, with a cross
    /// dissolve at the cut: footage (luma `footage`, two seconds of file, so
    /// one spare) or the still (`still`) first.
    private func dissolve(stillFirst: Bool, footage: UInt8, still: UInt8) async throws -> (DrawingFixture, ComposedTimeline) {
        var fixture = try DrawingFixture()
        let second = CMTime(seconds: 1, preferredTimescale: 600)
        let movie = try await fixture.addClip(luma: footage, frames: 48)
        let url = fixture.directory.appending(path: "still.png")
        try writeStill(to: url) { _, _ in (still, 255) }
        let picture = try MediaImporter.importStill(at: url)
        fixture.project.addMedia(picture)
        fixture.project.trimClipEnd(movie.clipID, in: fixture.timelineID, layer: movie.layerID, to: second)
        let stillClip = TimelineClip(source: .media(picture.id), startOffset: stillFirst ? .zero : second, trimStart: .zero, trimEnd: second)
        let index = try #require(fixture.project.timelines.firstIndex { $0.id == fixture.timelineID })
        let layer = try #require(fixture.project.timelines[index].layers.firstIndex { $0.id == movie.layerID })
        fixture.project.timelines[index].layers[layer].clips.append(stillClip)
        if stillFirst {
            fixture.project.editClip(movie.clipID, in: fixture.timelineID) { $0.startOffset = second }
        }
        let incoming = stillFirst ? movie.clipID : stillClip.id
        fixture.project.setTransition(.crossDissolve, at: .leading, of: incoming, in: fixture.timelineID, layer: movie.layerID)
        return (fixture, try await fixture.build())
    }

    @Test func aStillDissolvesWithTheFootageBeforeIt() async throws {
        let (fixture, composed) = try await dissolve(stillFirst: false, footage: 40, still: 220)
        defer { fixture.cleanUp() }
        let footageAlone = try await grayLevel(of: composed, at: CMTime(seconds: 0.25, preferredTimescale: 600))
        let stillAlone = try await grayLevel(of: composed, at: CMTime(seconds: 1.75, preferredTimescale: 600))
        // Before the cut the still comes in from its own spare picture; after
        // it the footage goes out over its spare frames, not over black.
        let before = try await grayLevel(of: composed, at: CMTime(seconds: 0.75, preferredTimescale: 600))
        let after = try await grayLevel(of: composed, at: CMTime(seconds: 1.25, preferredTimescale: 600))
        #expect(before > footageAlone + 20)
        #expect(after < stillAlone - 20)
        #expect(after > before)
    }

    @Test func footageDissolvesWithTheStillBeforeIt() async throws {
        let (fixture, composed) = try await dissolve(stillFirst: true, footage: 220, still: 40)
        defer { fixture.cleanUp() }
        let footageAlone = try await grayLevel(of: composed, at: CMTime(seconds: 1.75, preferredTimescale: 600))
        // After the cut the footage comes in over the still's spare picture,
        // so it is darker than the footage alone, though brighter than a
        // dissolve from black would leave it.
        let after = try await grayLevel(of: composed, at: CMTime(seconds: 1.25, preferredTimescale: 600))
        #expect(after < footageAlone - 20)
        #expect(after > 40 + 20)
    }

    @Test func aMissingStillStopsExportButNotTheViewer() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.addClip(luma: 100)
        let placed = try await fixture.addStill { _, _ in (220, 255) }
        try FileManager.default.removeItem(at: placed.url)

        await #expect(throws: CompositionError.self) { try await fixture.build() }
        let preview = try await fixture.build(forPreview: true)
        let level = try await grayLevel(of: preview, at: .zero)
        #expect(abs(level - 100) < 12)
    }

    @Test func savingKeepsAStillsKindEvenOffline() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await fixture.addStill { _, _ in (220, 255) }
        let package = fixture.directory.appending(path: "Stills.amv", directoryHint: .isDirectory)

        try await ProjectStore.save(fixture.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        #expect(loaded.project.clips.first?.kind == .image)

        try FileManager.default.removeItem(at: placed.url)
        let offline = try await ProjectStore.load(from: package)
        #expect(offline.project.clips.first?.kind == .image)
    }

    @Test func aStillIsReplacedOnlyByAPicture() async throws {
        let fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let first = fixture.directory.appending(path: "first.png")
        let second = fixture.directory.appending(path: "second.png")
        try writeStill(to: first) { _, _ in (100, 255) }
        try writeStill(to: second) { _, _ in (200, 255) }
        let asset = try MediaImporter.importStill(at: first)

        let analysis = try await MediaReplacer.analyze(
            candidate: second, replacing: asset, reference: nil,
            originalScores: .failure(.notCaptured), usedRanges: [CMTimeRange(start: .zero, duration: CMTime(seconds: 20, preferredTimescale: 600))]
        )
        #expect(analysis.needsNoQuestions)

        let movie = fixture.directory.appending(path: "movie.mov")
        try await writeMovie(to: movie, segments: [(luma: 50, frames: 12)])
        await #expect(throws: ReplacementKindError.self) {
            try await MediaReplacer.analyze(
                candidate: movie, replacing: asset, reference: nil, originalScores: .failure(.notCaptured), usedRanges: []
            )
        }
    }
}
