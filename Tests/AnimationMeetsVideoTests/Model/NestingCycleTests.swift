import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A timeline never ends up inside itself, however deep, by any way of
/// putting one timeline in another.
@Suite struct NestingCycleTests {
    private static func media() -> MediaClip {
        MediaClip(
            name: "Clip", kind: .video, url: nil,
            duration: CMTime(seconds: 5, preferredTimescale: 600),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
    }

    /// A embeds B, B embeds C, and C takes D as an effect's input; each has
    /// footage of its own.
    private static func chain() throws -> (project: EditingProject, a: UUID, b: UUID, c: UUID, d: UUID) {
        var project = EditingProject.empty
        func add(_ name: String) -> UUID {
            let id = project.addTimeline(name: name, frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
            _ = project.importClip(Self.media(), intoTimeline: id)
            return id
        }
        let a = add("A"), b = add("B"), c = add("C"), d = add("D")
        let inB = project.embedTimeline(b, intoTimeline: a)
        let inC = project.embedTimeline(c, intoTimeline: b)
        #expect(inB != nil && inC != nil)
        let host = try #require(project.timeline(id: c)?.layers.first?.clips.first)
        var matte = Effect(kind: .matte)
        matte.input = EffectInput(source: .timeline(d))
        project.editClip(host.id, in: c) { $0.effects = [matte] }
        return (project, a, b, c, d)
    }

    @Test func noWayOfNestingPutsATimelineInsideItself() throws {
        var (project, a, b, c, d) = try Self.chain()
        let before = project

        for (outer, inner) in [(a, a), (a, b), (a, c), (a, d), (b, c), (c, d)] {
            // Embed, from the browser's menu.
            #expect(!project.canEmbed(outer, into: inner))
            let embeddedHere = project.embedTimeline(outer, intoTimeline: inner)
            #expect(embeddedHere == nil)
            // Dropped on a new layer, or on a layer there.
            let piece = MediaPiece.timeline(outer, from: .zero, to: CMTime(seconds: 1, preferredTimescale: 600))
            let onNewLayer = project.addPieces([piece], intoTimeline: inner)
            #expect(onNewLayer == nil)
            let layer = try #require(project.timeline(id: inner)?.layers.first)
            let onLayer = project.addPieces([piece], intoLayer: layer.id, in: inner, at: .zero)
            #expect(onLayer == nil)
            // As an effect's input, on the footage there.
            let footage = try #require(layer.clips.first)
            var effect = Effect(kind: .matte)
            effect.input = nil
            project.editClip(footage.id, in: inner) { $0.effects.append(effect) }
            let accepted = project.setInput(EffectInput(source: .timeline(outer)), ofEffect: effect.id, onClip: footage.id, in: inner)
            #expect(!accepted)
        }
        #expect(project.timelines.map(\.layers.count) == before.timelines.map(\.layers.count))

        // A pasted clip of A refuses to go into D; a pasted clip whose
        // effect takes A as its input goes into D without that input.
        let embedded = try #require(project.timeline(id: a)?.layers.first?.clips.first { $0.source == .timeline(b) })
        let ofB = try #require(project.clipBundle(embedded.id, in: a))
        let refused = project.paste(ofB, in: d, onto: nil, at: .zero)
        #expect(refused == nil)
        let footageOfD = try #require(project.timeline(id: d)?.layers.last?.clips.first)
        var withInput = try #require(project.clipBundle(footageOfD.id, in: d))
        var matte = Effect(kind: .matte)
        matte.input = EffectInput(source: .timeline(a))
        withInput.clip.effects = [matte]
        let pastedHere = project.paste(withInput, in: d, onto: nil, at: .zero)
        let pasted = try #require(pastedHere)
        let clip = try #require(project.clipAndLayer(pasted.clipID, in: d)?.clip)
        #expect(clip.effects.first?.input == nil)
        #expect(!project.timelinesDrawn(from: d).contains(a))
    }

    /// Several timelines added at once go back to back on one new layer,
    /// as clips do.
    @Test func severalTimelinesGoOnOneLayer() throws {
        var project = EditingProject.empty
        let main = project.rootTimelineID
        var ids: [UUID] = []
        for name in ["One", "Two", "Three"] {
            let id = project.addTimeline(name: name, frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
            _ = project.importClip(Self.media(), intoTimeline: id)
            ids.append(id)
        }
        let pieces = ids.map { MediaPiece.timeline($0, from: .zero, to: CMTime(seconds: 5, preferredTimescale: 600)) }
        let addedHere = project.addPieces(pieces, intoTimeline: main)
        let added = try #require(addedHere)
        let timeline = try #require(project.timeline(id: main))
        #expect(timeline.layers.count == 1)
        let clips = try #require(timeline.layer(id: added.layerID)?.clips)
        #expect(clips.map(\.source) == ids.map { .timeline($0) })
        #expect(clips.map(\.startOffset.seconds) == [0, 5, 10])
    }
}
