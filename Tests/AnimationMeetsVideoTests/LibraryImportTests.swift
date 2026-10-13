import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func videoWithSound(url: URL? = nil, duration: Double = 10) -> MediaClip {
    MediaClip(
        name: "Clip", kind: .video, url: url, duration: seconds(duration),
        frameRate: 24, colorSpace: .rec709, codecName: "H.264", hasAudio: true
    )
}

@Suite struct ImportTests {
    @Test func addingMediaLeavesTheTimelineEmpty() {
        var project = EditingProject.empty
        let media = videoWithSound()
        project.addMedia(media)
        #expect(project.clips.map(\.id) == [media.id])
        #expect(project.timeline(id: project.rootTimelineID)?.layers.isEmpty == true)

        let placed = project.placeAsset(media.id, intoTimeline: project.rootTimelineID)
        let layer = project.timeline(id: project.rootTimelineID)?.layers.first
        #expect(layer?.id == placed?.layerID)
        #expect(layer?.clips.first?.trimEnd == media.duration)
    }
}
