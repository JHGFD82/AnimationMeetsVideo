import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The Waveform effect (see docs/waveform-effect.md), drawing a song
/// whose samples are handed to `WaveformAudio` rather than read from a
/// file: four seconds of a full-scale 1 kHz sine on the left, silence on
/// the right, on a Music layer of a 1280 by 720 timeline.
@Suite(.serialized) struct WaveformTests {
    private let frame = CGSize(width: 1280, height: 720)
    private var center: CGPoint { CGPoint(x: frame.width / 2, y: frame.height / 2) }

    private struct Fixture {
        var project = EditingProject.empty
        let songID: UUID
        let waveID: UUID
        let clipID: UUID
        let url: URL

        init(frame: CGSize) throws {
            project.timelines[0].frameSize = frame
            url = URL(fileURLWithPath: "/dev/null/amv-waveform-\(UUID().uuidString).wav")
            var song = MediaClip(
                name: "Tone.wav", kind: .audio, url: url, duration: CMTime(seconds: 4, preferredTimescale: 600), frameRate: 24,
                colorSpace: .rec709, codecName: "PCM"
            )
            song.hasAudio = true
            songID = song.id
            project.clips.append(song)
            project.putOnMusicLayer([song.id])
            let made = project.addShapeLayer(.waveform, to: project.rootTimelineID, duration: CMTime(seconds: 4, preferredTimescale: 600))
            let placed = try #require(made)
            clipID = placed.clipID
            waveID = try #require(project.clipAndLayer(placed.clipID, in: project.rootTimelineID)?.clip.effects.first?.id)
            WaveformAudio.shared.store(WaveformAudio.Samples(channels: [Self.tone, [Int16](repeating: 0, count: Self.tone.count)]), for: url)
        }

        /// The full-scale 1 kHz sine, four seconds of it.
        static let tone: [Int16] = {
            let rate = WaveformAudio.Samples.rate
            return (0..<Int(rate * 4)).map { Int16((sin(2 * .pi * 1000 * Double($0) / rate) * 32_767).rounded()) }
        }()

        /// The tone in the right channel too, for a mix at full scale:
        /// Mixed is both channels' average, so the left alone is half.
        func toneInBothChannels() {
            WaveformAudio.shared.store(WaveformAudio.Samples(channels: [Self.tone, Self.tone]), for: url)
        }

        var timeline: Timeline { project.timeline(id: project.rootTimelineID)! }
        var clip: TimelineClip { project.clipAndLayer(clipID, in: project.rootTimelineID)!.clip }
        var effect: Effect { clip.effect(id: waveID)! }
        var sound: WaveformSound? { project.waveformSounds(for: clip, in: timeline)[waveID] }

        mutating func edit(_ change: (inout Effect) -> Void) {
            project.editEffect(waveID, ofClip: clipID, in: project.rootTimelineID, change)
        }

        mutating func set(_ kind: ControlKind, _ values: [Double]) {
            edit { $0.changeControl(kind) { $0.number = AnimatedValue(ComponentValue(values: values)) } }
        }

        mutating func choose(_ kind: ControlKind, _ choice: String) {
            edit { $0.changeControl(kind) { $0.choice = choice } }
        }
    }

    private func paints(_ f: Fixture, at time: Double = 1) throws -> [WaveformDrawing.Paint] {
        let setup = try #require(WaveformSetup(f.effect, at: .zero, center: center))
        return WaveformDrawing.paints(
            WaveformStep(effectID: f.waveID, setup: setup, time: time), sound: f.sound, frame: CGRect(origin: .zero, size: frame)
        )
    }

    private func bounds(_ paints: [WaveformDrawing.Paint]) -> CGRect {
        paints.reduce(CGRect.null) { $0.union($1.area.boundingBoxOfPath) }
    }

    @Test func itHearsTheMixOfItsTimeline() throws {
        var f = try Fixture(frame: frame)
        #expect(f.sound?.sources.count == 1)
        // One clip it doesn't hear.
        f.edit { $0.listensTo = .clip(UUID()) }
        #expect(f.sound?.sources.isEmpty == true)
    }

