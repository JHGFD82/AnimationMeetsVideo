import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct RecordingTests {
    /// Held, since its stream description points into it.
    private let avFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var format: AudioStreamBasicDescription { avFormat.streamDescription.pointee }

    /// Writes `count` buffers of 4800 frames (a tenth of a second) at
    /// `amplitude`.
    private func write(_ count: Int, amplitude: Float = 0.5, to writer: TakeWriter) throws {
        let avFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: 4800))
        buffer.frameLength = 4800
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: amplitude, count: 4800) }
        for index in 0..<count {
            writer.write(buffer.audioBufferList, frames: 4800, hostTime: UInt64(index))
        }
    }

    @Test func aTakeIsPlacedBackFromWhenTheTimelineStartedMoving() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-take-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        // The timeline is still for the first two buffers, then the third
        // arrives at 10 s.
        let writer = try TakeWriter(url: url, format: format) { host in
            host < 2 ? nil : CMTime(value: 10, timescale: 1)
        }
        try write(5, to: writer)
        #expect(writer.takePeak() == 0.5)
        #expect(writer.takePeak() == 0)
        writer.finish()
        // Two buffers, 0.2 s, came in before it.
        let start = try #require(writer.start)
        #expect(abs(start.seconds - 9.8) < 0.0001)
        #expect(abs(writer.seconds - 0.5) < 0.0001)
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == 24_000)
    }

    @Test func aTakeIsKeptInTheProjectsMedia() async throws {
        let package = FileManager.default.temporaryDirectory.appending(path: "amv-package-\(UUID().uuidString).amv", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        // In a folder of its own: keeping it renames it to a name fixed by
        // the date, which runs sharing the temporary folder would fight over.
        let takes = FileManager.default.temporaryDirectory.appending(path: "amv-takes-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: takes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: takes) }
        let take = takes.appending(path: "take.caf")
        let writer = try TakeWriter(url: take, format: format) { _ in .zero }
        try write(1, to: writer)
        writer.finish()

        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 10, 17, 22, 5, 9)
        let date = try #require(Calendar.current.date(from: parts))
        let kept = try await AudioRecorder.keep(take, packageURL: package, recordedAt: date)
        #expect(kept.lastPathComponent == "Recording 2026-10-17 at 22.05.09.caf")
        #expect(kept.deletingLastPathComponent().lastPathComponent == "Media")
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: take.path))
    }

    @Test func aRecordingGoesOnANewSoundLayer() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let clip = MediaClip(
            name: "Recording", kind: .audio, url: nil, duration: CMTime(value: 3, timescale: 1),
            frameRate: 0, colorSpace: .rec709, codecName: "PCM", hasAudio: true
        )
        let start = CMTime(value: 2_550, timescale: 1_000)
        let added = project.addRecording(clip, at: start, in: timelineID)
        let layerID = try #require(added)
        let layer = try #require(project.timeline(id: timelineID)?.layer(id: layerID))
        #expect(layer.kind == .sound)
        // Sound isn't held to frames: it lands exactly where it was heard.
        #expect(layer.clips.first?.startOffset == start)
    }

    @Test func appsLeaveThisOneOut() {
        let own = Bundle.main.bundlePath
        for app in AudioApps.list() {
            #expect(!app.processes.isEmpty)
            #expect(!app.name.isEmpty)
            #expect(app.id != own)
        }
    }

    @Test @MainActor func durationsRead() {
        #expect(RecordPopover.duration(7.9) == "0:07")
        #expect(RecordPopover.duration(3727) == "1:02:07")
    }
}
