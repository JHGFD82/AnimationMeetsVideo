import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func second(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 24_000) }
private let frame = CMTime(value: 1, timescale: 24)

/// What Time and Shutter do when frames are drawn from synthetic pictures.
@Suite struct TimeAndShutterDrawingTests {
    private let frameSize = CGSize(width: 16, height: 8)

    /// A picture clip on track 1 whose stack comes from `clip`, with the other
    /// tracks of `media` given for blending, echo and trails.
    private func drawClip(_ clip: TimelineClip, media: (inout MediaDraw) -> Void = { _ in }) -> DrawClip {
        var draw = MediaDraw(
            trackID: 1, base: .identity, url: URL(fileURLWithPath: "/dev/null"), sourceStart: .zero, segmentStart: .zero,
            frameDuration: frame
        )
        media(&draw)
        let stack = ClipStack(clip: clip, center: CGPoint(x: 8, y: 4), shift: .zero, frameDuration: frame)
        return DrawClip(content: .media(draw), stack: stack, range: CMTimeRange(start: .zero, duration: second(10)), owner: UUID())
    }

    private func baseClip() -> TimelineClip {
        TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: second(10))
    }

    private func copy(_ track: CMPersistentTrackID, strength: Double = 1, delay: CMTime = .zero) -> TrackCopy {
        TrackCopy(trackID: track, range: CMTimeRange(start: .zero, duration: second(10)), strength: strength, delay: delay)
    }

    @Test func blendMixesTheFrameWithTheNextByHowFarBetweenThemTheMomentIs() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0, 0, 0, 1))
        try harness.addSolid(track: 2, SIMD4(1, 1, 1, 1))
        var clip = baseClip()
        clip.time.speed = AnimatedValue(50)
        clip.time.frameBlending = .blend
        let drawn = drawClip(clip) { $0.nextFrame = copy(2) }
        // At 50%, a quarter second in the clip is an eighth of a second into
        // the source: three frames at 24 fps, exactly on a frame...
        let onFrame = try harness.draw([drawn], at: CMTime(value: 6, timescale: 24))
        #expect(harness.pixel(onFrame, x: 8, y: 4).x < 0.02)
        // ...and one timeline frame later, half way to the next.
        let between = try harness.draw([drawn], at: CMTime(value: 7, timescale: 24))
        #expect(abs(harness.pixel(between, x: 8, y: 4).x - 0.5) < 0.03)
        // A quarter of the way.
        let quarter = try harness.draw([drawn], at: CMTime(value: 13, timescale: 48))
        #expect(abs(harness.pixel(quarter, x: 8, y: 4).x - 0.25) < 0.03)
    }

    /// A smooth texture, `dx` and `dy` pixels along, on a 192 x 108 frame.
    private func texture(_ dx: Double, _ dy: Double) -> (Double, Double) -> SIMD4<Float> {
        { u, v in
            let x = u * 192 - dx, y = v * 108 - dy
            let wave = sin(x * 0.21 + y * 0.07) + sin(y * 0.19 - x * 0.05) + sin((x + y) * 0.11) + sin(x * 0.043) * cos(y * 0.061)
            let value = Float(0.5 + wave * 0.12)
            return SIMD4(value, value, value, 1)
        }
    }

    @Test func opticalFlowMovesTheFramesWhereBlendFadesThem() throws {
        var harness = CompositorHarness(size: CGSize(width: 192, height: 108))
        try harness.addPicture(track: 1, texture(0, 0))
        try harness.addPicture(track: 2, texture(12, 6))
        var truth = CompositorHarness(size: CGSize(width: 192, height: 108))
        try truth.addPicture(track: 1, texture(6, 3))
        let wanted = try truth.draw([CompositorHarness.clip(track: 1)])

        func error(_ mode: FrameBlending, options: DrawingOptions? = nil) throws -> Float {
            var clip = baseClip()
            clip.time.speed = AnimatedValue(50)
            clip.time.frameBlending = mode
            let drawn = drawClip(clip) {
                $0.nextFrame = copy(2)
                $0.opticalFlow = mode == .opticalFlow
            }
            // Half way to the next frame, as above.
            let frame = try harness.draw([drawn], at: CMTime(value: 7, timescale: 24), options: options)
            var total: Float = 0, count: Float = 0
            for y in 30..<78 {
                for x in 40..<150 {
                    total += abs(harness.pixel(frame, x: x, y: y).x - harness.pixel(wanted, x: x, y: y).x)
                    count += 1
                }
            }
            return total / count
        }
        let faded = try error(.blend), moved = try error(.opticalFlow)
        #expect(moved < faded / 2)
        // The viewer asks for no more than a fade while it plays.
        let live = try error(.opticalFlow, options: DrawingOptions())
        #expect(abs(live - faded) < 0.002)
    }

    @Test func opticalFlowMeasuresEachPairOfFramesOnce() throws {
        var harness = CompositorHarness(size: CGSize(width: 192, height: 108))
        try harness.addPicture(track: 1, texture(0, 0))
        try harness.addPicture(track: 2, texture(12, 6))
        var clip = baseClip()
        clip.time.speed = AnimatedValue(50)
        clip.time.frameBlending = .opticalFlow
        let drawn = drawClip(clip) {
            $0.nextFrame = copy(2)
            $0.opticalFlow = true
        }
        let flows = FlowFieldCache()
        // At 50%, both moments fall between the source's fourth and fifth
        // frames: a half and a quarter of the way.
        let half = try harness.draw([drawn], at: CMTime(value: 7, timescale: 24), flows: flows)
        let quarter = try harness.draw([drawn], at: CMTime(value: 13, timescale: 48), flows: flows)
        #expect(flows.measuredCount == 1)
        // What is drawn from the kept motion is what is drawn without it.
        let fresh = try harness.draw([drawn], at: CMTime(value: 13, timescale: 48))
        #expect(zip(quarter, fresh).allSatisfy { close($0, $1, tolerance: 0.002) })
        #expect(half != quarter)

        // Footage with uneven frame timing can put other frames where the
        // count says these are: they are measured, not given this motion.
        try harness.addPicture(track: 2, texture(-12, -6))
        _ = try harness.draw([drawn], at: CMTime(value: 7, timescale: 24), flows: flows)
        #expect(flows.measuredCount == 2)
    }

    @Test func withoutBlendTheNearestFrameShowsAlone() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(0, 0, 0, 1))
        try harness.addSolid(track: 2, SIMD4(1, 1, 1, 1))
        var clip = baseClip()
        clip.time.speed = AnimatedValue(50)
        let frames = try harness.draw([drawClip(clip)], at: CMTime(value: 7, timescale: 24))
        #expect(harness.pixel(frames, x: 8, y: 4).x < 0.02)
    }

    @Test func echoLayersEarlierFramesUnderTheCurrentOne() throws {
        var harness = CompositorHarness()
        // The current picture is half transparent black; the echo is white.
        try harness.addSolid(track: 1, SIMD4(0, 0, 0, 0.5))
        try harness.addSolid(track: 2, SIMD4(1, 1, 1, 1))
        try harness.addSolid(track: 3, SIMD4(1, 0, 0, 1))
        var clip = baseClip()
        clip.time.echo = Echo(count: 2, delay: frame, decay: 0.5)
        let drawn = drawClip(clip) { $0.echoes = [copy(2, strength: 0.5, delay: frame), copy(3, strength: 0.25, delay: CMTimeMultiply(frame, multiplier: 2))] }
        let frameOut = try harness.draw([drawn], at: second(1))
        let pixel = harness.pixel(frameOut, x: 8, y: 4)
        // Black at half strength over white at half strength over red at a
        // quarter, over the black below the root: the echoes show through
        // what the current picture leaves.
        #expect(pixel.x > 0.1 && pixel.y > 0.05 && pixel.x > pixel.y)
        // Without the echoes it is plain dark.
        let plain = try harness.draw([drawClip(baseClip())], at: second(1))
        #expect(harness.pixel(plain, x: 8, y: 4).x < 0.02)
    }

    @Test func motionBlurSmearsAMovingClipAcrossTheShutter() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(1, 1, 1, 1))
        var move = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
        move.controls[0].number.setAnimated(true, at: .zero)
        move.controls[0].number.set(ComponentValue(values: [16, 0]), at: frame)
        var clip = baseClip()
        clip.effects = [move]
        // Half a frame in, the picture is half a frame across: its left edge
        // is at x = 8, sharp.
        let moment = CMTime(value: 1, timescale: 48)
        let sharp = try harness.draw([drawClip(clip)], at: moment)
        let sharpEdge = (0..<16).map { harness.pixel(sharp, x: $0, y: 4).x }
        #expect(sharpEdge.allSatisfy { $0 < 0.05 || $0 > 0.95 })

        clip.shutter.motionBlur = MotionBlur(angle: 360, samples: 16)
        let blurred = try harness.draw([drawClip(clip)], at: moment)
        let blurredEdge = (0..<16).map { harness.pixel(blurred, x: $0, y: 4).x }
        // Across the shutter the edge sweeps eight pixels either side.
        #expect(blurredEdge.contains { $0 > 0.15 && $0 < 0.85 })
        #expect(blurredEdge[0] < 0.1 && blurredEdge[15] > 0.9)
        // And it is a smooth ramp: never goes back down.
        #expect(zip(blurredEdge, blurredEdge.dropFirst()).allSatisfy { $1 >= $0 - 0.02 })
    }

    @Test func aNarrowerShutterBlursLess() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(1, 1, 1, 1))
        var move = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
        move.controls[0].number.setAnimated(true, at: .zero)
        move.controls[0].number.set(ComponentValue(values: [16, 0]), at: frame)
        func width(_ angle: Double) throws -> Int {
            var clip = baseClip()
            clip.effects = [move]
            clip.shutter.motionBlur = MotionBlur(angle: angle, samples: 32)
            let drawn = try harness.draw([drawClip(clip)], at: CMTime(value: 1, timescale: 48))
            return (0..<16).filter { let a = harness.pixel(drawn, x: $0, y: 4).x; return a > 0.05 && a < 0.95 }.count
        }
        let wide = try width(360), narrow = try width(90)
        #expect(wide > narrow)
    }

    @Test func trailsAreCopiesOfTheFinishedClipFromEarlierMoments() throws {
        var harness = CompositorHarness()
        try harness.addSolid(track: 1, SIMD4(1, 1, 1, 1))
        try harness.addSolid(track: 2, SIMD4(1, 1, 1, 1))
        var move = Effect(kind: .transform, controls: [EffectControl(kind: .position)])
        move.controls[0].number.setAnimated(true, at: .zero)
        move.controls[0].number.set(ComponentValue(values: [8, 0]), at: frame)
        var clip = baseClip()
        clip.effects = [move]
        // At one frame in, the picture covers the right half; a frame earlier
        // it was at the left edge.
        var withTrails = clip
        withTrails.shutter.trails = Trails(count: 1, delay: frame, decay: 0.5)
        let plain = try harness.draw([drawClip(clip)], at: frame)
        let trailed = try harness.draw([drawClip(withTrails) { $0.trails = [copy(2, strength: 0.5, delay: frame)] }], at: frame)
        // The left half is empty without trails and half strength with.
        #expect(harness.pixel(plain, x: 2, y: 4).x < 0.05)
        #expect(abs(harness.pixel(trailed, x: 2, y: 4).x - 0.5) < 0.05)
        // The right half is the current picture itself either way.
        #expect(harness.pixel(trailed, x: 12, y: 4).x > 0.95)
    }

    @Test func theViewerDrawsFewerMotionBlurSamplesWhilePlaying() {
        let options = DrawingOptions()
        #expect(options.motionBlurSamples(wanted: 8) == 8)
        options.update(isPlaying: true)
        #expect(options.motionBlurSamples(wanted: 8) == 2)
        #expect(options.motionBlurSamples(wanted: 2) == 2)
        options.update(isQuarterSize: true)
        #expect(options.motionBlurSamples(wanted: 8) == 1)
        options.update(isPlaying: false, isQuarterSize: false)
        #expect(options.motionBlurSamples(wanted: 8) == 8)
        options.update(motionBlurInPreview: false)
        #expect(options.motionBlurSamples(wanted: 8) == 1)
    }

    @Test func playingDrawsAsManyMotionBlurSamplesAsFramesHaveRoomFor() {
        let options = DrawingOptions(), meter = RenderMeter()
        options.update(isPlaying: true)
        #expect(options.motionBlurSamples(wanted: 8) == 2)
        /// `count` playing frames at 24 fps, each drawn in `share` of its time.
        func play(_ count: Int, share: Double) {
            for _ in 0..<count {
                meter.record(renderSeconds: share / 24, frameSeconds: 1.0 / 24)
                options.adapt(to: meter)
            }
        }
        // Light frames raise the budget a sample at a time, settling
        // between steps, up to what the clip asks for and no further.
        play(DrawingOptions.settleFrames, share: 0.1)
        #expect(options.motionBlurSamples(wanted: 8) == 3)
        play(DrawingOptions.settleFrames * 20, share: 0.1)
        #expect(options.motionBlurSamples(wanted: 8) == 8)
        #expect(options.motionBlurSamples(wanted: 16) == 8)
        // Heavy ones halve it.
        play(DrawingOptions.settleFrames * 2, share: 1.5)
        #expect(options.motionBlurSamples(wanted: 8) == 2)
        play(DrawingOptions.settleFrames * 4, share: 1.5)
        #expect(options.motionBlurSamples(wanted: 8) == 1)
        // Paused frames and quarter size are as before.
        options.update(isQuarterSize: true)
        #expect(options.motionBlurSamples(wanted: 8) == 1)
        options.update(isPlaying: false)
        #expect(options.motionBlurSamples(wanted: 8) == 8)
    }

    @Test func onlyPlayingFramesCountTowardTheLoad() throws {
        let meter = RenderMeter()
        meter.record(renderSeconds: 1)
        #expect(meter.load == nil)
        meter.record(renderSeconds: 1.0 / 48, frameSeconds: 1.0 / 24)
        meter.record(renderSeconds: 1.0 / 12, frameSeconds: 1.0 / 24)
        let load = try #require(meter.load)
        #expect(load.frames == 2)
        #expect(abs(load.share - (0.5 + (2 - 0.5) * RenderMeter.loadWeight)) < 1e-9)
        #expect(meter.drain().frames == 3)
    }
}

