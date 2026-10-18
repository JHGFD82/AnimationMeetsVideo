import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }

/// A 24 fps project with one four-second video clip at the start of the
/// timeline, holding a Transform.
private struct KeyframingFixture {
    var project = EditingProject.empty
    let timelineID: UUID
    let clipID: UUID
    let transformID: UUID

    init() {
        let media = MediaClip(
            name: "A.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264"
        )
        timelineID = project.rootTimelineID
        clipID = project.importClip(media, intoTimeline: timelineID)!.clipID
        let id = clipID
        project.editClip(id, in: timelineID) { $0.trimStart = .zero; $0.trimEnd = seconds(4); $0.startOffset = .zero }
        transformID = project.addEffect(.transform, toClip: clipID, in: timelineID)!
    }

    var clip: TimelineClip { project.clipAndLayer(clipID, in: timelineID)!.clip }
    func effect(_ id: UUID) -> Effect { clip.effect(id: id)! }
    var transform: Effect { effect(transformID) }

    func control(_ kind: ControlKind) -> EffectControl { transform.control(kind)! }
    func target(_ kind: ControlKind) -> KeyframingTarget { .control(effectID: transformID, controlID: control(kind).id) }

    /// The first component of a Transform control at `time` seconds.
    func value(_ kind: ControlKind, at time: Double, component: Int = 0) -> Double {
        control(kind).values(at: seconds(time))[component]
    }

    mutating func add(_ kind: EffectKind) -> UUID {
        project.addEffect(kind, toClip: clipID, in: timelineID)!
    }

    mutating func edit(_ id: UUID, _ change: (inout Effect) -> Void) {
        project.editEffect(id, ofClip: clipID, in: timelineID, change)
    }

    mutating func set(_ id: UUID, _ kind: ControlKind, to value: Double) {
        edit(id) { effect in
            guard let c = effect.controls.firstIndex(where: { $0.kind == kind }) else { return }
            effect.controls[c].setComponent(0, to: value, at: .zero)
        }
    }

    mutating func choose(_ id: UUID, _ kind: ControlKind, _ option: String) {
        edit(id) { effect in
            guard let c = effect.controls.firstIndex(where: { $0.kind == kind }) else { return }
            effect.controls[c].choice = option
        }
    }

    mutating func point(_ id: UUID, at kind: ControlKind, component: Int? = nil, combine: KeyframingCombine = .add) {
        let target = target(kind)
        edit(id) {
            $0.keyframing?.target = target
            $0.keyframing?.component = component
            $0.keyframing?.combine = combine
        }
    }

    /// Keyframes a Transform control's x (and y 0) by hand.
    mutating func keyframe(_ kind: ControlKind, _ points: [(Double, Double)]) {
        let transformID = transformID
        project.editClip(clipID, in: timelineID) { clip in
            guard let e = clip.effects.index(of: transformID),
                  let c = clip.effects[e].controls.firstIndex(where: { $0.kind == kind })
            else { return }
            let width = kind.defaultValues.count
            clip.effects[e].controls[c].number = AnimatedValue(
                ComponentValue(values: kind.defaultValues),
                keyframes: points.map { time, x in
                    Keyframe(time: seconds(time), value: ComponentValue(values: [x] + Array(repeating: 0, count: width - 1)))
                }
            )
        }
    }
}

@Suite struct KeyframingTests {
    @Test func aNewKeyframingEffectGoesOnTopAndWritesToTheFirstControlBelow() {
        var f = KeyframingFixture()
        let id = f.add(.oscillator)
        #expect(f.clip.effects.map(\.kind) == [.oscillator, .transform])
        #expect(f.effect(id).keyframing?.target == f.target(.position))
        #expect(f.control(.position).isAnimated)
        // It draws nothing itself.
        #expect(f.effect(id).isNoOp)
    }

