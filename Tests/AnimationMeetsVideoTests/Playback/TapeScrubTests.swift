import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct TapeScrubTests {
    /// A piece holding a 440 Hz sine at 0.5 on the left and -0.5 on the
    /// right, starting at phase 0 at the timeline's start.
    private static func sinePiece() -> TapePiece {
        let frames = Int(TapeScrub.pieceSeconds * TapeScrub.sampleRate)
        let left = (0..<frames).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / TapeScrub.sampleRate)) }
        return TapePiece(left: left, right: left.map { -$0 })
    }

    private static func sine(at frame: Double) -> Float {
        Float(0.5 * sin(2 * Double.pi * 440 * frame / TapeScrub.sampleRate))
    }

    /// Plays `frames` frames, returning the left channel.
    private static func play(
        _ transport: inout TapeTransport, target: Double, frames: Int, end: Double = 1e9, pieces: [Int: TapePiece]
    ) -> [Float] {
        var left = [Float](repeating: 0, count: frames), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                transport.render(target: target, end: end, pieces: pieces, frames: frames, left: l.baseAddress!, right: r.baseAddress!)
            }
        }
        return left
    }

    @Test func theDialStartsSlowAndGetsFaster() {
        #expect(TapeScrub.rate(forDrag: 0) == 0)
        #expect(TapeScrub.rate(forDrag: 2) == 0)
        // A short drag is slow; it speeds up the further it goes.
        #expect(TapeScrub.rate(forDrag: 30) < 0.1)
        #expect(abs(TapeScrub.rate(forDrag: 152) - 1) < 1e-9)
        var last = 0.0
        for points in stride(from: 3.0, through: 400, by: 1) {
            let rate = TapeScrub.rate(forDrag: points)
            #expect(rate > last)
            last = rate
        }
        // Left is backwards, as fast; and there's a top speed.
        #expect(TapeScrub.rate(forDrag: -90) == -TapeScrub.rate(forDrag: 90))
        #expect(TapeScrub.rate(forDrag: 5_000) == TapeScrub.maxRate)
    }

    /// At normal speed the head plays the mix as it is, reading between
    /// samples where it falls between them.
    @Test func atNormalSpeedItPlaysTheMix() {
        let pieces = [0: Self.sinePiece()]
        var transport = TapeTransport(sampleRate: TapeScrub.sampleRate)
        transport.cue(1_000.3)
        // Up to speed and level.
        _ = Self.play(&transport, target: 1, frames: 9_600, pieces: pieces)
        #expect(transport.rate == 1)
        for _ in 0..<200 {
            let heard = Self.play(&transport, target: 1, frames: 1, pieces: pieces)[0]
            #expect(abs(heard - Self.sine(at: transport.position)) < 0.001)
        }
    }

    /// The speed glides to the dial's within a few buffers, and starting
    /// from rest doesn't click.
    @Test func itGlidesWithoutClicking() {
        let pieces = [0: Self.sinePiece()]
        var transport = TapeTransport(sampleRate: TapeScrub.sampleRate)
        // A quarter of the way into a cycle, where the sine is at its peak.
        transport.cue(1_000 + TapeScrub.sampleRate / 440 / 4)
        let first = Self.play(&transport, target: 4, frames: 480, pieces: pieces)
        #expect(abs(first[0]) < 0.001)
        // Most of the way there after one 10 ms buffer, all of it soon.
        #expect(transport.rate > 1.5)
        #expect(transport.rate < 4)
        _ = Self.play(&transport, target: 4, frames: 9_600, pieces: pieces)
        #expect(transport.rate == 4)
        // Let go, it comes to rest, quietly.
        let stopping = Self.play(&transport, target: 0, frames: 9_600, pieces: pieces)
        #expect(transport.rate == 0)
        #expect(abs(stopping.last ?? 1) < 0.0001)
    }

    @Test func itPlaysBackwardsAndStopsAtEitherEnd() {
        let pieces = [0: Self.sinePiece()]
        var transport = TapeTransport(sampleRate: TapeScrub.sampleRate)
        transport.cue(4_800)
        _ = Self.play(&transport, target: -1, frames: 2_400, pieces: pieces)
        #expect(transport.position < 4_800)
        _ = Self.play(&transport, target: -8, frames: 4_800, pieces: pieces)
        #expect(transport.position == 0)
        #expect(transport.rate == 0)
        transport.cue(9_000)
        _ = Self.play(&transport, target: 8, frames: 4_800, end: 10_000, pieces: pieces)
        #expect(transport.position == 10_000)
        #expect(transport.rate == 0)
    }

    /// A piece not read yet is silence, not garbage.
    @Test func missingPiecesAreSilent() {
        var transport = TapeTransport(sampleRate: TapeScrub.sampleRate)
        transport.cue(200_000)
        let heard = Self.play(&transport, target: 1, frames: 4_800, pieces: [0: Self.sinePiece()])
        #expect(heard.allSatisfy { $0 == 0 })
    }

    @Test func piecesAreReadAheadTheWayItGoes() {
        #expect(TapeScrub.wanted(at: 5, backwards: false, end: 60) == [2, 3, 4, 1])
        #expect(TapeScrub.wanted(at: 5, backwards: true, end: 60) == [2, 1, 0, 3])
        // Not before the start or past the end.
        #expect(TapeScrub.wanted(at: 0.5, backwards: true, end: 60) == [0, 1])
        #expect(TapeScrub.wanted(at: 5, backwards: false, end: 6.5) == [2, 3, 1])
    }

    /// Each piece holds the mix from its own start, whatever preroll was
    /// read before it.
    @Test func aPieceIsTheMixFromItsStart() async throws {
        let url = try AudioMixSupport.tone(amplitude: 0.25, seconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        var (project, _, layerID) = try AudioMixSupport.project(playing: url, seconds: 6)
        // Silent for the first 3 seconds, then full: the step shows where
        // the piece is.
        project.editVolume(of: layerID, in: project.rootTimelineID) {
            $0 = AnimatedValue(0, keyframes: [
                Keyframe(time: .zero, value: -96),
                Keyframe(time: CMTime(value: 2_999, timescale: 1_000), value: -96),
                Keyframe(time: CMTime(value: 3, timescale: 1), value: 0),
            ])
        }
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let curves = MixCurves(MixCurves.of(project))
        let piece = TapeScrub.read(1, of: composed, curves: curves)
        let rate = TapeScrub.sampleRate
        #expect(piece.left.count == Int(TapeScrub.pieceSeconds * rate))
        // Piece 1 is 2 to 4 seconds: quiet until a second in, then the tone.
        #expect(piece.left[Int(0.9 * rate)..<Int(0.99 * rate)].allSatisfy { abs($0) < 0.01 })
        #expect(abs(piece.left[Int(1.5 * rate)] - 0.25) < 0.005)
        // Past the end there's nothing, but still a piece.
        let past = TapeScrub.read(10, of: composed, curves: curves)
        #expect(past.left.allSatisfy { $0 == 0 })
    }
}

/// The tape on a real engine: it needs an output device.
@Suite(.enabled(if: !AudioDevices.outputs().isEmpty))
struct TapeScrubEngineTests {
    @Test func theTapeRunsAtTheSpeedAskedAndComesToRest() async throws {
        let url = try AudioMixSupport.tone(amplitude: 0.25, seconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let (project, _, _) = try AudioMixSupport.project(playing: url, seconds: 6)
        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let tape = TapeScrub()
        defer { tape.close() }
        tape.setComposition(composed, curves: MixCurves(MixCurves.of(project)))
        tape.open(deviceUID: nil)
        tape.cue(3)
        try await Task.sleep(for: .milliseconds(300))
        #expect(tape.position == 3)

        tape.setRate(-2)
        try await Task.sleep(for: .milliseconds(500))
        // A second back, less the moment it took to get going.
        #expect(tape.position < 2.2)
        #expect(tape.position > 1.8)

        tape.setRate(0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(tape.isStopped)
        let rest = tape.position
        try await Task.sleep(for: .milliseconds(100))
        #expect(tape.position == rest)
    }
}
