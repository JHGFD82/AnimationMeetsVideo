import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The effects panel doesn't read the parked playhead as its body is built
/// (see `PlayheadState`): the rows that show a value at the playhead follow
/// it themselves, and the rest aren't redrawn.
@MainActor
struct EffectsPanelPlayheadTests {
    /// A rectangle clip with its corner radius, `animated` or not.
    private func project(animated: Bool) throws -> (EditingProject, UUID, TimelineSelection) {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let created = project.addShapeLayer(.rectangle, to: timelineID)
        let added = try #require(created)
        project.editClip(added.clipID, in: timelineID) { clip in
            for index in clip.effects[0].controls.indices where clip.effects[0].controls[index].kind == .cornerRadius {
                if animated {
                    clip.effects[0].controls[index].number.setAnimated(true, at: .zero)
                    clip.effects[0].controls[index].number.set(ComponentValue(values: [10]), at: .zero)
                    clip.effects[0].controls[index].number.set(ComponentValue(values: [90]), at: CMTime(seconds: 1, preferredTimescale: 600))
                } else {
                    clip.effects[0].controls[index].number = AnimatedValue(ComponentValue(values: [24]))
                }
            }
        }
        let selection = TimelineSelection(timelineID: timelineID, layerID: added.layerID, timelineClipID: added.clipID)
        return (project, timelineID, selection)
    }

    /// The panel's picture with the playhead at each of `times`, in turn.
    private func pictures(animated: Bool, at times: [Double]) throws -> [Data] {
        let (project, timelineID, selection) = try project(animated: animated)
        let playhead = PlayheadState()
        let size = CGSize(width: 520, height: 420)
        let host = NSHostingView(rootView: EffectsPanel(
            project: .constant(project), timelineID: timelineID, selection: selection, playhead: playhead,
            state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
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
            // The label column, where the values are: the lanes beside it
            // have the playhead's line in them, which moves.
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            let labels = CGRect(x: 0, y: 0, width: EffectsPanelMetrics.labelWidth * scale, height: CGFloat(rep.pixelsHigh))
            let image = try #require(rep.cgImage?.cropping(to: labels))
            return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
    }

    @Test func aRowWithAnimatedValueFollowsThePlayhead() throws {
        let shown = try pictures(animated: true, at: [0, 0.5, 1])
        #expect(shown[0] != shown[1])
        #expect(shown[1] != shown[2])
    }

    @Test func aRowWithAFixedValueIsNotRedrawnByThePlayhead() throws {
        let shown = try pictures(animated: false, at: [0, 0.5, 1])
        #expect(shown[0] == shown[1])
        #expect(shown[1] == shown[2])
    }
}
