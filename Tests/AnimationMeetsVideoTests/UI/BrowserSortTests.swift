import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct BrowserSortTests {
    private func clip(_ name: String, _ kind: MediaKind, seconds: Double) -> MediaClip {
        MediaClip(name: name, kind: kind, url: nil, duration: CMTime(seconds: seconds, preferredTimescale: 600),
                  frameRate: kind == .video ? 24 : 0, colorSpace: .rec709, codecName: "Stub")
    }

    @Test func eachOrder() {
        let song = clip("Song", .audio, seconds: 200)
        let shot10 = clip("Shot 10", .video, seconds: 5)
        let still = clip("Poster", .image, seconds: 5)
        let shot2 = clip("Shot 2", .video, seconds: 30)
        let clips = [song, shot10, still, shot2]
        func names(_ order: BrowserSort) -> [String] { order.ordered(clips).map(\.name) }

        #expect(names(.added) == ["Song", "Shot 10", "Poster", "Shot 2"])
        // As the Finder sorts: 2 before 10.
        #expect(names(.name) == ["Poster", "Shot 2", "Shot 10", "Song"])
        // The longest first; equal lengths as imported.
        #expect(names(.duration) == ["Song", "Shot 2", "Shot 10", "Poster"])
        #expect(names(.kind) == ["Shot 2", "Shot 10", "Poster", "Song"])
    }

    @Test func timelinesSortByNameUnderMainFirst() {
        var project = EditingProject.empty
        let size = CGSize(width: 1920, height: 1080)
        let zed = project.addTimeline(name: "Zed", frameSize: size, frameRate: 24, colorSpace: .rec709)
        let alpha = project.addTimeline(name: "Alpha", frameSize: size, frameRate: 24, colorSpace: .rec709)
        #expect(TimelinesList.nodes(of: project).map(\.timelineID) == [project.rootTimelineID, zed, alpha])
        #expect(TimelinesList.nodes(of: project, sort: .name).map(\.timelineID) == [project.rootTimelineID, alpha, zed])
    }
}
