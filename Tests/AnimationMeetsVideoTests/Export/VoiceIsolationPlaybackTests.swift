import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Voice isolation as the viewer plays it, through a real player. The
/// player stamps its buffers loosely; taking that for jumps reset the unit
/// on every buffer and left the voice at half its level. Plays silently,
/// and only on a machine with somewhere to play.
@Suite(.enabled(if: !AudioDevices.outputs().isEmpty))
struct VoiceIsolationPlaybackTests {
    /// Spoken words from the system's voice, as a WAV file.
    private func speech() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
        let aiff = folder.appending(path: "amv-speech-\(UUID().uuidString).aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        func run(_ path: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
        }
        try run("/usr/bin/say", ["-o", aiff.path, "The quick brown fox jumps over the lazy dog, again and again and again."])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@44100", "-c", "1", aiff.path, wav.path])
        try? FileManager.default.removeItem(at: aiff)
        return wav
    }

    /// The average level the meter saw from 0.5 s to `end`.
    private func average(_ meter: MixLevelMeter, to end: Double) -> Float {
        let steps = Array(stride(from: 0.5, to: end, by: 0.1))
        return steps.reduce(0) { $0 + meter.reading(at: $1, span: 5).rms.x } / Float(steps.count)
    }

    @MainActor @Test func theVoiceIsHeardAtItsLevelWhilePlaying() async throws {
        let url = try speech()
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = try await AVURLAsset(url: url).load(.duration)
        var (project, clipID, _) = try AudioMixSupport.project(playing: url, seconds: duration.seconds)
        _ = project.addEffect(.voiceIsolation, toClip: clipID, in: project.rootTimelineID)

        let read = MixLevelMeter()
        _ = try await AudioMixSupport.loudest(of: project, meter: read)

        let composed = try await CompositionExporter.buildComposedTimeline(for: project, timelineID: project.rootTimelineID)
        let played = MixLevelMeter()
        let item = AVPlayerItem(asset: composed.composition)
        item.audioMix = composed.audioMix(curves: MixCurves(MixCurves.of(project)), meter: played)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.play()
        try await Task.sleep(for: .seconds(2.5))
        player.pause()

        let heard = average(played, to: 2.2), expected = average(read, to: 2.2)
        #expect(expected > 0.01)
        #expect(heard > expected * 0.8)
    }
}