    @Test func aFullScaleWaveFillsItsHeightBothWays() throws {
        var f = try Fixture(frame: frame)
        f.toneInBothChannels()
        f.set(.waveWindow, [10])
        f.set(.waveSamples, [441])
        f.choose(.waveSide, WaveformSide.both.rawValue)
        let drawn = try paints(f)
        // A line each side, a third of the frame either way of the middle.
        #expect(drawn.count == 2)
        let box = bounds(drawn)
        #expect(abs(box.midY - center.y) < 2)
        #expect(box.height > 2 * 120 - 4 && box.height < 2 * 120 + 6)
        #expect(abs(box.width - 2 * 427) < 6)
    }

    @Test func nothingIsDrawnWithoutSound() throws {
        let f = try Fixture(frame: frame)
        let setup = try #require(WaveformSetup(f.effect, at: .zero, center: center))
        #expect(WaveformDrawing.paints(WaveformStep(effectID: f.waveID, setup: setup, time: 1), sound: nil, frame: .zero).isEmpty)
        // Nor past the end of the song.
        #expect(bounds(try paints(f, at: 10)).height < 5)
    }

    @Test func barsColoredByLevelAreAPaintEach() throws {
        var f = try Fixture(frame: frame)
        f.set(.waveSamples, [32])
        f.choose(.waveDraw, WaveformDraw.bars.rawValue)
        f.choose(.waveColoring, WaveformColoring.byLevel.rawValue)
        f.edit { $0.changeControl(.fill) { $0.setPaint(.linear) } }
        #expect(try paints(f).count == 32)
    }

    @Test func theSpectrumPeaksAtTheTone() throws {
        let f = try Fixture(frame: frame)
        let sound = try #require(f.sound)
        let levels = WaveformAudio.shared.spectrum(sound, at: 1, bands: [250, 1000, 4000], channel: 0)
        #expect(levels[1] > 0.9)
        #expect(levels[0] < 0.5 && levels[2] < 0.5)
        // The right channel is silent.
        #expect(WaveformAudio.shared.spectrum(sound, at: 1, bands: [1000], channel: 1) == [0])
    }

    @Test func splitDrawsTheRightChannelInItsOwnColor() throws {
        var f = try Fixture(frame: frame)
        f.choose(.waveStereo, WaveformStereo.split.rawValue)
        let drawn = try paints(f)
        #expect(drawn.count == 2)
        #expect(drawn.contains { $0.color == [0.4, 0.8, 1, 1] })
    }

    @Test func theInspectorShowsTheSettingsOfHowItIsSet() throws {
        var f = try Fixture(frame: frame)
        #expect(f.effect.waveformShows(.waveStart) && !f.effect.waveformShows(.waveRadius))
        #expect(f.effect.waveformShows(.waveWindow) && !f.effect.waveformShows(.waveFrequencies))
        #expect(!f.effect.waveformShows(.rightColor))
        f.choose(.waveShape, WaveformShape.radial.rawValue)
        f.choose(.waveMode, WaveformMode.spectrum.rawValue)
        #expect(f.effect.waveformShows(.waveRadius) && !f.effect.waveformShows(.waveEnd))
        #expect(f.effect.waveformShows(.waveRelease) && !f.effect.waveformShows(.waveAlign))
    }

    @Test func itGoesIntoAnyClipAndIsFittedToTheFrame() throws {
        let f = try Fixture(frame: frame)
        // A third of the frame either side of the middle.
        #expect(f.effect.control(.waveStart)?.values(at: .zero) == [-427, 0])
        #expect(f.effect.control(.strokeWidth)?.values(at: .zero) == [3])
        #expect(f.effect.listensTo == .mix)
    }

    @Test func savingKeepsWhatItListensTo() async throws {
        var f = try Fixture(frame: frame)
        let layerID = UUID()
        f.edit { $0.listensTo = .layer(layerID) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "amv-waveform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appending(path: "Waveform.amv", directoryHint: .isDirectory)
        try await ProjectStore.save(f.project, to: package)
        let loaded = try await ProjectStore.load(from: package)
        let read = try #require(loaded.project.clipAndLayer(f.clipID, in: loaded.project.rootTimelineID)?.clip.effect(id: f.waveID))
        #expect(read.listensTo == .layer(layerID))
        #expect(read == f.effect)
    }
}

/// A Wave kept to its frequency range (see docs/waveform-effect.md).
@Suite struct WaveformFilterTests {
    private func sine(_ frequency: Double, seconds: Double = 0.2) -> [Double] {
        let rate = WaveformAudio.Samples.rate
        return (0..<Int(rate * seconds)).map { sin(2 * .pi * frequency * Double($0) / rate) }
    }