    @Test func aSecondOneWritesToTheNextControlNoneWritesTo() {
        var f = KeyframingFixture()
        let first = f.add(.wiggler)
        let second = f.add(.oscillator)
        #expect(f.effect(first).keyframing?.target == f.target(.position))
        #expect(f.effect(second).keyframing?.target == f.target(.scale))
        #expect(f.control(.position).number.keyframes.allSatisfy { $0.generatedBy == first })
    }

    @Test func anOscillatorWritesASineWave() {
        var f = KeyframingFixture()
        let id = f.add(.oscillator)
        f.point(id, at: .rotation)
        #expect(abs(f.value(.rotation, at: 0.25) - 10) < 0.15)
        #expect(abs(f.value(.rotation, at: 0.5)) < 0.15)
        #expect(abs(f.value(.rotation, at: 0.75) + 10) < 0.15)
        let keyframes = f.control(.rotation).number.keyframes
        #expect(keyframes.allSatisfy { $0.generatedBy == id })
        // Fewer than the clip's 97 frames.
        #expect(keyframes.count < 97)
    }

    @Test func addRidesOnTheHandMadeMoveAndKeepsItsBase() {
        var f = KeyframingFixture()
        f.keyframe(.position, [(0, 0), (4, 100)])
        let id = f.add(.oscillator)
        f.point(id, at: .position, component: 0)
        let first = f.control(.position).number
        // Within the 0.5% tolerance of the curve's 100 px spread.
        #expect(abs(f.value(.position, at: 0.25) - 16.25) < 0.6)
        #expect(abs(f.value(.position, at: 1) - 25) < 0.6)
        // y is left alone.
        #expect(f.value(.position, at: 0.25, component: 1) == 0)
        // Made again from the original, not from the last result.
        f.set(id, .amplitude, to: 20)
        f.set(id, .amplitude, to: 10)
        #expect(f.control(.position).number == first)
    }

    @Test func multiplyScalesWhatIsThere() {
        var f = KeyframingFixture()
        let id = f.add(.oscillator)
        f.point(id, at: .scale, combine: .multiply)
        f.set(id, .amplitude, to: 30)
        #expect(abs(f.value(.scale, at: 0.25) - 130) < 0.5)
        #expect(abs(f.value(.scale, at: 0.75) - 70) < 0.5)
    }

    @Test func theSameSeedWigglesTheSameWay() {
        var f = KeyframingFixture()
        let id = f.add(.wiggler)
        let first = f.control(.position).number
        f.set(id, .seed, to: 2)
        let second = f.control(.position).number
        f.set(id, .seed, to: 1)
        #expect(second != first)
        #expect(f.control(.position).number == first)
        // Independent: x and y move apart.
        #expect(f.value(.position, at: 1.3) != f.value(.position, at: 1.3, component: 1))
    }

    @Test func aTargetMovedAboveTheEffectKeepsItsKeyframes() {
        var f = KeyframingFixture()
        let id = f.add(.oscillator)
        f.point(id, at: .rotation)
        let made = f.control(.rotation).number
        f.project.moveEffect(id, ofClip: f.clipID, in: f.timelineID, toIndex: 1)
        #expect(!f.project.keyframingTargetIsReachable(f.effect(id), in: f.clip))
        f.set(id, .amplitude, to: 40)
        #expect(f.control(.rotation).number == made)
    }

    @Test func deletingTheEffectPutsTheTargetBack() {
        var f = KeyframingFixture()
        let id = f.add(.wiggler)
        #expect(f.control(.position).isAnimated)
        f.project.removeEffect(id, fromClip: f.clipID, in: f.timelineID)
        #expect(!f.control(.position).isAnimated)
        #expect(f.control(.position).number.value == ComponentValue(values: [0, 0]))
    }

    @Test func bakingLeavesPlainKeyframes() {
        var f = KeyframingFixture()
        let id = f.add(.wiggler)
        let made = f.control(.position).number.keyframes
        f.project.bakeKeyframing(id, ofClip: f.clipID, in: f.timelineID)
        #expect(f.clip.effects.map(\.kind) == [.transform])
        let baked = f.control(.position).number.keyframes
        #expect(baked.map(\.time) == made.map(\.time))
        #expect(baked.allSatisfy { $0.generatedBy == nil })
    }