/// What Time and Shutter do to the composition built from real footage.
@Suite struct TimeAndShutterCompositionTests {
    private func movie(in fixture: inout DrawingFixture, segments: [(luma: UInt8, frames: Int)]) async throws -> (layerID: UUID, clipID: UUID) {
        let url = fixture.directory.appending(path: "m-\(UUID().uuidString).mov")
        try await writeMovie(to: url, segments: segments)
        let frames = segments.reduce(0) { $0 + $1.frames }
        let media = MediaClip(
            name: url.lastPathComponent, kind: .video, url: url, duration: CMTime(value: Int64(frames), timescale: 24),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        let placed = fixture.project.importClip(media, intoTimeline: fixture.timelineID)
        return try #require(placed)
    }

    @Test func halfSpeedPlaysTheSourceInTwiceTheTime() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        // One dark second, then one bright one.
        let placed = try await movie(in: &fixture, segments: [(50, 24), (200, 24)])
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.time.speed = AnimatedValue(50) }
        let clip = try #require(fixture.project.clipAndLayer(placed.clipID, in: fixture.timelineID)?.clip)
        #expect(clip.placedDuration == CMTime(value: 4, timescale: 1))

        let composed = try await fixture.build()
        #expect(abs(composed.composition.duration.seconds - 4) < 0.05)
        let early = try await grayLevel(of: composed, at: CMTime(value: 1, timescale: 1))
        let middleOfDark = try await grayLevel(of: composed, at: CMTime(value: 3, timescale: 2))
        let late = try await grayLevel(of: composed, at: CMTime(value: 3, timescale: 1))
        // The dark second lasts two seconds now.
        #expect(abs(early - middleOfDark) <= 3)
        #expect(late > early + 40)
    }

    @Test func opticalFlowDrawsInExportFromRealFootage() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        // Dark for a second, then bright: between the frames at the cut
        // there is no motion to follow, so the in-between frame is a mix.
        let placed = try await movie(in: &fixture, segments: [(50, 24), (200, 24)])
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) {
            $0.time.speed = AnimatedValue(50)
            $0.time.frameBlending = .opticalFlow
        }
        let composed = try await fixture.build()
        let before = try await grayLevel(of: composed, at: CMTime(value: 3, timescale: 2))
        let after = try await grayLevel(of: composed, at: CMTime(value: 5, timescale: 2))
        #expect(after > before + 40)
        // A moment between frames still draws.
        let between = try await grayLevel(of: composed, at: CMTime(value: 7, timescale: 24))
        #expect(abs(between - before) < 10)
    }

    @Test func doubleSpeedPlaysItInHalfTheTime() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await movie(in: &fixture, segments: [(50, 24), (200, 24)])
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.time.speed = AnimatedValue(200) }
        let composed = try await fixture.build()
        #expect(abs(composed.composition.duration.seconds - 1) < 0.05)
        let first = try await grayLevel(of: composed, at: CMTime(value: 1, timescale: 8))
        let second = try await grayLevel(of: composed, at: CMTime(value: 3, timescale: 4))
        #expect(second > first + 40)
    }

    @Test func aSpeedRampPlaysThroughItsKeyframes() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await movie(in: &fixture, segments: [(50, 24), (200, 24)])
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) {
            $0.time.speed.setAnimated(true, at: .zero)
            $0.time.speed.set(400, at: CMTime(value: 2, timescale: 1))
        }
        let clip = try #require(fixture.project.clipAndLayer(placed.clipID, in: fixture.timelineID)?.clip)
        let placedLength = clip.placedDuration.seconds
        // Faster than steady but slower than a steady 400%.
        #expect(placedLength < 2 && placedLength > 0.5)
        let composed = try await fixture.build()
        #expect(abs(composed.composition.duration.seconds - placedLength) < 0.15)
    }

    @Test func frameBlendingEchoAndTrailsAddTracksOfTheSameFootage() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await movie(in: &fixture, segments: [(100, 48)])
        let before = try await fixture.build().composition.tracks(withMediaType: .video).count
        #expect(before == 1)
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) {
            $0.time.frameBlending = .blend
            $0.time.echo = Echo(count: 3, delay: frame, decay: 0.5)
            $0.shutter.trails = Trails(count: 2, delay: frame, decay: 0.5)
        }
        let composed = try await fixture.build()
        // The clip's own, the next frame's, three echoes and two trails.
        let trackCount = composed.composition.tracks(withMediaType: .video).count
        #expect(trackCount == 7)
        // Stretches where the copies are all there are drawn, and rendered.
        #expect(composed.segments.contains { $0.needsRender })
        let level = try await grayLevel(of: composed, at: CMTime(value: 1, timescale: 1))
        #expect(level > 20)
    }

    @Test func feedbackAddsATrackForEachEarlierMoment() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await movie(in: &fixture, segments: [(100, 48)])
        var feedback = Effect(kind: .feedback)
        if let index = feedback.controls.firstIndex(where: { $0.kind.savedName == "copies" }) {
            feedback.controls[index].number = AnimatedValue(ComponentValue(values: [3]))
        }
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.effects = [feedback] }
        let composed = try await fixture.build()
        // The clip's own and three copies, a frame, two and three earlier.
        let trackCount = composed.composition.tracks(withMediaType: .video).count
        #expect(trackCount == 4)
        #expect(composed.segments.contains { $0.needsRender })
    }

    @Test func motionBlurMakesAStretchRenderAndChangesItsKey() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await movie(in: &fixture, segments: [(100, 48)])
        let plain = try await fixture.build()
        #expect(plain.segments.allSatisfy { !$0.needsRender })
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.shutter.motionBlur = MotionBlur() }
        let blurred = try await fixture.build()
        let renderedSegment = blurred.segments.first { $0.needsRender }
        let rendered = try #require(renderedSegment)
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.shutter.motionBlur = MotionBlur(angle: 90, samples: 8) }
        let narrower = try await fixture.build()
        #expect(narrower.segments.first(where: \.needsRender)?.key != rendered.key)
    }

    @Test func aRetimedClipsRenderKeyFollowsItsSpeed() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let placed = try await movie(in: &fixture, segments: [(100, 48)])
        // Something that makes it render at all: a grade.
        var grade = Effect(kind: .color, controls: [EffectControl(kind: .exposure)])
        grade.controls[0].number = AnimatedValue(ComponentValue(values: [0.5]))
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.effects = [grade] }
        let steady = try await fixture.build().segments.first(where: \.needsRender)?.key
        fixture.project.editClip(placed.clipID, in: fixture.timelineID) { $0.time.speed = AnimatedValue(50) }
        let slow = try await fixture.build().segments.first(where: \.needsRender)?.key
        #expect(steady != nil && slow != nil && steady != slow)
    }
}

