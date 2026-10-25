import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct FrameRateChangeTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    @Test func fractionalRatesKeepTheirFrameLength() {
        #expect(Timeline.frameDuration(for: 12.5) == CMTime(value: 1000, timescale: 12_500))
        #expect(Timeline.frameDuration(for: 25) == CMTime(value: 1, timescale: 25))
        #expect(Timeline.frameDuration(for: 29.97) == CMTime(value: 1001, timescale: 30_000))
    }

    @Test func changingTheRateMovesClipsLayerKeyframesAndSectionsOntoTheNewFrames() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(
            name: "Clip", kind: .video, url: nil, duration: seconds(10),
            frameRate: 24, colorSpace: .rec709, codecName: "Stub"
        )
        // Called first: #require can't wrap a mutating call.
        let imported = project.importClip(media, intoTimeline: t)
        let placed = project.placeAsset(media.id, intoTimeline: t)
        let first = try #require(imported)
        let second = try #require(placed)
        // Two clips meeting at a frame of 24 fps that isn't one of 25 fps.
        project.trimClipEnd(first.clipID, in: t, layer: first.layerID, to: CMTime(value: 25, timescale: 24))
        project.moveClip(second.clipID, in: t, layer: second.layerID, onto: first.layerID, to: CMTime(value: 25, timescale: 24))
        let tIndex = try #require(project.timelines.firstIndex { $0.id == t })
        let lIndex = try #require(project.timelines[tIndex].layers.firstIndex { $0.id == first.layerID })
        project.timelines[tIndex].layers[lIndex].volume.setAnimated(true, at: CMTime(value: 1, timescale: 24))
        project.addSection(in: t, from: CMTime(value: 1, timescale: 24), to: CMTime(value: 25, timescale: 24))

        let timeline = try #require(project.timeline(id: t))
        project.updateTimelineSettings(t, name: timeline.name, frameSize: timeline.frameSize, frameRate: 25, colorSpace: timeline.colorSpace)

        let updated = try #require(project.timeline(id: t))
        let frame = updated.frameDuration
        func onFrame(_ time: CMTime) -> Bool { updated.frameAligned(time, .nearest) == time }
        let clips = try #require(updated.layer(id: first.layerID)).clips
        #expect(clips.count == 2)
        #expect(clips.allSatisfy { onFrame($0.startOffset) && onFrame($0.endOffset) })
        #expect(clips[0].endOffset == clips[1].startOffset)
        #expect(try #require(updated.layer(id: first.layerID)).volume.keyframes.allSatisfy { onFrame($0.time) })
        #expect(updated.sections.allSatisfy { onFrame($0.start) && onFrame($0.end) && $0.duration >= frame })
    }

    @Test func conformingTakesTheClipsSizeRateAndColourSpace() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let media = MediaClip(
            name: "HDR", kind: .video, url: nil, duration: seconds(10),
            frameRate: 59.94, colorSpace: .rec2020PQ, codecName: "Stub"
        )
        let name = try #require(project.timeline(id: t)).name
        project.conformTimeline(t, to: media, frameSize: CGSize(width: 3840, height: 2160))
        let timeline = try #require(project.timeline(id: t))
        #expect(timeline.frameSize == CGSize(width: 3840, height: 2160))
        #expect(timeline.frameRate == 59.94)
        #expect(timeline.colorSpace == .rec2020PQ)
        #expect(timeline.name == name)
    }

    @Test func conformingToAStillKeepsTheRateAndAnUnknownSize() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        let before = try #require(project.timeline(id: t))
        let still = MediaClip(
            name: "Still", kind: .image, url: nil, duration: MediaClip.stillLength,
            frameRate: 0, colorSpace: .rec709, codecName: "PNG"
        )
        project.conformTimeline(t, to: still, frameSize: nil)
        let timeline = try #require(project.timeline(id: t))
        #expect(timeline.frameRate == before.frameRate)
        #expect(timeline.frameSize == before.frameSize)

        let song = MediaClip(name: "Song", kind: .audio, url: nil, duration: seconds(5), frameRate: 0, colorSpace: .rec2020PQ, codecName: "AAC")
        project.conformTimeline(t, to: song, frameSize: nil)
        #expect(try #require(project.timeline(id: t)).colorSpace == .rec709)
    }
}