    @Test func pointingElsewhereLeavesTheOldTargetsKeyframesPlain() {
        var f = KeyframingFixture()
        let id = f.add(.wiggler)
        f.point(id, at: .rotation)
        let position = f.control(.position).number
        #expect(position.isAnimated && position.keyframes.allSatisfy { $0.generatedBy == nil })
        #expect(f.control(.rotation).number.keyframes.allSatisfy { $0.generatedBy == id })
    }

    @Test func timeStepHoldsEachValue() {
        var f = KeyframingFixture()
        // One pixel a frame.
        f.keyframe(.position, [(0, 0), (4, 96)])
        let id = f.add(.timeStep)
        f.point(id, at: .position, component: 0)
        let frame = 1.0 / 24
        #expect(abs(f.value(.position, at: frame)) < 1e-6)
        #expect(abs(f.value(.position, at: 2 * frame) - 2) < 1e-6)
        #expect(abs(f.value(.position, at: 3 * frame) - 2) < 1e-6)
        f.set(id, .hold, to: 4)
        #expect(abs(f.value(.position, at: 7 * frame) - 4) < 1e-6)
    }

    @Test func looperCarriesTheKeyframesOnInEachMode() {
        var f = KeyframingFixture()
        f.keyframe(.position, [(0, 0), (1, 10)])
        let id = f.add(.looper)
        f.point(id, at: .position, component: 0)
        #expect(abs(f.value(.position, at: 1.5) - 5) < 0.1)
        f.choose(id, .loopMode, LoopMode.pingPong.rawValue)
        #expect(abs(f.value(.position, at: 1.25) - 7.5) < 0.1)
        f.choose(id, .loopMode, LoopMode.offset.rawValue)
        #expect(abs(f.value(.position, at: 1.5) - 15) < 0.1)
        f.choose(id, .loopMode, LoopMode.continue.rawValue)
        #expect(abs(f.value(.position, at: 2) - 20) < 0.1)
    }

    @Test func smootherSoftensAJump() {
        var f = KeyframingFixture()
        let frame = 1.0 / 24
        f.keyframe(.position, [(0, 0), (1 - frame, 0), (1, 100), (4, 100)])
        let id = f.add(.smoother)
        f.point(id, at: .position, component: 0)
        // Five frames centered on the jump: 0, 0, 100, 100, 100.
        #expect(abs(f.value(.position, at: 1) - 60) < 0.5)
        #expect(abs(f.value(.position, at: 0.5)) < 0.5)
    }

    @Test func overshootSwingsPastTheKeyframeAndSettles() {
        var f = KeyframingFixture()
        f.keyframe(.position, [(0, 0), (1, 100)])
        let id = f.add(.overshoot)
        f.point(id, at: .position, component: 0)
        let after = stride(from: 1.0, through: 2, by: 1.0 / 24).map { f.value(.position, at: $0) }
        #expect((after.max() ?? 0) > 102)
        #expect(abs(f.value(.position, at: 3.9) - 100) < 1)
        // Untouched before the keyframe it bounces from.
        #expect(abs(f.value(.position, at: 0.5) - 50) < 0.5)
    }

    @Test func aDuplicateWaitsForATargetOfItsOwn() {
        var f = KeyframingFixture()
        let id = f.add(.wiggler)
        let copy = f.project.duplicateEffect(id, ofClip: f.clipID, in: f.timelineID)!
        #expect(f.effect(copy).keyframing?.target == nil)
    }

