import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct MatteDrawingTests {
    private func matte(_ mode: MatteMode = .luma, amount: Double = 100) -> Effect {
        var effect = Effect(kind: .matte)
        effect.input = EffectInput(source: .asset(UUID()))
        effect.controls[0].matteMode = mode
        effect.controls[1].number = AnimatedValue(ComponentValue(values: [amount]))
        return effect
    }

    private func shift(_ x: Double) -> Effect {
        var effect = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
        effect.controls[0].number = AnimatedValue(ComponentValue(values: [x, 0]))
        return effect
    }

    private func input(track: CMPersistentTrackID) -> InputDraw {
        .track(
            TrackCopy(trackID: track, range: CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)), strength: 1),
            base: .identity
        )
    }

    /// A red clip with this stack and a matte of white on the left half and
    /// black on the right, opaque.
    private func draw(_ effects: [Effect], matteTrack: (Double, Double) -> SIMD4<Float>) throws -> (CompositorHarness, [SIMD4<Float>]) {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(1, 0, 0, 1))
        try harness.addPicture(track: 2, matteTrack)
        var clip = CompositorHarness.clip(track: 1, effects: effects)
        for effect in effects where effect.kind == .matte { clip.inputs[effect.id] = input(track: 2) }
        return (harness, try harness.draw([clip]))
    }

    private let halves: (Double, Double) -> SIMD4<Float> = { x, _ in x < 0.5 ? SIMD4(1, 1, 1, 1) : SIMD4(0, 0, 0, 1) }

    @Test func aLumaMatteShowsTheClipWhereThePictureIsBright() throws {
        let (harness, frame) = try draw([matte(.luma)], matteTrack: halves)
        #expect(close(harness.pixel(frame, x: 3, y: 4), SIMD4(1, 0, 0, 1)))
        #expect(harness.pixel(frame, x: 12, y: 4).x < 0.02)
    }

    @Test func invertedModesShowItWhereThePictureIsDark() throws {
        let (harness, frame) = try draw([matte(.invertedLuma)], matteTrack: halves)
        #expect(harness.pixel(frame, x: 3, y: 4).x < 0.02)
        #expect(close(harness.pixel(frame, x: 12, y: 4), SIMD4(1, 0, 0, 1)))
    }

    @Test func anAlphaMatteShowsTheClipWhereThePictureIsOpaque() throws {
        let (harness, frame) = try draw([matte(.alpha)], matteTrack: { x, _ in x < 0.5 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 0) })
        // The color of the picture doesn't matter, only whether it is there.
        #expect(close(harness.pixel(frame, x: 3, y: 4), SIMD4(1, 0, 0, 1)))
        #expect(harness.pixel(frame, x: 12, y: 4).x < 0.02)
        let (inverted, flipped) = try draw([matte(.invertedAlpha)], matteTrack: { x, _ in x < 0.5 ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 0) })
        #expect(inverted.pixel(flipped, x: 3, y: 4).x < 0.02)
        #expect(close(inverted.pixel(flipped, x: 12, y: 4), SIMD4(1, 0, 0, 1)))
    }

    @Test func aGrayMatteIsAPartialCut() throws {
        let (harness, frame) = try draw([matte(.luma)], matteTrack: { _, _ in SIMD4(0.5, 0.5, 0.5, 1) })
        #expect(abs(harness.pixel(frame, x: 8, y: 4).x - 0.5) < 0.03)
    }

    @Test func amountMixesTheCutIn() throws {
        let (harness, frame) = try draw([matte(.luma, amount: 50)], matteTrack: halves)
        // Half way between cut and not cut: the dark half shows half.
        #expect(abs(harness.pixel(frame, x: 12, y: 4).x - 0.5) < 0.03)
        #expect(close(harness.pixel(frame, x: 3, y: 4), SIMD4(1, 0, 0, 1)))
        let (off, plain) = try draw([matte(.luma, amount: 0)], matteTrack: halves)
        #expect(close(off.pixel(plain, x: 12, y: 4), SIMD4(1, 0, 0, 1)))
    }

    @Test func aMatteAboveAMoveTravelsWithTheClip() throws {
        // Cut first (the left half), then moved eight pixels right: what is
        // shown is the right half of the frame.
        let (harness, frame) = try draw([matte(.luma), shift(8)], matteTrack: halves)
        #expect(close(harness.pixel(frame, x: 12, y: 4), SIMD4(1, 0, 0, 1)))
        #expect(harness.pixel(frame, x: 3, y: 4).x < 0.02)
    }

    @Test func aMatteBelowAMoveIsFixedInTheFrame() throws {
        // Moved right first, then cut by the left half: nothing of the clip
        // is left there (it now covers only the right half).
        let (harness, frame) = try draw([shift(8), matte(.luma)], matteTrack: halves)
        #expect(harness.pixel(frame, x: 3, y: 4).x < 0.02)
        #expect(harness.pixel(frame, x: 12, y: 4).x < 0.02)
    }

    @Test func aNestedTimelineCanBeTheInput() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(1, 0, 0, 1))
        try harness.addPicture(track: 2, halves)
        var effect = matte(.luma)
        effect.input = EffectInput(source: .timeline(UUID()))
        var clip = CompositorHarness.clip(track: 1, effects: [effect])
        let group = GroupDraw(
            frameSize: CGSize(width: 16, height: 8), toOuter: .identity, passThrough: false,
            children: [CompositorHarness.clip(track: 2)]
        )
        clip.inputs[effect.id] = .group(group)
        let frame = try harness.draw([clip])
        #expect(close(harness.pixel(frame, x: 3, y: 4), SIMD4(1, 0, 0, 1)))
        #expect(harness.pixel(frame, x: 12, y: 4).x < 0.02)
    }

    @Test func withoutAnInputTheClipIsLeftAlone() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(1, 0, 0, 1))
        var effect = Effect(kind: .matte)
        let clip = CompositorHarness.clip(track: 1, effects: [effect])
        let frame = try harness.draw([clip])
        #expect(close(harness.pixel(frame, x: 8, y: 4), SIMD4(1, 0, 0, 1)))
        // Nor when it has one that isn't there to read.
        effect.input = EffectInput(source: .asset(UUID()))
        let missing = try harness.draw([CompositorHarness.clip(track: 1, effects: [effect])])
        #expect(close(harness.pixel(missing, x: 8, y: 4), SIMD4(1, 0, 0, 1)))
    }
}

