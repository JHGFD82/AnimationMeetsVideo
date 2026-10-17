import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func videoWithSound(url: URL? = nil, duration: Double = 10) -> MediaClip {
    MediaClip(
        name: "Clip", kind: .video, url: url, duration: seconds(duration),
        frameRate: 24, colorSpace: .rec709, codecName: "H.264", hasAudio: true
    )
}

@Suite struct TransitionEditingTests {
    private func setUp(duration: Double = 10) throws -> (EditingProject, UUID, UUID, UUID) {
        var project = EditingProject.empty
        let imported = project.importClip(videoWithSound(duration: duration), intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        return (project, project.rootTimelineID, ids.layerID, ids.clipID)
    }

    private func clip(_ project: EditingProject, _ t: UUID, _ l: UUID) -> TimelineClip? {
        project.timeline(id: t)?.layer(id: l)?.clips.first
    }

    @Test func aNewTransitionIsASecondAndKeepsItsLengthWhenChanged() throws {
        var (project, t, l, c) = try setUp()
        project.setTransition(.crossDissolve, at: .leading, of: c, in: t, layer: l)
        #expect(clip(project, t, l)?.transitionIn == ClipTransition(kind: .crossDissolve, duration: seconds(1)))

        project.setTransitionDuration(seconds(2), at: .leading, of: c, in: t, layer: l)
        project.setTransition(.wipe, at: .leading, of: c, in: t, layer: l)
        let transition = try #require(clip(project, t, l)?.transitionIn)
        #expect(transition.kind == .wipe)
        #expect(transition.duration.seconds == 2)

        project.removeTransition(at: .leading, of: c, in: t, layer: l)
        #expect(clip(project, t, l)?.transitionIn == nil)
    }

    @Test func aTransitionFitsBesideTheOtherEnd() throws {
        var (project, t, l, c) = try setUp(duration: 1.5)
        project.setTransition(.crossDissolve, at: .leading, of: c, in: t, layer: l)
        project.setTransition(.crossDissolve, at: .trailing, of: c, in: t, layer: l)
        #expect(clip(project, t, l)?.transitionOut?.duration.seconds == 0.5)
    }

    @Test func detachedSoundTakesNoTransitions() throws {
        var (project, t, l, _) = try setUp()
        let detached = project.detachAudio(in: t, layer: l)
        let audioLayer = try #require(detached)
        let sound = try #require(clip(project, t, audioLayer))
        project.setTransition(.crossDissolve, at: .leading, of: sound.id, in: t, layer: audioLayer)
        #expect(clip(project, t, audioLayer)?.transitionIn == nil)
    }

    @Test func splittingKeepsTheWayInAndTheWayOut() throws {
        var (project, t, l, c) = try setUp()
        project.setTransition(.crossDissolve, at: .leading, of: c, in: t, layer: l)
        project.setTransition(.zoom, at: .trailing, of: c, in: t, layer: l)
        project.split(c, in: t, layer: l, atTimelineTime: seconds(5))
        let halves = try #require(project.timeline(id: t)?.layer(id: l)?.clips)
        #expect(halves.count == 2)
        #expect(halves[0].transitionIn?.kind == .crossDissolve && halves[0].transitionOut == nil)
        #expect(halves[1].transitionIn == nil && halves[1].transitionOut?.kind == .zoom)
    }

    @Test func trimmedTransitionsShareTheClip() {
        var clip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: seconds(2))
        clip.transitionIn = ClipTransition(kind: .crossDissolve, duration: seconds(3))
        clip.transitionOut = ClipTransition(kind: .crossDissolve, duration: seconds(1))
        let durations = clip.effectiveTransitionDurations()
        #expect(abs(durations.leading.seconds - 4.0 / 3) < 0.001)
        #expect(abs(durations.trailing.seconds - 2.0 / 3) < 0.001)
    }
}

@Suite struct TransitionEffectTests {
    private let frame = CGSize(width: 100, height: 50)

    private func edges(_ kind: TransitionKind, _ direction: TransitionDirection = .right, at edge: TransitionEdge) -> EdgeTransitions {
        var clip = TimelineClip(source: .media(UUID()), startOffset: seconds(10), trimStart: .zero, trimEnd: seconds(4))
        clip.setTransition(ClipTransition(kind: kind, duration: seconds(2), options: TransitionOptions(direction: direction)), at: edge)
        return EdgeTransitions(clip: clip, frameSize: frame)!
    }

