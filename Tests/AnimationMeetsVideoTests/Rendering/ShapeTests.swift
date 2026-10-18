import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

extension DrawingFixture {
    /// Puts a shape layer of `kind` at the top of the root timeline, two
    /// seconds long.
    mutating func addShape(_ kind: EffectKind = .rectangle) throws -> (layerID: UUID, clipID: UUID) {
        let added = project.addShapeLayer(kind, to: timelineID, duration: CMTime(seconds: 2, preferredTimescale: 600))
        return try #require(added)
    }

    /// Sets every control of `kind` in the clip's stack to `values`.
    mutating func setControl(_ kind: ControlKind, _ values: [Double], ofClip clipID: UUID) {
        project.editClip(clipID, in: timelineID) { clip in
            for e in clip.effects.indices {
                for c in clip.effects[e].controls.indices where clip.effects[e].controls[c].kind == kind {
                    clip.effects[e].controls[c].number = AnimatedValue(ComponentValue(values: values))
                }
            }
        }
    }
}

@Suite struct ShapeTests {
    private let second = CMTime(seconds: 1, preferredTimescale: 600)

    @Test func aShapeLayerAloneIsDrawnOverBlack() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        // Half the frame's width and height, centered: 64 by 36 of 128 by 72.
        try fixture.addShape()

        let composed = try await fixture.build()
        #expect(composed.hasPictures)
        let inside = try await grayLevel(of: composed, at: second)
        let outside = try await grayLevel(of: composed, at: second, x: 0.1, y: 0.1)
        #expect(inside > 220)
        #expect(outside < 10)
    }

    @Test func anEllipseLeavesTheCornersOfItsBounds() async throws {
        var rectangle = try DrawingFixture()
        defer { rectangle.cleanUp() }
        let box = try rectangle.addShape(.rectangle)
        rectangle.setControl(.shapeSize, [36, 36], ofClip: box.clipID)
        var ellipse = try DrawingFixture()
        defer { ellipse.cleanUp() }
        try ellipse.addShape(.ellipse)

        // 15 pixels left of and above the center: inside a 36-pixel square,
        // outside the circle in it (21 pixels from the center, radius 18).
        let x = (64.0 - 15) / 128, y = (36.0 - 15) / 72
        let square = try await grayLevel(of: rectangle.build(), at: second, x: x, y: y)
        let circle = try await grayLevel(of: ellipse.build(), at: second, x: x, y: y)
        let middle = try await grayLevel(of: ellipse.build(), at: second)
        #expect(square > 220)
        #expect(circle < 10)
        #expect(middle > 220)
    }

    @Test func aTranslucentShapeShowsTheFootageUnderIt() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.addClip(luma: 40)
        let shape = try fixture.addShape()
        fixture.setControl(.fill, [1, 1, 1, 0.5], ofClip: shape.clipID)

        let composed = try await fixture.build()
        let footage = try await grayLevel(of: composed, at: second, x: 0.1, y: 0.1)
        let mixed = try await grayLevel(of: composed, at: second)
        #expect(mixed > footage + 60)
        #expect(mixed < 230)
    }

    @Test func aShapeCanDrawOverFootageInItsOwnStack() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let footage = try await fixture.addClip(luma: 40)
        fixture.project.editClip(footage.clipID, in: fixture.timelineID) { $0.effects = [Effect(kind: .rectangle)] }
        fixture.setControl(.shapeSize, [32, 32], ofClip: footage.clipID)

        let composed = try await fixture.build()
        let box = try await grayLevel(of: composed, at: .zero)
        let around = try await grayLevel(of: composed, at: .zero, x: 0.1, y: 0.1)
        #expect(box > 220)
        #expect(around < 70)
    }

    @Test func aStrokeAloneOutlinesTheShape() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let shape = try fixture.addShape()
        fixture.project.editClip(shape.clipID, in: fixture.timelineID) { clip in
            if let fill = clip.effects[0].controls.firstIndex(where: { $0.kind == .fill }) { clip.effects[0].controls[fill].enabled = false }
        }
        fixture.setControl(.stroke, [1, 1, 1, 1], ofClip: shape.clipID)
        fixture.setControl(.strokeWidth, [4], ofClip: shape.clipID)

        let composed = try await fixture.build()
        // The left edge is at x = 32; the stroke covers 30 to 34.
        let edge = try await grayLevel(of: composed, at: second, x: 32.0 / 128)
        let middle = try await grayLevel(of: composed, at: second)
        #expect(edge > 200)
        #expect(middle < 10)
    }

    @Test func aShapeScaledUpStaysSharp() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let shape = try fixture.addShape()
        // Eight pixels square, then scaled to 64: its left edge lands at 32.
        fixture.setControl(.shapeSize, [8, 8], ofClip: shape.clipID)
        var scale = EffectControl(kind: .scale)
        scale.number = AnimatedValue(ComponentValue(values: [800, 800]))
        fixture.project.editClip(shape.clipID, in: fixture.timelineID) { $0.effects.append(Effect(kind: .transform, controls: [scale])) }

        let composed = try await fixture.build()
        // A pixel and a half either side of the edge. Enlarging an 8-pixel
        // picture eightfold would blur the edge across several pixels.
        let inside = try await grayLevel(of: composed, at: second, x: 33.5 / 128)
        let outside = try await grayLevel(of: composed, at: second, x: 30.5 / 128)
        #expect(inside > 230)
        #expect(outside < 20)
    }

    @Test func movingAShapeKeepsItsRenderButResizingItDoesNot() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let shape = try fixture.addShape()

        let before = try await fixture.build().segments.filter(\.needsRender).map(\.key)
        fixture.project.editClip(shape.clipID, in: fixture.timelineID) { $0.startOffset = CMTime(seconds: 1, preferredTimescale: 24) }
        let moved = try await fixture.build().segments.filter(\.needsRender).map(\.key)
        fixture.setControl(.shapeSize, [20, 20], ofClip: shape.clipID)
        let resized = try await fixture.build().segments.filter(\.needsRender).map(\.key)
        #expect(!before.isEmpty)
        #expect(before == moved)
        #expect(Set(resized).isDisjoint(with: Set(before)))
    }

    @Test func savingKeepsAShapeClipAndItsControls() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let shape = try fixture.addShape(.ellipse)
        fixture.setControl(.fill, [0.2, 0.4, 0.6, 0.8], ofClip: shape.clipID)
        fixture.project.editClip(shape.clipID, in: fixture.timelineID) { clip in
            if let size = clip.effects[0].controls.firstIndex(where: { $0.kind == .shapeSize }) { clip.effects[0].controls[size].linked = true }
        }
        let package = fixture.directory.appending(path: "Shapes.amv", directoryHint: .isDirectory)

        try await ProjectStore.save(fixture.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        let saved = try #require(fixture.project.clipAndLayer(shape.clipID, in: fixture.timelineID)?.clip)
        let read = try #require(loaded.project.clipAndLayer(shape.clipID, in: loaded.project.rootTimelineID)?.clip)
        #expect(read.source == .graphic)
        #expect(read.effects == saved.effects)
    }
}
