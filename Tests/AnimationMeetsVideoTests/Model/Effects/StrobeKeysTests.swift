import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }

private let frame = 1.0 / 24

/// Strobe Keys' arithmetic, away from any project: where pulses fall,
/// their corners, and how they are varied.
@Suite struct StrobeKeysMathTests {
    @Test func framePulsesComeEveryNFramesUpToOnePastTheEnd() {
        let pulses = StrobeKeys.framePulses(every: 12, shift: 0, frame: frame, duration: 2)
        #expect(pulses.map(\.time) == [0, 0.5, 1, 1.5, 2, 2.5])
        #expect(pulses.allSatisfy { abs($0.interval - 0.5) < 1e-9 })
        let shifted = StrobeKeys.framePulses(every: 12, shift: -3, frame: frame, duration: 1)
        #expect(abs(shifted[0].time + 0.125) < 1e-9)
    }

    @Test func divisionsOfABeatFollowATempoRamp() {
        // Beats a second apart, then half a second: the halves between them
        // follow, and past the last beat they keep its spacing.
        let pulses = StrobeKeys.beatPulses(
            [0, 1, 1.5, 2], downbeats: [true, false, false, false], first: 0, every: 1, parts: 2, shift: 0, duration: 1.8
        )
        let times = pulses.map(\.time)
        #expect(zip(times, [0, 0.5, 1, 1.25, 1.5, 1.75, 2]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(pulses.count == 7)
        #expect(pulses[0].isDownbeat && !pulses[1].isDownbeat)
    }

    @Test func aBeatOffsetMovesEveryPulseByBeats() {
        let pulses = StrobeKeys.beatPulses([0, 0.5, 1, 1.5], downbeats: [], first: 0, every: 1, parts: 1, shift: 0.5, duration: 1.2)
        #expect(pulses.map(\.time).prefix(3).elementsEqual([0.25, 0.75, 1.25]) { abs($0 - $1) < 1e-9 })
    }

    @Test func aRateThatChangesIsIntegrated() {
        // One a second for a second, then two a second.
        let elapsed = (0...48).map { Double($0) * frame }
        var cycles = 0.0
        let integrated = elapsed.indices.map { k -> Double in
            if k > 0 { cycles += (elapsed[k - 1] < 1 ? 1 : 2) * frame }
            return cycles
        }
        let pulses = StrobeKeys.ratePulses(cycles: integrated, elapsed: elapsed, lastRate: 2, shift: 0, duration: 2)
        #expect(pulses.map(\.time).elementsEqual([0, 1, 1.5, 2, 2.5]) { abs($0 - $1) < 1e-6 })
    }

    @Test func aDutyCycleHoldsAndJumpsOnFrames() {
        let envelope = StrobeKeys.Envelope(times: .share, attack: 0, decay: 0, sustainFor: 0.5, release: 0)
        let pulses = StrobeKeys.framePulses(every: 12, shift: 0, frame: frame, duration: 1)
        let nodes = StrobeKeys.nodes(pulses, envelope: envelope, frame: frame)
        func level(_ at: Double) -> Double { StrobeKeys.level(at: at, of: nodes) }
        #expect(level(0) == 1 && level(3) == 1 && level(5) == 1 && level(5.5) == 1)
        #expect(level(6) == 0 && level(11) == 0 && level(11.9) == 0)
        #expect(level(12) == 1)
        // Each jump is a hold the frame before it.
        #expect(nodes.contains(StrobeKeys.Node(frame: 5, level: 1, leaving: .hold)))
        #expect(nodes.contains(StrobeKeys.Node(frame: 11, level: 0, leaving: .hold)))
    }

    @Test func retriggerStartsFromWhereTheLastPulseHadReached() {
        // A 30-frame release, cut every 12 frames by the next pulse's
        // 6-frame attack: at frame 12 the last is at 80%.
        var envelope = StrobeKeys.Envelope(
            times: .frames, attack: 6, decay: 0, sustainFor: 0, release: 30, attackCurve: .linear, releaseCurve: .linear
        )
        let pulses = StrobeKeys.framePulses(every: 12, shift: 0, frame: frame, duration: 1)
        let cut = StrobeKeys.nodes(pulses, envelope: envelope, frame: frame)
        #expect(abs(StrobeKeys.level(at: 11, of: cut) - (1 - 5.0 / 30)) < 1e-9)
        #expect(abs(StrobeKeys.level(at: 15, of: cut) - 0.5) < 1e-9)
        envelope.overlap = .retrigger
        let retriggered = StrobeKeys.nodes(pulses, envelope: envelope, frame: frame)
        #expect(abs(StrobeKeys.level(at: 12, of: retriggered) - 0.8) < 1e-9)
        #expect(abs(StrobeKeys.level(at: 15, of: retriggered) - 0.9) < 1e-9)
    }