    @Test func theWholeRangeIsntFiltered() throws {
        var effect = Effect(kind: .waveform)
        effect.sizeShape(to: CGSize(width: 1280, height: 720))
        let setup = try #require(WaveformSetup(effect, at: .zero, center: CGPoint(x: 640, y: 360)))
        #expect(WaveformDrawing.bandFilters(setup) == nil)
    }

    @Test func aLowRangeKeepsTheBassAndDropsTheTreble() throws {
        var effect = Effect(kind: .waveform)
        effect.changeControl(.waveFrequencies) { $0.number = AnimatedValue(ComponentValue(values: [20, 200])) }
        let setup = try #require(WaveformSetup(effect, at: .zero, center: .zero))
        let filters = try #require(WaveformDrawing.bandFilters(setup))
        func peak(_ frequency: Double) -> Double {
            var signal = sine(frequency)
            for filter in filters { signal = WaveformDrawing.run(signal, through: filter) }
            // Once it has settled.
            return signal.suffix(signal.count / 2).map(abs).max() ?? 0
        }
        #expect(peak(60) > 0.8)
        #expect(peak(4000) < 0.01)
    }
}

/// The Graph picker's presets (docs/waveform-effect.md, "In the
/// inspector").
@Suite struct WaveformGraphTests {
    @Test func eachGraphIsRecognizedOnceApplied() {
        for graph in WaveformGraph.allCases {
            var effect = Effect(kind: .waveform)
            graph.apply(to: &effect)
            #expect(WaveformGraph.current(of: effect) == graph)
        }
    }

    @Test func aNewWaveformIsAWaveAndLeavingScopeTakesStereoOffXY() {
        var effect = Effect(kind: .waveform)
        #expect(WaveformGraph.current(of: effect) == .wave)
        WaveformGraph.scope.apply(to: &effect)
        #expect(effect.choice(.waveStereo, as: WaveformStereo.self) == .xy)
        WaveformGraph.bars.apply(to: &effect)
        #expect(effect.choice(.waveStereo, as: WaveformStereo.self) == .mixed)
        #expect(effect.choice(.waveMode, as: WaveformMode.self) == .spectrum)
        // Settings that match none of the graphs light none.
        effect.changeControl(.waveShape) { $0.choice = WaveformShape.radial.rawValue }
        #expect(WaveformGraph.current(of: effect) == nil)
    }
}

// The graphs and timing added from docs/fix-plan.md: Area, Rays and
// Particles; Level meters and the Spectrogram; attack, release and peak
// hold; the Floor and Scale; Spacing; and bars shaded up their length.
extension WaveformTests {
    @Test func anAreaIsOneFilledShapeWithNoLine() throws {
        var f = try Fixture(frame: frame)
        f.choose(.waveDraw, WaveformDraw.area.rawValue)
        let drawn = try paints(f)
        #expect(drawn.count == 1)
        #expect(bounds(drawn).height > 20)
    }

    @Test func raysAndParticlesDrawSomething() throws {
        var f = try Fixture(frame: frame)
        f.choose(.waveMode, WaveformMode.spectrum.rawValue)
        f.set(.waveSamples, [32])
        f.choose(.waveDraw, WaveformDraw.rays.rawValue)
        #expect(!(try paints(f)).isEmpty)
        f.choose(.waveDraw, WaveformDraw.particles.rawValue)
        // A paint for each of the four steps out.
        #expect(try paints(f).count == 4)
    }

    @Test func aMeterReachesItsHeightForAFullScaleTone() throws {
        var f = try Fixture(frame: frame)
        f.toneInBothChannels()
        f.choose(.waveMode, WaveformMode.level.rawValue)
        let drawn = try paints(f)
        #expect(drawn.count == 1)
        // Fitted to the frame, the Height is a sixth of it: 120.
        #expect(abs(bounds(drawn).height - 120) < 6)
        // A meter a channel, side by side.
        f.choose(.waveStereo, WaveformStereo.two.rawValue)
        let two = try paints(f)
        #expect(two.count == 2)
        #expect(abs(two[0].area.boundingBoxOfPath.midY - two[1].area.boundingBoxOfPath.midY) < 1)
    }