/// Sound of retimed clips.
@Suite struct RetimedSoundTests {
    private func tone(in directory: URL) throws -> URL {
        let url = directory.appending(path: "tone-\(UUID().uuidString).wav")
        let rate = 48_000.0
        let samples = [Float](repeating: 0.2, count: Int(rate) * 2)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
        return url
    }

    private func project(sound: SoundMode, speed: Double, in directory: URL) throws -> (EditingProject, UUID) {
        var project = EditingProject.empty
        let media = MediaClip(
            name: "Tone", kind: .audio, url: try tone(in: directory), duration: CMTime(value: 2, timescale: 1),
            frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
        )
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let placed = try #require(imported)
        project.editClip(placed.clipID, in: project.rootTimelineID) {
            $0.time.speed = AnimatedValue(speed)
            $0.time.sound = sound
        }
        return (project, placed.clipID)
    }

    @Test func keepPitchAndChangePitchChooseTheTimePitchAlgorithm() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "amv-sound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (sound, expected) in [(SoundMode.keepPitch, AVAudioTimePitchAlgorithm.spectral), (.changePitch, .varispeed)] {
            let (project, _) = try project(sound: sound, speed: 50, in: directory)
            let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
            #expect(abs(composed.composition.duration.seconds - 4) < 0.05)
            let audioMix = composed.audioMix(curves: MixCurves(MixCurves.of(project)))
            let mix = try #require(audioMix as? AVMutableAudioMix)
            #expect(mix.inputParameters.first?.audioTimePitchAlgorithm == expected)
        }
    }

    @Test func mutePlaysNothingWhileTheSpeedIsntOneHundredPercent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "amv-sound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var (project, clipID) = try project(sound: .mute, speed: 50, in: directory)
        // Nothing left to play: there is no sound track, and no picture.
        await #expect(throws: CompositionError.self) {
            try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        }
        // At its own speed the sound plays, whatever the choice says.
        project.editClip(clipID, in: project.rootTimelineID) { $0.time.speed = AnimatedValue(100) }
        let steady = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        #expect(steady.composition.tracks(withMediaType: .audio).count == 1)
    }
}