    @Test func decaySettlesOnTheSustainLevel() {
        let envelope = StrobeKeys.Envelope(
            times: .frames, attack: 0, decay: 4, sustainFor: 4, release: 0, sustain: 0.5, decayCurve: .linear
        )
        let pulses = StrobeKeys.framePulses(every: 24, shift: 0, frame: frame, duration: 1)
        let nodes = StrobeKeys.nodes(pulses, envelope: envelope, frame: frame)
        #expect(StrobeKeys.level(at: 0, of: nodes) == 1)
        #expect(abs(StrobeKeys.level(at: 2, of: nodes) - 0.75) < 1e-9)
        #expect(StrobeKeys.level(at: 6, of: nodes) == 0.5)
        #expect(StrobeKeys.level(at: 8, of: nodes) == 0)
    }

    @Test func curvesStartAndEndWhereTheyShould() {
        for curve in StrobeCurve.allCases {
            #expect(StrobeKeys.shape(curve, 0) == 0)
            #expect(abs(StrobeKeys.shape(curve, 1) - 1) < 1e-12)
        }
        // An exponential release has done most of its fall a fifth of the
        // way through.
        #expect(StrobeKeys.shape(.exponential, 0.2) > 0.6)
    }

    @Test func aPatternTurnsStepsOffAndAccentsOthers() {
        let pulses = StrobeKeys.framePulses(every: 1, shift: 0, frame: frame, duration: 1)
        var variation = StrobeKeys.Variation()
        variation.pattern = StrobeStep.steps(of: "x.X. ")
        #expect(variation.pattern == [.on, .off, .accent, .off])
        let varied = StrobeKeys.varied(pulses, by: variation, duration: 1)
        #expect(varied.allSatisfy { $0.index % 2 == 0 })
        #expect(varied.first { $0.index == 2 }?.height == 1.5)
        #expect(varied.first { $0.index == 4 }?.height == 1)
    }

    @Test func theSameSeedSkipsTheSamePulses() {
        let pulses = StrobeKeys.framePulses(every: 1, shift: 0, frame: frame, duration: 10)
        var variation = StrobeKeys.Variation()
        variation.skipChance = { _ in 0.5 }
        variation.seed = 7
        let once = StrobeKeys.varied(pulses, by: variation, duration: 10).map(\.index)
        let again = StrobeKeys.varied(pulses, by: variation, duration: 10).map(\.index)
        variation.seed = 8
        let other = StrobeKeys.varied(pulses, by: variation, duration: 10).map(\.index)
        #expect(once == again)
        #expect(once != other)
        #expect(once.count > pulses.count / 4 && once.count < pulses.count * 3 / 4)
    }

    @Test func swingMakesEveryOtherPulseLate() {
        let pulses = StrobeKeys.framePulses(every: 12, shift: 0, frame: frame, duration: 2)
        var variation = StrobeKeys.Variation()
        variation.swing = { _ in 0.5 }
        let varied = StrobeKeys.varied(pulses, by: variation, duration: 2)
        #expect(varied.map(\.time).prefix(4).elementsEqual([0, 0.75, 1, 1.75]) { abs($0 - $1) < 1e-9 })
    }

    @Test func flashingCountsPulsesInAnySecond() {
        func pulses(_ times: [Double]) -> [StrobeKeys.Pulse] {
            times.enumerated().map { StrobeKeys.Pulse(time: $1, interval: 0.25, height: 1, index: $0, step: $0) }
        }
        #expect(!StrobeKeys.flashesTooFast(pulses([0, 0.5, 1, 1.5, 2])))
        #expect(!StrobeKeys.flashesTooFast(pulses([0, 0.3, 0.6, 1.2])))
        #expect(StrobeKeys.flashesTooFast(pulses([0, 0.3, 0.6, 0.9])))
    }
}

