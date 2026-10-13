import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A click every `interval` seconds, starting at `first`: a short decaying
/// noise burst, which is what a drum hit looks like to an onset detector.
private func clickTrack(seconds: Double, interval: Double, first: Double, sampleRate: Double) -> [Float] {
    var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
    var generator = SystemRandomNumberGenerator()
    var time = first
    while time < seconds {
        let start = Int(time * sampleRate)
        let length = Int(0.03 * sampleRate)
        for i in 0..<length where start + i < samples.count {
            let envelope = Float(exp(-Double(i) / (0.006 * sampleRate)))
            samples[start + i] = Float.random(in: -1...1, using: &generator) * envelope * 0.8
        }
        time += interval
    }
    return samples
}

private func seconds(_ time: CMTime) -> Double { time.seconds }

@Suite struct BeatDetectorTests {
    // MARK: Tracking

    @Test func findsTheTempoAndPlacementOfAClickTrack() throws {
        let rate = BeatDetector.sampleRate
        let samples = clickTrack(seconds: 12, interval: 0.5, first: 0.1, sampleRate: rate)
        let analyzer = OnsetAnalyzer()
        samples.withUnsafeBufferPointer { analyzer.append($0) }

        let result = try #require(BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond))

        #expect(abs(result.beatsPerMinute - 120) < 3)
        #expect(result.frames.count >= 18)
        for frame in result.frames {
            let beat = Double(OnsetAnalyzer.centerSample(ofFrame: frame)) / rate
            let nearest = ((beat - 0.1) / 0.5).rounded() * 0.5 + 0.1
            #expect(abs(beat - nearest) < 0.05, "beat at \(beat)s is off the clicks")
        }
    }

    @Test func slowerClicksGiveTheirOwnTempo() throws {
        let rate = BeatDetector.sampleRate
        let samples = clickTrack(seconds: 16, interval: 60.0 / 90.0, first: 0.3, sampleRate: rate)
        let analyzer = OnsetAnalyzer()
        samples.withUnsafeBufferPointer { analyzer.append($0) }

        let result = try #require(BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond))

        #expect(abs(result.beatsPerMinute - 90) < 3)
    }

    @Test func silenceAndShortAudioHaveNoBeats() {
        let analyzer = OnsetAnalyzer()
        [Float](repeating: 0, count: 22_050 * 10).withUnsafeBufferPointer { analyzer.append($0) }
        #expect(BeatTracker.track(envelope: analyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond) == nil)

        let short = clickTrack(seconds: 2, interval: 0.5, first: 0.1, sampleRate: BeatDetector.sampleRate)
        let shortAnalyzer = OnsetAnalyzer()
        short.withUnsafeBufferPointer { shortAnalyzer.append($0) }
        #expect(BeatTracker.track(envelope: shortAnalyzer.envelope, framesPerSecond: OnsetAnalyzer.framesPerSecond) == nil)
    }

    // MARK: End to end

    @Test func detectsBeatsInAnAudioFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-beats-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 44_100.0
        let samples = clickTrack(seconds: 12, interval: 0.5, first: 0.1, sampleRate: rate)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }

        let track = try await BeatDetector.detect(url: url)

        #expect(!track.isEmpty)
        #expect(abs(track.beatsPerMinute - 120) < 3)
        for beat in track.beats(from: .zero, to: CMTime(seconds: 13, preferredTimescale: 600)) {
            let nearest = ((beat.seconds - 0.1) / 0.5).rounded() * 0.5 + 0.1
            #expect(abs(beat.seconds - nearest) < 0.05)
        }
    }

    @Test func aFileWithoutAudioIsAnError() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-noaudio-\(UUID().uuidString).txt")
        try Data("nope".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            _ = try await BeatDetector.detect(url: url)
        }
    }

    // MARK: BeatTrack

    private let sample = BeatTrack(timescale: 1000, times: [0, 500, 1000, 1500, 2000], beatsPerMinute: 120)

    @Test func beatsInARangeIncludeTheStartAndExcludeTheEnd() {
        let beats = sample.beats(from: CMTime(value: 500, timescale: 1000), to: CMTime(value: 1500, timescale: 1000))
        #expect(beats.map(seconds) == [0.5, 1.0])
        #expect(sample.beats(from: CMTime(seconds: 3, preferredTimescale: 600), to: CMTime(seconds: 4, preferredTimescale: 600)).isEmpty)
    }

    @Test func encodingRoundTrips() throws {
        let decoded = try BeatTrack(decoding: sample.encoded())
        #expect(decoded.times == sample.times)
        #expect(decoded.timescale == 1000)
        #expect(abs(decoded.beatsPerMinute - 120) < 0.001)

        let empty = try BeatTrack(decoding: BeatTrack.none().encoded())
        #expect(empty.isEmpty)
    }

    @Test func damagedDataIsRejected() {
        #expect(throws: BeatTrackError.self) { try BeatTrack(decoding: Data("nonsense".utf8)) }
        #expect(throws: BeatTrackError.self) { try BeatTrack(decoding: sample.encoded().dropLast(3)) }
        #expect(throws: BeatTrackError.self) { try BeatTrack(decoding: Data()) }
    }

    // MARK: Timeline markers

    private func audioAsset(_ name: String = "song.wav") -> MediaClip {
        MediaClip(
            name: name, kind: .audio, url: URL(fileURLWithPath: "/tmp/\(name)"),
            duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "Test", hasAudio: true
        )
    }

    private func add(_ asset: MediaClip, to project: inout EditingProject) -> (layerID: UUID, clipID: UUID) {
        project.importClip(asset, intoTimeline: project.rootTimelineID)!
    }

    private func t(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    @Test func markersFollowTheClipsTrimAndPlacement() throws {
        var project = EditingProject.empty
        let asset = audioAsset()
        let ids = add(asset, to: &project)
        let timeline = project.timelines[0]
        var layer = try #require(timeline.layer(id: ids.layerID))
        // Plays the asset from 0.75s to 2.25s, starting at 10s on the timeline.
        layer.clips[0].trimStart = t(0.75)
        layer.clips[0].trimEnd = t(2.25)
        layer.clips[0].startOffset = t(10)

        let markers = project.beatMarkers(in: layer, tracks: [asset.id: sample])

        #expect(markers.map { seconds($0) } == [10.25, 10.75, 11.25])
    }

    @Test func markersOfAReplacedFileAreShiftedByItsOffset() throws {
        var project = EditingProject.empty
        let asset = audioAsset()
        let ids = add(asset, to: &project)
        // Original time t is at t + 0.5s in the current file, where the beats were found.
        project.setAlignmentOffset(t(0.5), forAsset: asset.id)
        var layer = try #require(project.timelines[0].layer(id: ids.layerID))
        layer.clips[0].trimStart = t(0.75)
        layer.clips[0].trimEnd = t(2.25)
        layer.clips[0].startOffset = t(10)

        let markers = project.beatMarkers(in: layer, tracks: [asset.id: sample])

        // File beats 1.5 and 2.0 fall in the file range 1.25..<2.75.
        #expect(markers.map { seconds($0) } == [10.25, 10.75])
    }

    @Test func markersCombineEveryClipOnTheLayerInOrder() throws {
        var project = EditingProject.empty
        let asset = audioAsset()
        let ids = add(asset, to: &project)
        var layer = try #require(project.timelines[0].layer(id: ids.layerID))
        layer.clips[0].trimStart = .zero
        layer.clips[0].trimEnd = t(1)
        layer.clips[0].startOffset = t(5)
        var second = layer.clips[0]
        second.id = UUID()
        second.startOffset = t(0)
        layer.clips.append(second)

        let markers = project.beatMarkers(in: layer, tracks: [asset.id: sample])

        #expect(markers.map { seconds($0) } == [0, 0.5, 5, 5.5])
    }

    @Test func layersWithoutBeatsAreNotOffered() throws {
        var project = EditingProject.empty
        let song = audioAsset("song.wav"), quiet = audioAsset("quiet.wav"), unanalyzed = audioAsset("new.wav")
        let first = add(song, to: &project)
        let second = add(quiet, to: &project)
        _ = add(unanalyzed, to: &project)
        let tracks = [song.id: sample, quiet.id: BeatTrack.none()]

        let offered = project.beatLayers(in: project.timelines[0], tracks: tracks)

        #expect(offered.map(\.id) == [first.layerID])
        #expect(!offered.contains { $0.id == second.layerID })
    }

    @Test func deletingALayerRemovesItFromTheChoices() throws {
        var project = EditingProject.empty
        let song = audioAsset("song.wav"), other = audioAsset("other.wav")
        let first = add(song, to: &project)
        let second = add(other, to: &project)
        let tracks = [song.id: sample, other.id: sample]
        #expect(Set(project.beatLayers(in: project.timelines[0], tracks: tracks).map(\.id)) == [first.layerID, second.layerID])

        project.timelines[0].layers.removeAll { $0.id == first.layerID }

        #expect(project.beatLayers(in: project.timelines[0], tracks: tracks).map(\.id) == [second.layerID])
    }
}

// MARK: - Analysis queue and saving

private func writeClickFile(seconds: Double = 12) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "amv-beats-\(UUID().uuidString).wav")
    let rate = 44_100.0
    let samples = clickTrack(seconds: seconds, interval: 0.5, first: 0.1, sampleRate: rate)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
    return url
}