    @Test func aDissolveFadesInAndOut() {
        let fadeIn = edges(.crossDissolve, at: .leading)
        #expect(fadeIn.effect(at: seconds(10)).opacity == 0)
        #expect(abs(fadeIn.effect(at: seconds(11)).opacity - 0.5) < 0.001)
        #expect(fadeIn.effect(at: seconds(13)).opacity == 1)

        let fadeOut = edges(.crossDissolve, at: .trailing)
        #expect(abs(fadeOut.effect(at: seconds(13)).opacity - 0.5) < 0.001)
        #expect(fadeOut.animatedRanges == [CMTimeRange(start: seconds(12), end: seconds(14))])
    }

    @Test func aWipeRightUncoversFromTheLeftAndCoversFromTheLeft() {
        let wipeIn = edges(.wipe, .right, at: .leading).effect(at: seconds(11))
        #expect(wipeIn.visibleRect == CGRect(x: 0, y: 0, width: 50, height: 50))
        let wipeOut = edges(.wipe, .right, at: .trailing).effect(at: seconds(13))
        #expect(wipeOut.visibleRect == CGRect(x: 50, y: 0, width: 50, height: 50))
        // Outside the transition the whole frame shows.
        #expect(edges(.wipe, .right, at: .leading).effect(at: seconds(13)).visibleRect == CGRect(origin: .zero, size: frame))
    }

    @Test func aSlideRightComesInFromTheLeft() {
        let start = edges(.slide, .right, at: .leading).effect(at: seconds(10))
        #expect(start.transform.tx == -100)
        let leaving = edges(.slide, .right, at: .trailing).effect(at: seconds(14))
        #expect(leaving.transform.tx == 100)
    }

    @Test func aSlideUpComesInFromBelow() {
        let start = edges(.slide, .up, at: .leading).effect(at: seconds(10))
        #expect(start.transform.tx == 0)
        #expect(start.transform.ty == 50)
    }

    @Test func aWipeUpUncoversFromTheBottom() {
        let wipeIn = edges(.wipe, .up, at: .leading).effect(at: seconds(11))
        #expect(wipeIn.visibleRect == CGRect(x: 0, y: 25, width: 100, height: 25))
    }

    @Test func aSpinTurnsAboutTheCenterWhileFading() {
        let half = edges(.spin, at: .leading).effect(at: seconds(11))
        #expect(abs(half.opacity - 0.5) < 0.001)
        let center = CGPoint(x: 50, y: 25).applying(half.transform)
        #expect(abs(center.x - 50) < 0.001 && abs(center.y - 25) < 0.001)
        // Half a turn in: a point right of center is now left of it.
        let right = CGPoint(x: 90, y: 25).applying(half.transform)
        #expect(right.x < 50)
    }

    @Test func changingKindKeepsTheSettingsBothOffer() {
        let wipe = ClipTransition(kind: .wipe, duration: seconds(1), options: TransitionOptions(direction: .down))
        #expect(TransitionKind.slide.options(replacing: wipe).direction == .down)
        #expect(TransitionKind.crossDissolve.options(replacing: wipe) == TransitionKind.crossDissolve.defaultOptions)
    }
}

@Suite struct TransitionCompositionTests {
    @Test func aTransitionAtACutPlaysTheOutgoingClipUnderneath() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "amv-transition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appending(path: "m.mov")
        try await writeMovie(to: movie, segments: [(luma: 40, frames: 48), (luma: 220, frames: 48)])

        var project = EditingProject.empty
        var media = videoWithSound(url: movie, duration: 4)
        media.hasAudio = false
        let t = project.rootTimelineID
        let imported = project.importClip(media, intoTimeline: t)
        let ids = try #require(imported)
        // Two halves meeting at 2 s, each with frames beyond its trim.
        project.trimClipEnd(ids.clipID, in: t, layer: ids.layerID, to: seconds(1))
        let tIndex = project.timelines.firstIndex { $0.id == t }!
        let next = TimelineClip(source: .media(media.id), startOffset: seconds(1), trimStart: seconds(2), trimEnd: seconds(3))
        project.timelines[tIndex].layers[0].clips.append(next)

        let plain = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t)
        #expect(plain.composition.tracks(withMediaType: .video).count == 1)

        project.setTransition(.crossDissolve, at: .leading, of: next.id, in: t, layer: ids.layerID)
        // All of it after the cut, so only the outgoing clip needs extending.
        project.applyJointEdit(.place(duration: seconds(1), lead: .zero), at: next.id, in: t, layer: ids.layerID)
        let blended = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: t)
        let tracks = blended.composition.tracks(withMediaType: .video)
        #expect(tracks.count == 2)
        // The underlay continues the first clip from where it was trimmed.
        let underlay = try #require(tracks.last?.segments.first { !$0.isEmpty })
        #expect(abs(underlay.timeMapping.source.start.seconds - 1) < 0.05)
        #expect(abs(underlay.timeMapping.target.start.seconds - 1) < 0.05)
        #expect(blended.composition.duration.seconds == plain.composition.duration.seconds)
    }
}