/// Strobe Keys in a project: on a 24 fps clip four seconds long holding a
/// Transform, picked in the Keyframe Designer.
@MainActor @Suite struct StrobeKeysTests {
    private struct Fixture {
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
        var timeline: Timeline { project.timeline(id: timelineID)! }
        var transform: Effect { clip.effect(id: transformID)! }
        func target(_ kind: ControlKind) -> KeyframingTarget {
            .control(effectID: transformID, controlID: transform.control(kind)!.id)
        }
        func value(_ kind: ControlKind, atFrame frame: Double) -> Double {
            transform.control(kind)!.values(at: seconds(frame / 24))[0]
        }
        func strobe(_ id: UUID) -> Effect { clip.effect(id: id)! }

        mutating func drive(_ kind: ControlKind) -> UUID {
            project.setKeyframing(.strobeKeys, driving: target(kind), onClip: clipID, in: timelineID)!
        }

        mutating func edit(_ id: UUID, _ change: (inout Effect) -> Void) {
            project.editEffect(id, ofClip: clipID, in: timelineID, change)
        }

        mutating func set(_ id: UUID, _ kind: ControlKind, to value: Double) {
            edit(id) { $0.changeControl(kind) { $0.setComponent(0, to: value, at: .zero) } }
        }

        mutating func choose(_ id: UUID, _ kind: ControlKind, _ option: String) {
            edit(id) { $0.changeControl(kind) { $0.choice = option } }
        }

        /// A song on a Music layer whose beat map has a beat every half
        /// second from 0.5 s, four to a measure, the first a downbeat.
        mutating func addSong() {
            var song = MediaClip(
                name: "Song.wav", kind: .audio, url: URL(fileURLWithPath: "/dev/null"), duration: seconds(20), frameRate: 24,
                colorSpace: .rec709, codecName: "PCM"
            )
            song.hasAudio = true
            let beats = (1...30).map { MappedBeat(time: seconds(Double($0) * 0.5), position: ($0 - 1) % 4 + 1) }
            song.beatMap = BeatMap(sections: [BeatSection(kind: .consistent, start: .zero, end: seconds(20), isConfirmed: true, beats: beats)])
            project.clips.append(song)
            project.putOnMusicLayer([song.id])
        }
    }

    @Test func overAnOpacityItMultipliesFromNoneToAll() {
        var f = Fixture()
        let id = f.drive(.opacity)
        #expect(f.strobe(id).keyframing?.combine == .multiply)
        #expect(f.strobe(id).control(.strobeLevels)?.number.value.values == [0, 1])
        let rotation = f.drive(.rotation)
        #expect(f.strobe(rotation).keyframing?.combine == .add)
        #expect(f.strobe(rotation).control(.strobeLevels)?.number.value.values == [0, 10])
    }

    @Test func aDutyCycleBlinksTheOpacityOnFrames() {
        var f = Fixture()
        let id = f.drive(.opacity)
        f.choose(id, .strobeTiming, StrobeTiming.frames.rawValue)
        f.edit(id) { $0.applyStrobeDuty() }
        // On for six frames of every twelve, held, not ramping between.
        #expect(f.value(.opacity, atFrame: 0) == 100)
        #expect(f.value(.opacity, atFrame: 5) == 100)
        #expect(f.value(.opacity, atFrame: 5.5) == 100)
        #expect(f.value(.opacity, atFrame: 6) == 0)
        #expect(f.value(.opacity, atFrame: 11.5) == 0)
        #expect(f.value(.opacity, atFrame: 12) == 100)
        let keyframes = f.transform.control(.opacity)!.number.keyframes
        #expect(keyframes.contains { $0.hold && $0.generatedBy == id })
        // A corner a frame, not a keyframe every frame.
        #expect(keyframes.count < 4 * 24 / 2)
    }

    @Test func swappingDipsInsteadOfRising() {
        var f = Fixture()
        let id = f.drive(.opacity)
        f.choose(id, .strobeTiming, StrobeTiming.frames.rawValue)
        f.edit(id) { $0.applyStrobeDuty() }
        f.edit(id) { $0.swapStrobeLevels() }
        #expect(f.strobe(id).control(.strobeLevels)?.number.value.values == [1, 0])
        #expect(f.value(.opacity, atFrame: 2) == 0)
        #expect(f.value(.opacity, atFrame: 8) == 100)
    }

