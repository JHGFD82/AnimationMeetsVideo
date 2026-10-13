import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func video(url: URL? = nil, duration: Double = 10) -> MediaClip {
    MediaClip(name: "Clip", kind: .video, url: url, duration: seconds(duration), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
}

private func layers(_ project: EditingProject) -> [TimelineLayer] {
    project.timeline(id: project.rootTimelineID)?.layers ?? []
}

@Suite struct LayerArrangementTests {
    @Test func aLayerMovesToAnyPlaceInTheStack() throws {
        var project = EditingProject.empty
        let t = project.rootTimelineID
        for _ in 0..<3 { project.importClip(video(), intoTimeline: t) }
        let ids = layers(project).map(\.id)
        project.moveLayer(ids[0], in: t, toIndex: 2)
        #expect(layers(project).map(\.id) == [ids[1], ids[2], ids[0]])
        project.moveLayer(ids[0], in: t, toIndex: 0)
        #expect(layers(project).map(\.id) == ids)
    }
}
