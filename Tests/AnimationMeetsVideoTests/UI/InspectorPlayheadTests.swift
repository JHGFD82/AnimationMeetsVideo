import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The Inspector doesn't read the parked playhead as its body is built
/// (see `PlayheadState`): the layer's Sound rows follow it themselves, and
/// nothing else is redrawn.
@MainActor
struct InspectorPlayheadTests {
    /// The Inspector's picture, in turn, with the playhead at each of
    /// `times`, for a song on a Music layer whose volume is `animated` or not.
    private func pictures(animated: Bool, at times: [Double]) throws -> [Data] {
        let song = try SnapshotSupport.clickSong(named: "inspector-playhead-song", seconds: 4)
        var project = EditingProject.empty
        project.clips = [song]
        project.putOnMusicLayer([song.id])
        let timelineID = project.rootTimelineID
        let layer = try #require(project.timeline(id: timelineID)?.layers.first)
        let clip = try #require(layer.clips.first)
        if animated {
            project.editVolume(of: layer.id, in: timelineID) {
                $0.setAnimated(true, at: .zero)
                $0.set(1, at: .zero)
                $0.set(0.1, at: CMTime(seconds: 1, preferredTimescale: 600))
            }
        }
        let timelineClip = try #require(project.clipAndLayer(clip.id, in: timelineID)?.clip)
        let playhead = PlayheadState()
        let size = CGSize(width: 340, height: 520)
        let host = NSHostingView(rootView: InspectorPanel(
            project: .constant(project), timelineID: timelineID,
            selection: TimelineSelection(timelineID: timelineID, layerID: layer.id, timelineClipID: clip.id),
            info: .media(song), timelineClip: timelineClip, playhead: playhead, onSeek: { _ in }, onDeleteSelection: {}
        ).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        func settle() {
            for _ in 0..<5 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
            }
        }
        settle()
        return try times.map { seconds in
            playhead.time = CMTime(seconds: seconds, preferredTimescale: 600)
            settle()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return try #require(rep.representation(using: .png, properties: [:]))
        }
    }

    @Test func aRowWithAnimatedVolumeFollowsThePlayhead() throws {
        let shown = try pictures(animated: true, at: [0, 0.5, 1])
        #expect(shown[0] != shown[1])
        #expect(shown[1] != shown[2])
    }

    @Test func aFixedVolumeIsNotChangedByThePlayhead() throws {
        let shown = try pictures(animated: false, at: [0, 0.5, 1])
        #expect(shown[0] == shown[1])
        #expect(shown[1] == shown[2])
    }
}
