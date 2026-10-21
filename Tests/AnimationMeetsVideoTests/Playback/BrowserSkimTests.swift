import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
@Suite(.serialized) struct BrowserSkimTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    /// A 4 s, 24 fps movie and the clip for it.
    private func makeClip(alignment: Double = 0) async throws -> MediaClip {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-skim-\(UUID().uuidString).mov")
        try await writeMovie(to: url, segments: [(0, 24), (128, 24), (255, 48)])
        var clip = MediaClip(
            name: "Skimmed", kind: .video, url: url, duration: seconds(4),
            frameRate: 24, colorSpace: .rec709, codecName: "H.264"
        )
        clip.alignmentOffset = seconds(alignment)
        return clip
    }

    private func target(_ clip: MediaClip, from start: Double = 0, length: Double = 4) -> BrowserSkim.Target {
        BrowserSkim.Target(item: "clip", clip: clip, start: seconds(start), duration: seconds(length))
    }

    /// Waits for the player to get to `time`, as a seek finishes.
    private func playerReaches(_ skim: BrowserSkim, _ time: Double) async -> Bool {
        for _ in 0..<200 {
            if abs(skim.player.currentTime().seconds - time) < 0.001 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func showsTheFrameSkimmedToInTheFile() async throws {
        let clip = try await makeClip(alignment: 0.5)
        defer { try? FileManager.default.removeItem(at: clip.url!) }
        let skim = BrowserSkim()
        defer { skim.end() }

        skim.skim(target(clip, length: 3), at: 1)

        #expect(skim.isActive)
        #expect(skim.seconds == 1)
        #expect(skim.sourceTime == seconds(1))
        // Original time 1 s is 1.5 s into the file.
        #expect(await playerReaches(skim, 1.5))
        #expect(skim.player.isMuted)
    }

    @Test func aSceneIsSkimmedFromWhereItStarts() async throws {
        let clip = try await makeClip()
        defer { try? FileManager.default.removeItem(at: clip.url!) }
        let skim = BrowserSkim()
        defer { skim.end() }

        skim.skim(target(clip, from: 2, length: 2), at: 0.5)

        #expect(skim.sourceTime == seconds(2.5))
        #expect(await playerReaches(skim, 2.5))
    }

    @Test func staysInsideTheClipAndStepsByFrames() async throws {
        let clip = try await makeClip()
        defer { try? FileManager.default.removeItem(at: clip.url!) }
        let skim = BrowserSkim()
        defer { skim.end() }

        skim.skim(target(clip, length: 2), at: 9)
        #expect(skim.seconds == 2)
        skim.skim(target(clip, length: 2), at: -1)
        #expect(skim.seconds == 0)

        skim.step(frames: 3)
        #expect(abs(skim.seconds - 3.0 / 24) < 1e-9)
        skim.step(frames: -10)
        #expect(skim.seconds == 0)
        skim.step(frames: 10)
        #expect(await playerReaches(skim, 10.0 / 24))
    }

    @Test func spacePlaysToTheClipsEndAndSkimmingStopsIt() async throws {
        let clip = try await makeClip()
        defer { try? FileManager.default.removeItem(at: clip.url!) }
        let skim = BrowserSkim()
        defer { skim.end() }
        let short = target(clip, from: 1, length: 0.5)

        skim.skim(short, at: 0)
        #expect(await playerReaches(skim, 1))
        skim.togglePlay()
        #expect(skim.isPlaying)
        #expect(!skim.player.isMuted)
        for _ in 0..<300 where skim.isPlaying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!skim.isPlaying)
        #expect(abs(skim.seconds - 0.5) < 0.1)

        // Played again from the end, it starts over; moving the pointer
        // goes back to skimming, silently.
        skim.togglePlay()
        #expect(skim.isPlaying)
        #expect(skim.seconds == 0)
        skim.skim(short, at: 0.25)
        #expect(!skim.isPlaying)
        #expect(skim.player.isMuted)
    }

    @Test func endingGivesTheViewerBack() async throws {
        let clip = try await makeClip()
        defer { try? FileManager.default.removeItem(at: clip.url!) }
        let skim = BrowserSkim()

        skim.skim(target(clip), at: 1)
        skim.end()

        #expect(!skim.isActive)
        #expect(skim.player.currentItem == nil)
        skim.togglePlay()
        #expect(!skim.isPlaying)
    }

    @Test func stillsAndMissingFilesArentSkimmed() {
        let still = MediaClip(
            name: "Still", kind: .image, url: URL(fileURLWithPath: "/tmp/still.png"), duration: MediaClip.stillLength,
            frameRate: 0, colorSpace: .rec709, codecName: "PNG"
        )
        var offline = still
        offline.kind = .video
        offline.url = nil
        let skim = BrowserSkim()

        skim.skim(target(still), at: 1)
        #expect(!skim.isActive)
        skim.skim(target(offline), at: 1)
        #expect(!skim.isActive)
    }
}