    @Test func peakHoldAddsAMarkAboveEachBar() throws {
        var f = try Fixture(frame: frame)
        f.toneInBothChannels()
        f.choose(.waveMode, WaveformMode.level.rawValue)
        let plain = try paints(f).count
        f.set(.wavePeakHold, [500])
        #expect(try paints(f).count == plain + 1)
    }

    @Test func theSpectrogramShadesItsCellsAndIsEmptyInSilence() throws {
        var f = try Fixture(frame: frame)
        f.edit { WaveformGraph.spectrogram.apply(to: &$0) }
        f.set(.waveSamples, [24])
        let drawn = try paints(f, at: 2)
        #expect(!drawn.isEmpty)
        let box = bounds(drawn)
        #expect(box.height <= 120 + 1)
        #expect(try paints(f, at: 30).isEmpty)
    }

    @Test func attackReleaseAndPeakHoldShapeTheLevel() {
        var setup = WaveformSetup(Effect(kind: .waveform), at: .zero, center: .zero)!
        // Sound arriving now after silence: the attack slows its rise.
        setup.attack = 0.5
        let rising = WaveformDrawing.envelope(setup, now: [1], at: 1) { _ in [0] }
        #expect(rising.values[0] < 0.2)
        // Silence now after sound: the release holds some of it.
        setup.attack = 0
        setup.release = 0.5
        let falling = WaveformDrawing.envelope(setup, now: [0], at: 1) { _ in [1] }
        #expect(falling.values[0] > 0.8)
        // The peak stays for the hold.
        setup.release = 0
        setup.peakHold = 0.3
        let held = WaveformDrawing.envelope(setup, now: [0.2], at: 1) { grid in [grid == 45 ? 0.9 : 0.1] }
        #expect(held.values[0] == 0.2)
        #expect(held.peaks?[0] == 0.9)
    }

    @Test func theScaleAndFloorShapeTheSpectrum() throws {
        #expect(WaveformScale.linear.frequencies(3, from: 20, to: 20_000) == [20, 10_010, 20_000])
        #expect(abs(WaveformScale.log.frequencies(3, from: 20, to: 20_000)[1] - 632.456) < 0.01)
        let f = try Fixture(frame: frame)
        let sound = try #require(f.sound)
        let deep = WaveformAudio.shared.spectrum(sound, at: 1, bands: [1015], channel: 0, floor: -120)[0]
        let shallow = WaveformAudio.shared.spectrum(sound, at: 1, bands: [1015], channel: 0, floor: -40)[0]
        #expect(deep > shallow)
    }

    @Test func spacingDecidesHowManyPoints() throws {
        var f = try Fixture(frame: frame)
        f.set(.waveSpacing, [10])
        let setup = try #require(WaveformSetup(f.effect, at: .zero, center: center))
        // The line is two thirds of 1280 across: 854 pixels.
        #expect(abs(WaveformDrawing.pointCount(setup) - 85) <= 1)
    }

    @Test func barsByLevelAreShadedUpTheirLength() throws {
        var f = try Fixture(frame: frame)
        f.choose(.waveMode, WaveformMode.spectrum.rawValue)
        f.set(.waveSamples, [8])
        f.choose(.waveDraw, WaveformDraw.bars.rawValue)
        f.choose(.waveColoring, WaveformColoring.byLevel.rawValue)
        f.edit { $0.changeControl(.fill) { $0.setPaint(.linear) } }
        let drawn = try paints(f)
        #expect(drawn.count == 8)
        #expect(drawn.allSatisfy { $0.gradient?.fill.style.space == .frame })
    }

    @Test func everyGraphHasAPreview() {
        for graph in WaveformGraph.allCases {
            #expect(!WaveformPreview.shapes(of: graph).isEmpty, "\(graph.name)")
        }
    }
}

// What it hears: through the EQ, inside nested timelines, and with
// volume edits building the timeline again.
extension WaveformTests {
    private func level(_ f: Fixture) throws -> Double {
        let sound = try #require(f.sound)
        return WaveformAudio.shared.level(sound, at: 1, channel: nil, floor: -80)
    }

