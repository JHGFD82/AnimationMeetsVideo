import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }

/// A 24 fps timeline with a four-second video clip holding a Transform, and
/// a song on a Music layer: a 60 Hz burst from 1 to 1.5 s and a 5 kHz burst
/// from 2.5 to 3 s, both at half of full scale (about −9 dB).
private struct AudioKeysFixture {
    var project = EditingProject.empty
    let timelineID: UUID
    let clipID: UUID
    let songClipID: UUID
    let transformID: UUID

    init() {
        let silence = { (length: Double) in [Float](repeating: 0, count: Int(length * Spectrogram.sampleRate)) }
        let samples = silence(1) + tone(60, amplitude: 0.5, seconds: 0.5) + silence(1)
            + tone(5000, amplitude: 0.5, seconds: 0.5) + silence(1)
        let url = URL(fileURLWithPath: "/tmp/audio-keys-\(UUID().uuidString).wav")
        SpectrogramStore.shared.set(Spectrogram.analyze(samples), for: url)

        let media = MediaClip(
            name: "A.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264"
        )
        timelineID = project.rootTimelineID
        clipID = project.importClip(media, intoTimeline: timelineID)!.clipID
        let id = clipID
        project.editClip(id, in: timelineID) { $0.trimStart = .zero; $0.trimEnd = seconds(4); $0.startOffset = .zero }
        transformID = project.addEffect(.transform, toClip: clipID, in: timelineID)!

        var song = MediaClip(name: "Song.wav", kind: .audio, url: url, duration: seconds(4), frameRate: 24, colorSpace: .rec709, codecName: "PCM")
        song.hasAudio = true
        project.clips.append(song)
        project.putOnMusicLayer([song.id])
        songClipID = project.timeline(id: timelineID)!.layers.last!.clips[0].id
    }

    var clip: TimelineClip { project.clipAndLayer(clipID, in: timelineID)!.clip }
    var rotation: EffectControl { clip.effect(id: transformID)!.control(.rotation)! }
    func value(at time: Double) -> Double { rotation.values(at: seconds(time))[0] }

    /// An Audio Keys effect on the rotation, listening to the whole mix.
    mutating func listen(from low: Double, to high: Double) -> UUID {
        let id = project.addEffect(.audioKeys, toClip: clipID, in: timelineID)!
        let target = KeyframingTarget.control(effectID: transformID, controlID: rotation.id)
        project.editEffect(id, ofClip: clipID, in: timelineID) { effect in
            effect.keyframing?.target = target
            effect.controls[0].number = AnimatedValue(ComponentValue(values: [low, high]))
        }
        return id
    }

    mutating func set(_ id: UUID, _ kind: ControlKind, _ values: [Double]) {
        project.editEffect(id, ofClip: clipID, in: timelineID) { effect in
            guard let c = effect.controls.firstIndex(where: { $0.kind == kind }) else { return }
            effect.controls[c].number = AnimatedValue(ComponentValue(values: values))
        }
    }
}

@Suite struct AudioKeysTests {
    @Test func theBoxMovesOnlyWithItsOwnTone() {
        var f = AudioKeysFixture()
        _ = f.listen(from: 40, to: 120)
        // −9 dB is above the box's top (−10 dB): all the way up.
        #expect(abs(f.value(at: 1.25) - 10) < 0.2)
        #expect(abs(f.value(at: 0.5)) < 0.1)
        // The 5 kHz burst is outside the box.
        #expect(abs(f.value(at: 2.75)) < 0.1)
    }

    @Test func aHighBoxHearsTheHighTone() {
        var f = AudioKeysFixture()
        _ = f.listen(from: 4000, to: 6000)
        #expect(abs(f.value(at: 2.75) - 10) < 0.2)
        #expect(abs(f.value(at: 1.25)) < 0.1)
    }

    @Test func releaseLingersAndAttackComesInSlowly() {
        var f = AudioKeysFixture()
        let id = f.listen(from: 40, to: 120)
        // The window reaches about 46 ms past the burst; 200 ms of release
        // later about a third is left.
        let lingering = f.value(at: 1.75)
        #expect(lingering > 1 && lingering < 6)
        #expect(abs(f.value(at: 2.2)) < 0.5)
        f.set(id, .keyAttack, [200])
        #expect(f.value(at: 1.1) < 7)
        #expect(f.value(at: 1.45) > 7)
    }

    @Test func theClipsVolumeIsHeard() {
        var f = AudioKeysFixture()
        _ = f.listen(from: 40, to: 120)
        let song = f.songClipID
        let timeline = f.timelineID
        f.project.editClip(song, in: timeline) { $0.volume = AnimatedValue(-20) }
        f.project.refreshKeyframing()
        // −29 dB, halfway up the box from −50 to −10.
        let value = f.value(at: 1.25)
        #expect(value > 4.5 && value < 6)
    }

    @Test func listeningToALayerWithoutTheSongHearsNothing() throws {
        var f = AudioKeysFixture()
        let id = f.listen(from: 40, to: 120)
        let videoLayer = try #require(f.project.clipAndLayer(f.clipID, in: f.timelineID)?.layer.id)
        f.project.editEffect(id, ofClip: f.clipID, in: f.timelineID) { $0.keyframing?.audioSource = .layer(videoLayer) }
        let note = f.project.keyframingNote(for: f.clip.effect(id: id)!, in: f.clip)
        #expect(note?.dims == true)
    }

    @Test func theOutputRangeAndCurveShapeTheValue() {
        var f = AudioKeysFixture()
        let id = f.listen(from: 40, to: 120)
        f.set(id, .outputRange, [100, 130])
        #expect(abs(f.value(at: 1.25) - 130) < 0.5)
        #expect(abs(f.value(at: 0.5) - 100) < 0.2)
    }

    @Test func levelSumsThePartsOfBandsTheRangeCovers() {
        var bands = [Double](repeating: Spectrogram.floor, count: Spectrogram.bandCount)
        bands[10] = -20
        let whole = AudioKeysMath.level(of: bands, from: Spectrogram.edge(10), to: Spectrogram.edge(11))
        let half = AudioKeysMath.level(of: bands, from: Spectrogram.edge(10), to: Spectrogram.center(10))
        #expect(abs(whole + 20) < 1e-9)
        #expect(abs(half + 20 + 10 * log10(2.0)) < 1e-6)
        #expect(AudioKeysMath.normalized(-30, floor: -50, ceiling: -10) == 0.5)
    }
}
