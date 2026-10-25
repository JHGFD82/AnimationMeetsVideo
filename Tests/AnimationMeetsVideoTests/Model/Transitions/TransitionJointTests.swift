import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func video(url: URL? = nil, duration: Double = 10) -> MediaClip {
    MediaClip(name: "Clip", kind: .video, url: url, duration: seconds(duration), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
}

@Suite struct TransitionJointTests {
    /// One asset, ten seconds. A plays 0–4 s of it from 0 s, B plays 6–9 s
    /// from 4 s: six seconds of spare footage on each side of the cut.
    private struct Fixture {
        var project = EditingProject.empty
        var t: UUID
        var layer: UUID
        var a: UUID
        var b: UUID

        init(url: URL? = nil, bTrimStart: Double = 6, bStart: CMTime = seconds(4)) {
            t = project.rootTimelineID
            let placed = project.importClip(video(url: url), intoTimeline: t)!
            layer = placed.layerID
            a = placed.clipID
            project.trimClipEnd(a, in: t, layer: layer, to: seconds(4))
            let clipB = TimelineClip(source: project.timeline(id: t)!.layers[0].clips[0].source,
                                     startOffset: bStart, trimStart: seconds(bTrimStart), trimEnd: seconds(bTrimStart + 3))
            b = clipB.id
            let tIndex = project.timelines.firstIndex { $0.id == t }!
            project.timelines[tIndex].layers[0].clips.append(clipB)
        }

        var joint: TransitionJoint? { project.joint(at: b, in: t, layer: layer) }
        var clipB: TimelineClip { project.timeline(id: t)!.layer(id: layer)!.clips.first { $0.id == b }! }
        var clipA: TimelineClip { project.timeline(id: t)!.layer(id: layer)!.clips.first { $0.id == a }! }
    }

    @Test func aTransitionAtACutJoinsTheClipsCentered() throws {
        var f = Fixture()
        // Dropped on the outgoing clip's end, it still belongs to the incoming one.
        f.project.setTransition(.crossDissolve, at: .trailing, of: f.a, in: f.t, layer: f.layer)
        #expect(f.clipA.transitionOut == nil)
        let joint = try #require(f.joint)
        #expect(joint.transition.duration == seconds(1))
        #expect(joint.lead == seconds(0.5))
        #expect(joint.start == seconds(3.5) && joint.end == seconds(4.5))
        #expect(joint.spareTail == seconds(6) && joint.spareHead == seconds(6))
    }

    /// Clips a sliver apart (their edges in different timescales) are a cut
    /// as everywhere else, so a transition dropped there joins them; a
    /// real gap doesn't.
    @Test func aTransitionJoinsClipsASliverApart() throws {
        var f = Fixture(bStart: CMTimeAdd(seconds(4), CMTime(value: 1, timescale: 3000)))
        f.project.setTransition(.crossDissolve, at: .trailing, of: f.a, in: f.t, layer: f.layer)
        #expect(f.joint != nil)
        #expect(f.clipA.transitionOut == nil)

        var gapped = Fixture(bStart: seconds(4.5))
        gapped.project.setTransition(.crossDissolve, at: .trailing, of: gapped.a, in: gapped.t, layer: gapped.layer)
        #expect(gapped.joint == nil)
        #expect(gapped.clipA.transitionOut != nil)
    }

    @Test func aJointKeepsToTheSpareFootage() throws {
        // B starts at the very beginning of the file: nothing before its in point.
        var f = Fixture(bTrimStart: 0)
        f.project.setTransition(.crossDissolve, at: .leading, of: f.b, in: f.t, layer: f.layer)
        let joint = try #require(f.joint)
        #expect(joint.lead == .zero)
        f.project.applyJointEdit(.place(duration: seconds(2), lead: seconds(1)), at: f.b, in: f.t, layer: f.layer)
        #expect(f.joint?.lead == .zero)
        #expect(f.joint?.transition.duration == seconds(2))
    }

    @Test func movingAndLengtheningAJoint() throws {
        var f = Fixture()
        f.project.setTransition(.filmDissolve, at: .leading, of: f.b, in: f.t, layer: f.layer)
        f.project.applyJointEdit(.place(duration: seconds(2), lead: seconds(2)), at: f.b, in: f.t, layer: f.layer)
        #expect(f.joint?.start == seconds(2) && f.joint?.end == seconds(4))
        // No longer than both clips' room around the cut.
        f.project.applyJointEdit(.place(duration: seconds(20), lead: seconds(1)), at: f.b, in: f.t, layer: f.layer)
        #expect(f.joint?.transition.duration == seconds(7))
    }

    @Test func rollingTheCutTrimsOneClipAsTheOtherGrows() throws {
        var f = Fixture()
        f.project.setTransition(.crossDissolve, at: .leading, of: f.b, in: f.t, layer: f.layer)
        f.project.applyJointEdit(.roll(seconds(1)), at: f.b, in: f.t, layer: f.layer)
        #expect(f.clipA.trimEnd == seconds(5))
        #expect(f.clipB.trimStart == seconds(7) && f.clipB.startOffset == seconds(5))
        #expect(f.clipB.endOffset == seconds(7))
        // Never past the end of the incoming clip.
        f.project.applyJointEdit(.roll(seconds(10)), at: f.b, in: f.t, layer: f.layer)
        #expect(f.clipB.endOffset == seconds(7))
        #expect(f.clipB.trimmedDuration == CMTime(value: 1, timescale: 24))
    }

    @Test func wideningKeepsTheTransitionsCenter() throws {
        var f = Fixture()
        f.project.setTransition(.crossDissolve, at: .leading, of: f.b, in: f.t, layer: f.layer)
        let before = try #require(f.joint)
        let center = CMTimeAdd(before.start, CMTimeMultiplyByRatio(before.transition.duration, multiplier: 1, divisor: 2))

        f.project.applyJointEdit(.widen(seconds(0.5)), at: f.b, in: f.t, layer: f.layer)
        let wider = try #require(f.joint)
        #expect(wider.transition.duration == seconds(2))
        #expect(CMTimeAdd(wider.start, seconds(1)) == center)

        f.project.applyJointEdit(.widen(seconds(-0.75)), at: f.b, in: f.t, layer: f.layer)
        let narrower = try #require(f.joint)
        #expect(narrower.transition.duration == seconds(0.5))
        #expect(CMTimeAdd(narrower.start, seconds(0.25)) == center)
    }

    /// The sound's shape is set on its own; its timing stays the
    /// transition's.
    @Test func settingTheSoundsShapeLeavesTheTiming() throws {
        var f = Fixture()
        f.project.setTransition(.crossDissolve, at: .leading, of: f.b, in: f.t, layer: f.layer)
        let before = try #require(f.joint)
        f.project.applyJointEdit(.soundCrossfade(.equalPower), at: f.b, in: f.t, layer: f.layer)
        let after = try #require(f.joint)
        #expect(after.transition.audioCrossfade == .equalPower)
        #expect(after.start == before.start && after.end == before.end && after.lead == before.lead)
        f.project.applyJointEdit(.soundCrossfade(nil), at: f.b, in: f.t, layer: f.layer)
        #expect(f.joint?.transition.audioCrossfade == nil)
    }

    @Test func slippingEitherClipAtACutKeepsTheCut() throws {
        var f = Fixture()
        f.project.setTransition(.crossDissolve, at: .leading, of: f.b, in: f.t, layer: f.layer)

        f.project.applyJointEdit(.slipOut(seconds(1)), at: f.b, in: f.t, layer: f.layer)
        #expect(f.clipA.trimStart == seconds(1) && f.clipA.trimEnd == seconds(5))
        #expect(f.clipA.endOffset == seconds(4))

        f.project.applyJointEdit(.slipIn(seconds(-1)), at: f.b, in: f.t, layer: f.layer)
        #expect(f.clipB.trimStart == seconds(5) && f.clipB.trimEnd == seconds(8))
        #expect(f.clipB.startOffset == seconds(4))
        #expect(f.joint != nil)
    }

    @Test func withoutSpareFootageTheTransitionStaysInTheClip() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let placedA = project.importClip(video(duration: 4), intoTimeline: t)
        let placedB = project.importClip(video(duration: 3), intoTimeline: t)
        let a = try #require(placedA), b = try #require(placedB)
        project.moveClip(b.clipID, in: t, layer: b.layerID, onto: a.layerID, to: seconds(4))
        project.setTransition(.crossDissolve, at: .leading, of: b.clipID, in: t, layer: a.layerID)
        #expect(project.joint(at: b.clipID, in: t, layer: a.layerID) == nil)
        let clip = try #require(project.timeline(id: t)?.layer(id: a.layerID)?.clips.first { $0.id == b.clipID })
        #expect(clip.transitionIn?.lead == .zero)
    }

    @Test func aJointPlaysBothClipsAcrossTheCut() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amv-joint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appending(path: "m.mov")
        try await writeMovie(to: movie, segments: [(luma: 40, frames: 120), (luma: 220, frames: 120)])

        var f = Fixture(url: movie)
        f.project.setTransition(.crossDissolve, at: .leading, of: f.b, in: f.t, layer: f.layer)
        let composed = try await CompositionExporter.buildComposedTimeline(for: f.project, timelineID: f.t)
        let tracks = composed.composition.tracks(withMediaType: .video)
        // The incoming clip's head above, the layer, the outgoing tail below.
        #expect(tracks.count == 3)
        let head = try #require(tracks.first?.segments.first { !$0.isEmpty })
        #expect(abs(head.timeMapping.target.start.seconds - 3.5) < 0.05)
        #expect(abs(head.timeMapping.source.start.seconds - 5.5) < 0.05)
        let tail = try #require(tracks.last?.segments.first { !$0.isEmpty })
        #expect(abs(tail.timeMapping.target.start.seconds - 4) < 0.05)
        #expect(abs(tail.timeMapping.source.start.seconds - 4) < 0.05)
        #expect(abs(tail.timeMapping.target.duration.seconds - 0.5) < 0.05)
    }

    /// Two embedded timelines meeting at a cut join as media clips do, with
    /// the rest of each nested timeline as their spare footage.
    @Test func aTransitionAtACutJoinsNestedTimelines() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        func nested(_ name: String) -> ClipSource {
            let id = project.addTimeline(name: name, frameSize: CGSize(width: 1920, height: 1080), frameRate: 24, colorSpace: .rec709)
            _ = project.importClip(video(), intoTimeline: id)
            return .timeline(id)
        }
        let first = nested("A"), second = nested("B")
        let tIndex = project.timelines.firstIndex { $0.id == t }!
        let a = TimelineClip(source: first, startOffset: .zero, trimStart: .zero, trimEnd: seconds(4))
        let b = TimelineClip(source: second, startOffset: seconds(4), trimStart: seconds(6), trimEnd: seconds(9))
        project.timelines[tIndex].layers.append(TimelineLayer(clips: [a, b]))
        let layer = project.timelines[tIndex].layers.last!.id

        project.setTransition(.crossDissolve, at: .trailing, of: a.id, in: t, layer: layer)
        let joint = try #require(project.joint(at: b.id, in: t, layer: layer))
        #expect(joint.lead == seconds(0.5))
        #expect(joint.spareTail == seconds(6) && joint.spareHead == seconds(6))
    }

    /// A dissolve at a cut shows both clips halfway through, whichever of
    /// them are nested timelines, rather than either one over black.
    @Test(arguments: [(true, true), (false, true), (true, false)])
    func aJointBlendsNestedTimelinesAcrossTheCut(outgoingNested: Bool, incomingNested: Bool) async throws {
        let levels = try await jointLevels(outgoingNested: outgoingNested, incomingNested: incomingNested, at: [1, 2, 3])
        let before = levels[0], cut = levels[1], after = levels[2]
        #expect(before < 60 && after > 200)
        #expect(cut > before + 40 && cut < after - 40)
    }

    /// A nested timeline going out keeps playing under the rest of the
    /// dissolve after the cut, as media does, rather than leaving the
    /// incoming clip to fade in over black for its second half. The way in
    /// is the incoming clip's, so the outgoing one has no transition of
    /// its own.
    @Test(arguments: [(true, true), (false, true), (true, false)])
    func aNestedJointDissolvesLikeMedia(outgoingNested: Bool, incomingNested: Bool) async throws {
        let times = [1.75, 2, 2.1, 2.25, 2.4]
        let media = try await jointLevels(outgoingNested: false, incomingNested: false, at: times)
        let nested = try await jointLevels(outgoingNested: outgoingNested, incomingNested: incomingNested, at: times)
        for (a, b) in zip(media, nested) {
            #expect(abs(a - b) <= 4, "\(media) against \(nested)")
        }
    }

    /// Gray levels at `times` (in seconds) across a dissolve from two
    /// seconds of dark to two of bright, cut at two seconds, each a nested
    /// timeline or media.
    private func jointLevels(outgoingNested: Bool, incomingNested: Bool, at times: [Double]) async throws -> [Int] {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let frameSize = fixture.project.timelines[0].frameSize
        let scratch = fixture.project.addTimeline(name: "Scratch", frameSize: frameSize, frameRate: 24, colorSpace: .rec709)
        // Four seconds of one gray, as a nested timeline or as media.
        func source(luma: UInt8, nested: Bool) async throws -> ClipSource {
            let holder = nested
                ? fixture.project.addTimeline(name: "Inner", frameSize: frameSize, frameRate: 24, colorSpace: .rec709)
                : scratch
            let placed = try await fixture.addClip(luma: luma, frames: 96, to: holder)
            return nested ? .timeline(holder) : try #require(fixture.project.timeline(id: holder)?.layer(id: placed.layerID)?.clips.first?.source)
        }
        let dark = try await source(luma: 40, nested: outgoingNested)
        let bright = try await source(luma: 220, nested: incomingNested)

        // The first two seconds of the dark one, then the last two of the bright one.
        let t = fixture.timelineID
        let tIndex = fixture.project.timelines.firstIndex { $0.id == t }!
        let a = TimelineClip(source: dark, startOffset: .zero, trimStart: .zero, trimEnd: seconds(2))
        let b = TimelineClip(source: bright, startOffset: seconds(2), trimStart: seconds(2), trimEnd: seconds(4))
        fixture.project.timelines[tIndex].layers.append(TimelineLayer(clips: [a, b]))
        let layer = fixture.project.timelines[tIndex].layers.last!.id
        fixture.project.setTransition(.crossDissolve, at: .leading, of: b.id, in: t, layer: layer)
        #expect(fixture.project.joint(at: b.id, in: t, layer: layer)?.lead == seconds(0.5))

        let composed = try await fixture.build()
        var levels: [Int] = []
        for time in times {
            levels.append(try await grayLevel(of: composed, at: seconds(time)))
        }
        return levels
    }
}