    /// A song the mix leaves silent, muted or turned off, is silent here
    /// too, not drawn as though it played.
    @Test func itDoesntHearASongThatIsntPlayed() throws {
        for silence: (inout TimelineClip) -> Void in [{ $0.soundMuted = true }, { $0.enabled = false }] {
            var f = try Fixture(frame: frame)
            f.toneInBothChannels()
            #expect(try level(f) > 0.5)
            let songClip = try #require(f.timeline.layers.flatMap(\.clips).first { $0.source == .media(f.songID) })
            f.project.editClip(songClip.id, in: f.project.rootTimelineID, silence)
            let heard = f.sound.map { WaveformAudio.shared.level($0, at: 1, channel: nil, floor: -80) } ?? 0
            #expect(heard < 0.01)
        }
    }

    @Test func itHearsTheSongsEQ() throws {
        var f = try Fixture(frame: frame)
        f.toneInBothChannels()
        let plain = try level(f)
        // The EQ's output 20 dB down: a quarter of the 80 dB range.
        var eq = Effect(kind: .equalizer)
        eq.changeControl(.eqOutput) { $0.enabled = true; $0.number = AnimatedValue(ComponentValue(values: [-20])) }
        let songClip = try #require(f.timeline.layers.flatMap(\.clips).first { $0.source == .media(f.songID) })
        f.project.editClip(songClip.id, in: f.project.rootTimelineID) { $0.audioEffects = [eq] }
        #expect(f.sound?.hasEqualizers == true)
        let quieter = try level(f)
        #expect(abs((plain - quieter) - 0.25) < 0.02)
    }

    @Test func itHearsANestedTimelinesSound() throws {
        var f = try Fixture(frame: frame)
        f.toneInBothChannels()
        let plain = try level(f)
        let songClip = try #require(f.timeline.layers.flatMap(\.clips).first { $0.source == .media(f.songID) })
        let nested = f.project.nestClips([songClip.id], in: f.project.rootTimelineID, named: "Song")
        #expect(nested != nil)
        let source = try #require(f.sound?.sources.first)
        #expect(source.chain.count == 2)
        #expect(abs(try level(f) - plain) < 0.01)
    }

    @Test func aVolumeEditBuildsTheTimelineAgainWithAWaveform() throws {
        var f = try Fixture(frame: frame)
        let before = CompositionKey(project: f.project)
        let songClip = try #require(f.timeline.layers.flatMap(\.clips).first { $0.source == .media(f.songID) })
        f.project.editClip(songClip.id, in: f.project.rootTimelineID) { $0.volume = AnimatedValue(-6.0) }
        #expect(CompositionKey(project: f.project) != before)
    }
}

/// A Waveform drawn through the compositor from a sound file on disk, as
/// the app draws one: a WAV of a full-scale 1 kHz tone on a Music layer,
/// and a Waveform clip over it on the 128 by 72 frame.
@Suite struct WaveformCompositorTests {
    @Test func aWaveformDrawsItsSoundFileThroughTheCompositor() async throws {
        var fixture = try DrawingFixture()
        defer { fixture.cleanUp() }
        let url = fixture.directory.appending(path: "tone.wav")
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for i in 0..<Int(frames) { samples[i] = Float(sin(2 * .pi * 1000 * Double(i) / rate)) }
        }
        try file.write(from: buffer)
        var song = MediaClip(
            name: "tone.wav", kind: .audio, url: url, duration: CMTime(seconds: 2, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "PCM"
        )
        song.hasAudio = true
        fixture.project.clips.append(song)
        fixture.project.putOnMusicLayer([song.id])
        let added = fixture.project.addShapeLayer(.waveform, to: fixture.timelineID, duration: CMTime(seconds: 2, preferredTimescale: 600))
        #expect(added != nil)
        let composed = try await fixture.build()
        let second = CMTime(seconds: 1, preferredTimescale: 600)
        // A dense, full-height wave across the middle; dark above it.
        #expect(try await grayLevel(of: composed, at: second, x: 0.5, y: 0.5) > 150)
        #expect(try await grayLevel(of: composed, at: second, x: 0.5, y: 0.05) < 10)
    }
}
