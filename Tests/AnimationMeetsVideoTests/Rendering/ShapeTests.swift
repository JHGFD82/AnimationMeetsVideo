import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

extension DrawingFixture {
    /// Puts a shape layer of `kind` at the top of the root timeline, two
    /// seconds long.
    @discardableResult mutating func addShape(_ kind: EffectKind = .rectangle) throws -> (layerID: UUID, clipID: UUID) {
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

extension DrawingFixture {
    /// Sets every choice control of `kind` in the clip's stack.
    mutating func setChoice(_ kind: ControlKind, _ choice: String, ofClip clipID: UUID) {
        project.editClip(clipID, in: timelineID) { clip in
            for e in clip.effects.indices {
                for c in clip.effects[e].controls.indices where clip.effects[e].controls[c].kind == kind {
                    clip.effects[e].controls[c].choice = choice
                }
            }
        }
    }

    /// A gray rectangle, 64 by 36 in the middle of the frame (its left
    /// edge at x = 32), with a white stroke `width` wide on `edge`.
    @discardableResult mutating func addStrokedBox(width: Double, edge: StrokeEdge) throws -> UUID {
        let shape = try addShape()
        setControl(.fill, [0.4, 0.4, 0.4, 1], ofClip: shape.clipID)
        setControl(.stroke, [1, 1, 1, 1], ofClip: shape.clipID)
        setControl(.strokeWidth, [width], ofClip: shape.clipID)
        setChoice(.strokeEdge, edge.rawValue, ofClip: shape.clipID)
        return shape.clipID
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

    /// The gray level along the frame's middle row at x = `pixel` + 0.5.
    private func level(_ composed: ComposedTimeline, x pixel: Double, y row: Double = 36) async throws -> Int {
        try await grayLevel(of: composed, at: second, x: (pixel + 0.5) / 128, y: (row + 0.5) / 72)
    }

    @Test func anOutsideStrokeLeavesTheShapeAlone() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try fixture.addStrokedBox(width: 4, edge: .outside)
        let composed = try await fixture.build()
        // 28 to 32 is the stroke; from 32 in is the gray fill.
        #expect(try await level(composed, x: 29) > 220)
        let fill = try await level(composed, x: 33)
        #expect(fill > 60 && fill < 160)
        #expect(try await level(composed, x: 26) < 10)
    }

    @Test func anInsideStrokeKeepsTheShapesSize() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        try fixture.addStrokedBox(width: 4, edge: .inside)
        let composed = try await fixture.build()
        // 32 to 36 is the stroke; nothing is drawn left of 32.
        #expect(try await level(composed, x: 33) > 220)
        #expect(try await level(composed, x: 30) < 10)
        let fill = try await level(composed, x: 40)
        #expect(fill > 60 && fill < 160)
    }

    @Test func aStrokeEffectStrokesTheStrokeAboveIt() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let clipID = try fixture.addStrokedBox(width: 4, edge: .center)
        // Around the outer edge of the white stroke (30), outside it: 26 to 30.
        var stroke = Effect(kind: .stroke)
        for index in stroke.controls.indices {
            switch stroke.controls[index].kind {
            case .stroke: stroke.controls[index].number = AnimatedValue(ComponentValue(values: [0.6, 0.6, 0.6, 1]))
            case .strokeWidth: stroke.controls[index].number = AnimatedValue(ComponentValue(values: [4]))
            case .strokeEdge: stroke.controls[index].choice = StrokeEdge.outside.rawValue
            default: break
            }
        }
        fixture.project.editClip(clipID, in: fixture.timelineID) { $0.effects.append(stroke) }

        let composed = try await fixture.build()
        let outer = try await level(composed, x: 27)
        #expect(outer > 120 && outer < 210)
        #expect(try await level(composed, x: 31) > 220)
        #expect(try await level(composed, x: 24) < 10)
    }

    @Test func aStrokeWithNoShapesAboveItSaysSo() throws {
        let stroke = Effect(kind: .stroke)
        #expect(!EditingProject.strokeHasShapes([stroke], at: 0))
        #expect(EditingProject.strokeHasShapes([Effect(kind: .star), stroke], at: 1))
        #expect(!EditingProject.strokeHasShapes([Effect(kind: .star), Effect(kind: .blending), stroke], at: 2))
    }

