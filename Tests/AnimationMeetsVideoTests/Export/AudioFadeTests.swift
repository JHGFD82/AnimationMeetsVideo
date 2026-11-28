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

    /// How `clip`'s sound is heard at each hundredth of a second to 10 s:
    /// its fades' gains where it plays, past its ends included, else 0.
    private func heard(_ clip: TimelineClip, among clips: [TimelineClip], in project: EditingProject) -> [Float] {
        let (fades, head, tail) = project.audioFades(of: clip, among: clips)
        let from = CMTimeSubtract(clip.startOffset, head).seconds, to = CMTimeAdd(clip.endOffset, tail).seconds
        return (0..<1000).map { step in
            let t = Double(step) / 100 + 0.005
            guard t >= from, t < to else { return 0 }
            return fades.reduce(Float(1)) { $0 * $1.gain(at: t) }
        }
    }

    private func close(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.001 }
    }

    // F99: detaching dropped the fades the sound had under the picture's
    // transitions, so detached sound came in and went out at full level.
    @Test(arguments: [false, true])
    func detachedSoundIsHeardAsItWasAttached(both: Bool) throws {
        var (project, a, b, layer) = try joined()
        let t = project.rootTimelineID
        // From black into A, linear; and a joint at the cut, A into B.
        project.setTransition(.crossDissolve, at: .leading, of: a, in: t, layer: layer)
        project.editClip(a, in: t) { $0.transitionIn?.curve = .linear }
        project.setTransition(.crossDissolve, at: .leading, of: b, in: t, layer: layer)
        let before = try #require(project.timeline(id: t)?.layer(id: layer)?.clips)
        let clipA = try #require(before.first { $0.id == a }), clipB = try #require(before.first { $0.id == b })
        #expect(clipB.transitionIn?.lead ?? .zero > .zero)

        let detached = project.detachAudio(of: both ? nil : [b], in: t, layer: layer)
        let soundLayer = try #require(detached)
        let copies = try #require(project.timeline(id: t)?.layer(id: soundLayer)?.clips).sorted { $0.startOffset < $1.startOffset }
        let pictures = try #require(project.timeline(id: t)?.layer(id: layer)?.clips)
        #expect(copies.count == (both ? 2 : 1))

        let copyB = try #require(copies.last)
        #expect(close(heard(copyB, among: copies, in: project), heard(clipB, among: before, in: project)))
        if both {
            #expect(close(heard(copies[0], among: copies, in: project), heard(clipA, among: before, in: project)))
        } else {
            // A's sound, still attached, fades out across the joint as before.
            let stillA = try #require(pictures.first { $0.id == a })
            #expect(close(heard(stillA, among: pictures, in: project), heard(clipA, among: before, in: project)))
        }
    }

    @Test func aJoinedCutCrossfadesBothClipsOverTheTransition() throws {
        var (project, a, b, layer) = try joined()
        // Centered on the cut: 3.5 s to 4.5 s.
        project.setTransition(.crossDissolve, at: .leading, of: b, in: project.rootTimelineID, layer: layer)
        let outgoing = try fades(of: a, in: project)
        let incoming = try fades(of: b, in: project)
        #expect(outgoing.fades == [AudioFade(start: 3.5, end: 4.5, rising: false, crossfade: .sCurve)])
        #expect(incoming.fades == [AudioFade(start: 3.5, end: 4.5, rising: true, crossfade: .sCurve)])
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
        #expect(outgoing.fades == [AudioFade(start: 3, end: 4, rising: false, crossfade: .sCurve)])
        #expect(incoming.fades == [AudioFade(start: 3, end: 4, rising: true, crossfade: .sCurve)])
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

    /// Each shape starts and ends level, and the two sides mirror each
    /// other: an S-curve and a linear crossfade sum to one, equal power
    /// sums in power.
    @Test func crossfadeShapes() {
        for shape in AudioCrossfade.allCases {
            let rising = AudioFade(start: 0, end: 2, rising: true, crossfade: shape)
            let falling = AudioFade(start: 0, end: 2, rising: false, crossfade: shape)
            #expect(rising.gain(at: 0) == 0 && rising.gain(at: 2) == 1)
            #expect(falling.gain(at: 0) == 1 && falling.gain(at: 2) < 0.0001)
            for seconds in stride(from: 0.0, through: 2, by: 0.25) {
                let (up, down) = (rising.gain(at: seconds), falling.gain(at: seconds))
                switch shape {
                case .sCurve, .linear: #expect(abs(up + down - 1) < 0.0001)
                case .equalPower: #expect(abs(up * up + down * down - 1) < 0.0001)
                }
            }
        }
        // The S-curve eases out of its start, where linear doesn't.
        let s = AudioFade(start: 0, end: 1, rising: true, crossfade: .sCurve)
        let straight = AudioFade(start: 0, end: 1, rising: true, crossfade: .linear)
        #expect(s.gain(at: 0.1) < straight.gain(at: 0.1) / 2)
        #expect(abs(s.gain(at: 0.5) - 0.5) < 0.0001)
    }

    /// The project's shape applies at every joined cut whose transition
    /// doesn't choose one; a transition's own wins, for both clips' sound.
    @Test func aJoinedCutTakesTheProjectsShapeUnlessItsTransitionHasOne() throws {
        var (project, a, b, layer) = try joined()
        let t = project.rootTimelineID
        project.setTransition(.crossDissolve, at: .leading, of: b, in: t, layer: layer)
        project.jointAudioCrossfade = .equalPower
        #expect(try fades(of: a, in: project).fades.map(\.crossfade) == [.equalPower])
        #expect(try fades(of: b, in: project).fades.map(\.crossfade) == [.equalPower])

        project.editClip(b, in: t) { $0.transitionIn?.audioCrossfade = .linear }
        #expect(try fades(of: a, in: project).fades.map(\.crossfade) == [.linear])
        #expect(try fades(of: b, in: project).fades.map(\.crossfade) == [.linear])

        // Changing the kind keeps the sound's shape.
        project.setTransition(.wipe, at: .leading, of: b, in: t, layer: layer)
        #expect(try fades(of: b, in: project).fades.map(\.crossfade) == [.linear])

        // The project's shape is built into the tracks' fades, so changing
        // it rebuilds the player.
        var changed = project
        changed.jointAudioCrossfade = .sCurve
        #expect(CompositionKey(project: changed) != CompositionKey(project: project))
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
