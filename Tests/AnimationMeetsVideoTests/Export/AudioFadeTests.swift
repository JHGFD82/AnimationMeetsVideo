import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// Sound fading under transitions.
@Suite struct AudioFadeTests {
    @Test func fadesAreEqualPower() {
        let rising = AudioFade(start: 1, end: 3, rising: true)
        let falling = AudioFade(start: 1, end: 3, rising: false)
        #expect(rising.gain(at: 0) == 0 && rising.gain(at: 4) == 1)
        #expect(falling.gain(at: 0) == 1 && falling.gain(at: 4) < 0.0001)
        // Halfway, each is down 3 dB, so together they are as loud as one.
        let half = rising.gain(at: 2)
        #expect(abs(half - falling.gain(at: 2)) < 0.0001)
        #expect(abs(half * half + falling.gain(at: 2) * falling.gain(at: 2) - 1) < 0.0001)
        #expect(abs(AudioFade(start: 1, end: 3, rising: true, curve: TransitionCurve(preset: .easyEase)).gain(at: 1.2) - rising.gain(at: 1.2)) > 0.01)
    }

    /// One video with sound, ten seconds. A plays 0–4 s of it from 0 s, B
    /// plays 6–9 s from 4 s.
    private func joined() throws -> (EditingProject, a: UUID, b: UUID, layer: UUID) {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(
            name: "Clip", kind: .video, url: nil, duration: seconds(10), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: t)
        let placed = try #require(imported)
        project.trimClipEnd(placed.clipID, in: t, layer: placed.layerID, to: seconds(4))
        let source = try #require(project.clipAndLayer(placed.clipID, in: t)?.clip.source)
        let b = TimelineClip(source: source, startOffset: seconds(4), trimStart: seconds(6), trimEnd: seconds(9))
        let tIndex = try #require(project.timelines.firstIndex { $0.id == t })
        project.timelines[tIndex].layers[0].clips.append(b)
        return (project, placed.clipID, b.id, placed.layerID)
    }

    private func fades(of clipID: UUID, in project: EditingProject) throws -> (fades: [AudioFade], head: CMTime, tail: CMTime) {
        let layer = try #require(project.clipAndLayer(clipID, in: project.rootTimelineID)?.layer)
        let clip = try #require(layer.clips.first { $0.id == clipID })
        return project.audioFades(of: clip, among: layer.clips)
    }

    @Test func aJoinedCutCrossfadesBothClipsOverTheTransition() throws {
        var (project, a, b, layer) = try joined()
        // Centered on the cut: 3.5 s to 4.5 s.
        project.setTransition(.crossDissolve, at: .leading, of: b, in: project.rootTimelineID, layer: layer)
        let outgoing = try fades(of: a, in: project)
        let incoming = try fades(of: b, in: project)
        #expect(outgoing.fades == [AudioFade(start: 3.5, end: 4.5, rising: false)])
        #expect(incoming.fades == [AudioFade(start: 3.5, end: 4.5, rising: true)])
        // A plays half a second past its out point, B half a second before
        // its in point.
        #expect(outgoing.tail == seconds(0.5) && outgoing.head == .zero)
        #expect(incoming.head == seconds(0.5) && incoming.tail == .zero)
    }

    @Test func aWayOutAtACutFadesTheNextClipInUnderIt() throws {
        var (project, a, b, _) = try joined()
        // Set directly: a drop at a cut would give it to the incoming clip.
        project.editClip(a, in: project.rootTimelineID) { $0.transitionOut = ClipTransition(kind: .crossDissolve, duration: seconds(1)) }
        let outgoing = try fades(of: a, in: project)
        let incoming = try fades(of: b, in: project)
        #expect(outgoing.fades == [AudioFade(start: 3, end: 4, rising: false)])
        #expect(incoming.fades == [AudioFade(start: 3, end: 4, rising: true)])
        #expect(incoming.head == seconds(1))
    }

    @Test func aTransitionAtAnOpenEndFadesToSilence() throws {
        var (project, a, _, layer) = try joined()
        let t = project.rootTimelineID
        project.setTransition(.crossDissolve, at: .leading, of: a, in: t, layer: layer)
        let result = try fades(of: a, in: project)
        #expect(result.fades == [AudioFade(start: 0, end: 1, rising: true)])
        #expect(result.head == .zero)
    }

    @Test func theMixFadesInUnderAWayIn() async throws {
        let url = try AudioMixSupport.tone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, clipID, _) = try AudioMixSupport.project(playing: url, seconds: 2)
        project.editClip(clipID, in: project.rootTimelineID) {
            $0.transitionIn = ClipTransition(kind: .crossDissolve, duration: seconds(1))
        }
        let early = try await AudioMixSupport.loudest(of: project, before: 0.1)
        let middle = try await AudioMixSupport.loudest(of: project, after: 0.49, before: 0.51)
        let late = try await AudioMixSupport.loudest(of: project, after: 1.2)
        #expect(early.x < 0.25 * 0.2)
        #expect(abs(middle.x - 0.25 * Float(0.5).squareRoot()) < 0.01)
        #expect(abs(late.x - 0.25) < 0.005)
    }
}
