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

        init(url: URL? = nil, bTrimStart: Double = 6) {
            t = project.rootTimelineID
            let placed = project.importClip(video(url: url), intoTimeline: t)!
            layer = placed.layerID
            a = placed.clipID
            project.trimClipEnd(a, in: t, layer: layer, to: seconds(4))
            let clipB = TimelineClip(source: project.timeline(id: t)!.layers[0].clips[0].source,
                                     startOffset: seconds(4), trimStart: seconds(bTrimStart), trimEnd: seconds(bTrimStart + 3))
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

    @Test func rippleEditsAtACutMoveWhatFollows() throws {
        var f = Fixture()
        f.project.setTransition(.crossDissolve, at: .leading, of: f.b, in: f.t, layer: f.layer)

        // The outgoing clip grows by a second; the incoming one follows the cut.
        f.project.applyJointEdit(.rippleOut(seconds(1)), at: f.b, in: f.t, layer: f.layer)
        #expect(f.clipA.endOffset == seconds(5))
        #expect(f.clipB.startOffset == seconds(5) && f.clipB.trimStart == seconds(6))

        // The incoming clip loses its first second; the cut stays.
        f.project.applyJointEdit(.rippleIn(seconds(1)), at: f.b, in: f.t, layer: f.layer)
        #expect(f.clipB.startOffset == seconds(5) && f.clipB.trimStart == seconds(7))
        #expect(f.clipB.endOffset == seconds(7))
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
}