@Suite struct EffectInputModelTests {
    private func project() -> (EditingProject, UUID, UUID, UUID) {
        var project = EditingProject.empty
        let video = MediaClip(name: "Matte.mov", kind: .video, url: URL(fileURLWithPath: "/dev/null"), duration: CMTime(value: 4, timescale: 1), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let audio = MediaClip(name: "Song.wav", kind: .audio, url: URL(fileURLWithPath: "/dev/null"), duration: CMTime(value: 4, timescale: 1), frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true)
        project.addMedia(video)
        let placed = project.importClip(MediaClip(name: "Clip", kind: .video, url: nil, duration: CMTime(value: 10, timescale: 1), frameRate: 24, colorSpace: .rec709, codecName: "H.264"), intoTimeline: project.rootTimelineID)!
        let effect = project.addEffect(.matte, toClip: placed.clipID, in: project.rootTimelineID)!
        project.addMedia(audio)
        return (project, placed.clipID, effect, video.id)
    }

    @Test func aMatteTakesAVideoAssetOrATimelineAndNothingElse() {
        var (p, clip, effect, video) = project()
        let t = p.rootTimelineID
        let audio = p.clips.first { $0.kind == .audio }!.id
        let accepted1 = p.setInput(EffectInput(source: .asset(audio)), ofEffect: effect, onClip: clip, in: t)
        #expect(!accepted1)
        let accepted2 = p.setInput(EffectInput(source: .asset(UUID())), ofEffect: effect, onClip: clip, in: t)
        #expect(!accepted2)
        let accepted3 = p.setInput(EffectInput(source: .asset(video), offset: CMTime(value: 1, timescale: 1), loops: true), ofEffect: effect, onClip: clip, in: t)
        #expect(accepted3)
        let stored = p.clipAndLayer(clip, in: t)!.clip.effects[0].input
        #expect(stored?.loops == true && stored?.offset == CMTime(value: 1, timescale: 1))
        #expect(p.name(of: stored!) == "Matte.mov" && !p.isMissing(stored!))
        p.setInput(nil, ofEffect: effect, onClip: clip, in: t)
        #expect(p.clipAndLayer(clip, in: t)!.clip.effects[0].input == nil)
        // Effects that take no picture refuse one.
        let transform = p.addEffect(.transform, toClip: clip, in: t)!
        let accepted4 = p.setInput(EffectInput(source: .asset(video)), ofEffect: transform, onClip: clip, in: t)
        #expect(!accepted4)
    }

    @Test func aTimelineCantBeItsOwnInputNorHaveItselfInside() {
        var (p, clip, effect, _) = project()
        let t = p.rootTimelineID
        let inner = p.addTimeline(name: "Inner", frameSize: CGSize(width: 64, height: 36), frameRate: 24, colorSpace: .rec709)
        let media = MediaClip(name: "m", kind: .video, url: nil, duration: CMTime(value: 2, timescale: 1), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        p.importClip(media, intoTimeline: inner)
        let accepted5 = p.setInput(EffectInput(source: .timeline(inner)), ofEffect: effect, onClip: clip, in: t)
        #expect(accepted5)
        let accepted6 = p.setInput(EffectInput(source: .timeline(t)), ofEffect: effect, onClip: clip, in: t)
        #expect(!accepted6)
        // The inner timeline can't use the one that uses it, as an input...
        let innerClip = p.timeline(id: inner)!.layers[0].clips[0]
        let innerEffect = p.addEffect(.matte, toClip: innerClip.id, in: inner)!
        let accepted7 = p.setInput(EffectInput(source: .timeline(t)), ofEffect: innerEffect, onClip: innerClip.id, in: inner)
        #expect(!accepted7)
        // ...nor nest it.
        #expect(!p.canEmbed(t, into: inner))
    }

    @Test func aMissingInputIsReported() {
        var (p, clip, effect, video) = project()
        let t = p.rootTimelineID
        p.setInput(EffectInput(source: .asset(video)), ofEffect: effect, onClip: clip, in: t)
        let input = p.clipAndLayer(clip, in: t)!.clip.effects[0].input!
        p.clips.removeAll { $0.id == video }
        #expect(p.isMissing(input))
        let (c, layer) = p.clipAndLayer(clip, in: t)!
        let note = p.note(forEffectAt: 0, in: c, on: layer, of: p.timeline(id: t)!)
        #expect(note?.dims == true)
    }

    @Test func inputsCountAsUsesOfAnAssetsFootage() {
        var (p, clip, effect, video) = project()
        let t = p.rootTimelineID
        #expect(p.usedRanges(ofMedia: video).isEmpty)
        p.setInput(EffectInput(source: .asset(video), offset: CMTime(value: 1, timescale: 1)), ofEffect: effect, onClip: clip, in: t)
        // From a second in, for as long as the clip lasts, up to the asset's end.
        #expect(p.usedRanges(ofMedia: video) == [CMTimeRange(start: CMTime(value: 1, timescale: 1), end: CMTime(value: 4, timescale: 1))])
    }

    @Test func aMatteWithoutAPictureIsDimmedWithANote() {
        let (p, clip, _, _) = project()
        let t = p.rootTimelineID
        let (c, layer) = p.clipAndLayer(clip, in: t)!
        #expect(c.effects[0].isNoOp)
        #expect(p.note(forEffectAt: 0, in: c, on: layer, of: p.timeline(id: t)!)?.dims == true)
    }
}

/// A matte built from real footage: the input follows the clip's time.
@Suite struct MatteCompositionTests {
    /// A clip of bright footage with a matte on it that is white for the first
    /// second and black for the next one, adjusted by `input`.
    private func fixture(offset: Double = 0, loops: Bool = false) async throws -> (DrawingFixture, ComposedTimeline) {
        var fixture = try DrawingFixture()
        let placed = try await fixture.addClip(luma: 200, frames: 96)
        let url = fixture.directory.appending(path: "matte.mov")
        try await writeMovie(to: url, segments: [(255, 24), (0, 24)])
        let media = MediaClip(
            name: "matte.mov", kind: .video, url: url, duration: CMTime(value: 48, timescale: 24),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        fixture.project.addMedia(media)
        var effect = Effect(kind: .matte)
        effect.controls[0].matteMode = .luma
        effect.input = EffectInput(source: .asset(media.id), offset: CMTime(seconds: offset, preferredTimescale: 24_000), loops: loops)
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.effects = [effect] }
        let built = try await fixture.build()
        return (fixture, built)
    }

    @Test func theInputPlaysFromTheStartOfTheClip() async throws {
        let (fixture, composed) = try await fixture()
        defer { fixture.cleanUp() }
        let white = try await grayLevel(of: composed, at: CMTime(value: 1, timescale: 2))
        let black = try await grayLevel(of: composed, at: CMTime(value: 3, timescale: 2))
        #expect(white > 150)
        #expect(black < 30)
    }

    @Test func anOffsetStartsTheInputLaterInItsFootage() async throws {
        let (fixture, composed) = try await fixture(offset: 1)
        defer { fixture.cleanUp() }
        // The clip starts one second into the matte, which is black by then.
        let first = try await grayLevel(of: composed, at: CMTime(value: 1, timescale: 2))
        #expect(first < 30)
    }

    @Test func afterItsEndTheInputHoldsItsLastFrame() async throws {
        let (fixture, composed) = try await fixture()
        defer { fixture.cleanUp() }
        let held = try await grayLevel(of: composed, at: CMTime(value: 7, timescale: 2))
        #expect(held < 30)
    }

    @Test func aLoopingInputStartsAgain() async throws {
        let (fixture, composed) = try await fixture(loops: true)
        defer { fixture.cleanUp() }
        // Two seconds long, so at 2.5 s it is back at its white first second.
        let again = try await grayLevel(of: composed, at: CMTime(value: 5, timescale: 2))
        #expect(again > 150)
    }
}