    @Test func aStarIsNotchedBetweenItsPoints() async throws {
        var polygon = try DrawingFixture()
        defer { polygon.cleanUp() }
        try polygon.addShape(.polygon)
        var star = try DrawingFixture()
        defer { star.cleanUp() }
        try star.addShape(.star)

        // Radius 18, inner 9: 12 pixels out between the first two points
        // (54 degrees up and right of the center) is inside a pentagon,
        // whose edge is 14.6 out there, and in a star's notch.
        let angle = -54.0 * .pi / 180
        let x = 64 + 12 * cos(angle), y = 36 + 12 * sin(angle)
        let pentagon = try await grayLevel(of: polygon.build(), at: second, x: x / 128, y: y / 72)
        let notch = try await grayLevel(of: star.build(), at: second, x: x / 128, y: y / 72)
        #expect(pentagon > 220)
        #expect(notch < 30)
        #expect(try await grayLevel(of: star.build(), at: second) > 220)
    }

    @Test func aDashedStrokeHasGaps() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let clipID = try fixture.addStrokedBox(width: 2, edge: .center)
        fixture.setControl(.dash, [6, 6], ofClip: clipID)
        let composed = try await fixture.build()
        // Along the outer half of the top edge's stroke (row 17, outside the
        // box at 18), from x = 40 to 60.
        var levels: [Int] = []
        for x in stride(from: 40.0, through: 60, by: 1) { levels.append(try await level(composed, x: x, y: 17)) }
        #expect(levels.contains { $0 > 200 })
        #expect(levels.contains { $0 < 40 })
    }

    @Test func savingKeepsStarsAndStrokeChoices() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let shape = try fixture.addShape(.star)
        fixture.project.editClip(shape.clipID, in: fixture.timelineID) { $0.effects.append(Effect(kind: .stroke)) }
        fixture.setChoice(.strokeEdge, StrokeEdge.outside.rawValue, ofClip: shape.clipID)
        fixture.setChoice(.strokeJoin, StrokeJoin.round.rawValue, ofClip: shape.clipID)
        fixture.setControl(.dash, [3, 5], ofClip: shape.clipID)
        let package = fixture.directory.appending(path: "Stars.amv", directoryHint: .isDirectory)

        try await ProjectStore.save(fixture.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        let saved = try #require(fixture.project.clipAndLayer(shape.clipID, in: fixture.timelineID)?.clip)
        let read = try #require(loaded.project.clipAndLayer(shape.clipID, in: loaded.project.rootTimelineID)?.clip)
        #expect(read.effects == saved.effects)
    }

    @Test func eachChoiceOffersItsOwnOptions() {
        #expect(ControlKind.matteMode.choiceOptions.map(\.id) == MatteMode.allCases.map(\.rawValue))
        #expect(ControlKind.strokeEdge.choiceOptions.map(\.id) == StrokeEdge.allCases.map(\.rawValue))
        #expect(ControlKind.mode.choiceOptions.map(\.id) == BlendMode.allCases.map(\.rawValue))
    }

    @Test func aSquircleFillsMoreOfItsCornersThanACircle() async throws {
        func corner(squircle: Bool) async throws -> Int {
            var fixture = try DrawingFixture()
            defer { fixture.cleanUp() }
            // 60 square in the middle: from (34, 6) to (94, 66).
            let shape = try fixture.addShape()
            fixture.setControl(.shapeSize, [60, 60], ofClip: shape.clipID)
            fixture.setControl(.cornerRadius, [25], ofClip: shape.clipID)
            fixture.project.editClip(shape.clipID, in: fixture.timelineID) { clip in
                if let index = clip.effects[0].controls.firstIndex(where: { $0.kind == .cornerRadius }) {
                    clip.effects[0].controls[index].squircle = squircle
                }
            }
            // On the top left diagonal: 27.6 from the circular corner's
            // center, outside its radius of 25, but inside the squircle,
            // whose corner reaches out to (37.9, 9.9).
            return try await grayLevel(of: fixture.build(), at: second, x: 39.5 / 128, y: 11.5 / 72)
        }
        #expect(try await corner(squircle: false) < 60)
        #expect(try await corner(squircle: true) > 180)
    }

    @Test func savingKeepsASquircle() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let shape = try fixture.addShape()
        fixture.project.editClip(shape.clipID, in: fixture.timelineID) { clip in
            if let index = clip.effects[0].controls.firstIndex(where: { $0.kind == .cornerRadius }) {
                clip.effects[0].controls[index].squircle = true
            }
        }
        let package = fixture.directory.appending(path: "Squircle.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(fixture.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        let read = try #require(loaded.project.clipAndLayer(shape.clipID, in: loaded.project.rootTimelineID)?.clip)
        #expect(read.effects[0].control(.cornerRadius)?.squircle == true)
    }
}