    @Test func pastingFollowsTheTargetThatCameAlong() throws {
        var f = KeyframingFixture()
        _ = f.add(.wiggler)
        let media = MediaClip(
            name: "B.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
            colorSpace: .rec709, codecName: "H.264"
        )
        let other = f.project.importClip(media, intoTimeline: f.timelineID)!.clipID
        f.project.editClip(other, in: f.timelineID) { $0.trimStart = .zero; $0.trimEnd = seconds(4) }
        let bundle = try #require(f.project.bundle(ofEffects: nil, fromClip: f.clipID, in: f.timelineID))
        f.project.paste(bundle, ontoClip: other, in: f.timelineID)
        let pasted = try #require(f.project.clipAndLayer(other, in: f.timelineID)?.clip)
        let wiggler = pasted.effects[0], transform = pasted.effects[1]
        let position = try #require(transform.control(.position))
        #expect(wiggler.keyframing?.target == .control(effectID: transform.id, controlID: position.id))
        #expect(position.number.isAnimated && position.number.keyframes.allSatisfy { $0.generatedBy == wiggler.id })
    }
}

/// Beat Keys on a song whose beat map has a beat every half second, four to
/// a measure, on a Music layer of the same timeline.
@Suite struct BeatKeysTests {
    private func fixture() -> (KeyframingFixture, layerID: UUID) {
        var f = KeyframingFixture()
        var song = MediaClip(
            name: "Song.wav", kind: .audio, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
            colorSpace: .rec709, codecName: "PCM"
        )
        song.hasAudio = true
        let beats = (1...30).map { MappedBeat(time: seconds(Double($0) * 0.5), position: ($0 - 1) % 4 + 1) }
        song.beatMap = BeatMap(sections: [BeatSection(kind: .consistent, start: .zero, end: seconds(20), isConfirmed: true, beats: beats)])
        f.project.clips.append(song)
        f.project.putOnMusicLayer([song.id])
        let layerID = f.project.timeline(id: f.timelineID)!.layers.last!.id
        return (f, layerID)
    }

    @Test func pulsesLandOnTheBeatsWithTheAccentOnTheOne() {
        var (f, layerID) = fixture()
        let id = f.add(.beatKeys)
        f.point(id, at: .rotation)
        f.edit(id) { $0.keyframing?.beatLayer = layerID }
        // The beat at 0.5 s is a downbeat; the one at 1 s isn't.
        #expect(abs(f.value(.rotation, at: 0.5) - 15) < 0.1)
        #expect(abs(f.value(.rotation, at: 1) - 10) < 0.1)
        // Gone by the next beat.
        #expect(abs(f.value(.rotation, at: 0.5 + 0.25 + 1.0 / 24)) < 0.1)
        let times = Set(f.control(.rotation).number.keyframes.map(\.time.seconds))
        #expect([0.5, 1.0, 1.5, 2.0].allSatisfy { times.contains($0) })
    }

    @Test func everyOtherDownbeatSkipsTheRest() {
        var (f, layerID) = fixture()
        let id = f.add(.beatKeys)
        f.point(id, at: .rotation)
        f.edit(id) { $0.keyframing?.beatLayer = layerID }
        f.choose(id, .beatSelection, BeatSelection.downbeats.rawValue)
        // Downbeats at 0.5, 2.5, 4.5 ...; every second one from the first.
        f.set(id, .everyBeats, to: 2)
        #expect(abs(f.value(.rotation, at: 0.5) - 10) < 0.1)
        #expect(abs(f.value(.rotation, at: 2.5)) < 0.1)
        #expect(abs(f.value(.rotation, at: 1)) < 0.1)
    }

    @Test func aClipAtHalfSpeedGetsItsPulsesOnTheBeatsAsHeard() {
        var (f, layerID) = fixture()
        f.project.editClip(f.clipID, in: f.timelineID) { $0.time.speed = AnimatedValue(50) }
        let id = f.add(.beatKeys)
        f.point(id, at: .rotation)
        f.edit(id) { $0.keyframing?.beatLayer = layerID }
        // The beat at 1 s of the timeline plays source 0.5 s.
        #expect(abs(f.value(.rotation, at: 0.5) - 10) < 0.1)
        #expect(abs(f.value(.rotation, at: 0.25) - 15) < 0.1)
    }
}