@MainActor
@Suite struct BeatAnalysisQueueTests {
    private func project(url: URL, hasAudio: Bool) -> EditingProject {
        var project = EditingProject.empty
        project.clips = [MediaClip(
            name: url.lastPathComponent, kind: .audio, url: url,
            duration: CMTime(seconds: 12, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "Test", hasAudio: hasAudio
        )]
        return project
    }

    private func waitForBeats(_ analysis: AssetAnalysis) async throws {
        for _ in 0..<2000 {
            if analysis.progress.isEmpty && analysis.beats.count + analysis.beatFailures.count >= 1 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("beat analysis did not finish")
    }

    @Test func clipsWithAudioGetBeatsAndTheyAreUnsavedUntilMarked() async throws {
        let url = try writeClickFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = project(url: url, hasAudio: true)
        let id = project.clips[0].id
        let analysis = AssetAnalysis()

        analysis.analyzeMissing(in: project)
        try await waitForBeats(analysis)

        let track = try #require(analysis.beats[id])
        #expect(abs(track.beatsPerMinute - 120) < 3)
        #expect(Set(analysis.unsavedBeats.keys) == [id])
        analysis.markBeatsSaved([id])
        #expect(analysis.unsavedBeats.isEmpty)
        #expect(analysis.beats[id] != nil)
    }

    @Test func clipsWithoutAudioAreNotAnalyzedForBeats() async throws {
        let url = try writeClickFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let silent = project(url: url, hasAudio: false)
        let analysis = AssetAnalysis()

        analysis.analyzeMissing(in: silent)
        for _ in 0..<2000 where !analysis.progress.isEmpty { try await Task.sleep(for: .milliseconds(5)) }

        #expect(analysis.beats.isEmpty)
        #expect(analysis.beatFailures.isEmpty)
    }

    @Test func savedBeatsAreNotFoundAgain() async throws {
        let url = try writeClickFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let project = project(url: url, hasAudio: true)
        let id = project.clips[0].id
        let analysis = AssetAnalysis()
        analysis.reset(beats: [id: .none()])

        analysis.analyzeMissing(in: project)

        for _ in 0..<2000 where !analysis.progress.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(analysis.beats[id] == BeatTrack.none())
        #expect(analysis.unsavedBeats.isEmpty)
    }
}

@Suite struct BeatStorageTests {
    private func makePackage() throws -> (root: URL, package: URL, project: EditingProject, assetID: UUID) {
        let root = FileManager.default.temporaryDirectory.appending(path: "amv-beat-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appending(path: "song.wav")
        try Data("not really audio".utf8).write(to: media)
        var project = EditingProject.empty
        let asset = MediaClip(
            name: "song.wav", kind: .audio, url: media,
            duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "Stub", hasAudio: true
        )
        _ = project.importClip(asset, intoTimeline: project.rootTimelineID)
        return (root, root.appending(path: "Test.amv", directoryHint: .isDirectory), project, asset.id)
    }

    private let stubImporter: @Sendable (URL) async throws -> MediaClip = { url in
        MediaClip(
            name: url.lastPathComponent, kind: .audio, url: url,
            duration: CMTime(seconds: 10, preferredTimescale: 600), frameRate: 0,
            colorSpace: .rec709, codecName: "Stub", hasAudio: true
        )
    }

    @Test func beatsAreSavedInReferenceAndLoadedBack() async throws {
        let (root, package, project, assetID) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = BeatTrack(timescale: 1000, times: [100, 600, 1100], beatsPerMinute: 120)

        try await ProjectStore.save(project, to: package, beats: [assetID: track])

        let file = ProjectStore.referenceFolder(for: assetID, in: package).appending(path: ProjectStore.beatFileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let loaded = try await ProjectStore.load(from: package, importMedia: stubImporter)
        #expect(loaded.beats[assetID]?.times == track.times)
    }

    @Test func anEmptyResultIsSavedSoTheAudioIsNotAnalyzedAgain() async throws {
        let (root, package, project, assetID) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        try await ProjectStore.save(project, to: package, beats: [assetID: .none()])

        let loaded = try await ProjectStore.load(from: package, importMedia: stubImporter)
        #expect(try #require(loaded.beats[assetID]).isEmpty)
    }

    @Test func beatsForUnknownAssetsAreNotWritten() async throws {
        let (root, package, project, _) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let stray = UUID()

        try await ProjectStore.save(project, to: package, beats: [stray: .none()])

        #expect(!FileManager.default.fileExists(atPath: ProjectStore.referenceFolder(for: stray, in: package).path))
    }

    @Test func aDamagedBeatFileJustMeansNotAnalyzed() async throws {
        let (root, package, project, assetID) = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        try await ProjectStore.save(project, to: package, beats: [assetID: .none()])
        let file = ProjectStore.referenceFolder(for: assetID, in: package).appending(path: ProjectStore.beatFileName)
        try Data("garbage".utf8).write(to: file)

        let loaded = try await ProjectStore.load(from: package, importMedia: stubImporter)

        #expect(loaded.beats[assetID] == nil)
    }
}