    @Test func changingCombineMovesDefaultLevelsAlong() {
        var f = Fixture()
        let id = f.drive(.opacity)
        f.edit(id) { $0.setStrobeCombine(.add) }
        #expect(f.strobe(id).control(.strobeLevels)?.number.value.values == [0, 10])
        // Levels set by hand stay.
        f.edit(id) { $0.changeControl(.strobeLevels) { $0.setComponent(1, to: 30, at: .zero) } }
        f.edit(id) { $0.setStrobeCombine(.replace) }
        #expect(f.strobe(id).keyframing?.combine == .replace)
        #expect(f.strobe(id).control(.strobeLevels)?.number.value.values == [0, 30])
    }

    @Test func itFollowsBeatsWhereThereAreSome() {
        var f = Fixture()
        f.addSong()
        let id = f.drive(.rotation)
        #expect(f.strobe(id).choice(.strobeTiming, as: StrobeTiming.self) == .beats)
        #expect(f.strobe(id).keyframing?.beatLayer != nil)
        f.choose(id, .beatDivision, BeatDivision.half.rawValue)
        // Nothing before the first beat; the downbeat at 0.5 s accented, the
        // half beat after it not.
        #expect(abs(f.value(.rotation, atFrame: 6)) < 1e-6)
        #expect(abs(f.value(.rotation, atFrame: 12) - 15) < 1e-6)
        #expect(abs(f.value(.rotation, atFrame: 18) - 10) < 1e-6)
        // The beats are what it reads.
        #expect(f.project.keyframingFreshness(of: f.strobe(id), in: f.clip, of: f.timeline) == .current)
    }

    @Test func itWarnsOnlyWhenItFlashesTooFast() {
        var f = Fixture()
        let id = f.drive(.opacity)
        #expect(f.project.strobeFlashingNote(for: f.strobe(id), in: f.clip, of: f.timeline) == nil)
        f.set(id, .strobeRate, to: 4)
        #expect(f.project.strobeFlashingNote(for: f.strobe(id), in: f.clip, of: f.timeline) != nil)
        // A rotation doesn't change the picture's brightness.
        let rotation = f.drive(.rotation)
        f.set(rotation, .strobeRate, to: 4)
        #expect(f.project.strobeFlashingNote(for: f.strobe(rotation), in: f.clip, of: f.timeline) == nil)
    }

    @Test func theDesignerShowsTheSettingsOfItsTiming() {
        var f = Fixture()
        let id = f.drive(.rotation)
        var strobe = f.strobe(id)
        #expect(strobe.designerShows(.strobeRate) && !strobe.designerShows(.strobeFrames) && !strobe.designerShows(.beatDivision))
        #expect(strobe.designerShows(.attackShare) && !strobe.designerShows(.attackFrames))
        #expect(!strobe.designerShows(.accent))
        strobe.keyframing?.pattern = "x.X."
        #expect(strobe.designerShows(.accent))
        f.choose(id, .strobeTiming, StrobeTiming.beats.rawValue)
        f.choose(id, .strobeTimes, StrobeTimes.frames.rawValue)
        strobe = f.strobe(id)
        #expect(strobe.designerShows(.beatDivision) && !strobe.designerShows(.strobeRate) && !strobe.designerShows(.frameShift))
        #expect(strobe.designerShows(.releaseFrames) && !strobe.designerShows(.releaseShare))
    }

    @Test func aRateThatIsntWholeFramesFallsBetweenThem() {
        var f = Fixture()
        let id = f.drive(.rotation)
        #expect(!f.strobe(id).strobeFallsBetweenFrames(frame: frame))
        f.set(id, .strobeRate, to: 5)
        #expect(f.strobe(id).strobeFallsBetweenFrames(frame: frame))
    }

    @Test func thePatternIsASettingThatMakesTheKeyframesAgain() {
        var f = Fixture()
        let id = f.drive(.rotation)
        f.choose(id, .strobeTiming, StrobeTiming.frames.rawValue)
        // Every 12 frames; the second pulse turned off.
        #expect(abs(f.value(.rotation, atFrame: 12) - 10) < 1e-6)
        f.edit(id) { $0.keyframing?.pattern = "x." }
        #expect(abs(f.value(.rotation, atFrame: 12)) < 1e-6)
        #expect(abs(f.value(.rotation, atFrame: 24) - 10) < 1e-6)
    }
}
