import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// What follows a value drag held to one side of the project (see
/// `ProjectState`): the viewer, the sound and the graph windows through the
/// surface, and, in the panel, the other axis of a linked control. Other
/// views show the project as it was until the drag ends.
@MainActor
struct HeldDragFollowTests {
    /// The effects panel's rows up to where their values end, as a picture:
    /// not the reset button after them, which is there once a value is
    /// changed in the project, and not the lanes, which have the playhead.
    private func picture(of host: NSHostingView<some View>) throws -> Data {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let labels = CGRect(x: 0, y: 0, width: 260 * scale, height: CGFloat(rep.pixelsHigh))
        let image = try #require(rep.cgImage?.cropping(to: labels))
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    @Test func aLinkedSizesOtherAxisFollowsADragOfTheFirst() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let created = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(created)
        // A shape's axes aren't linked unless asked.
        project.editClip(shape.clipID, in: timelineID) { clip in
            for index in clip.effects[0].controls.indices where clip.effects[0].controls[index].kind == .shapeSize {
                clip.effects[0].controls[index].linked = true
            }
        }
        let selection = TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID)
        let state = ProjectState(project)
        let size = CGSize(width: 520, height: 420)
        let host = NSHostingView(rootView: EffectsPanel(
            project: Binding(get: { state.value }, set: { state.value = $0 }), timelineID: timelineID, selection: selection,
            playheadTime: .zero, state: EffectsPanelState(), onSeek: { _ in }, onSelectTransition: { _ in }
        ).environment(state).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host

        func widen(_ project: inout EditingProject) {
            project.editClip(shape.clipID, in: timelineID) { clip in
                for index in clip.effects[0].controls.indices where clip.effects[0].controls[index].kind == .shapeSize {
                    clip.effects[0].controls[index].setComponent(0, to: 777, at: .zero)
                }
            }
        }
        let before = try picture(of: host)

        // A step of the drag: the project is as it was, the held copy has both axes.
        state.beginHold()
        state.hold { widen(&state.value) }
        #expect(state.held != nil)
        let held = try picture(of: host)
        #expect(held != before)

        // Let go: the same edit lands in the project (and the reset button comes).
        state.endHold()
        widen(&state.value)
        let committed = try picture(of: host)
        #expect(held == committed)
    }
    /// A sound row's slider, beside the number being dragged, as a picture.
    private func row(_ value: Double, held: Double?) throws -> Data {
        let size = CGSize(width: 340, height: 40)
        let host = NSHostingView(rootView: AudioPropertyRow(
            value: AnimatedValue(value), playhead: PlayheadTime(fixed: .zero), onEdit: { _ in }, onSeek: { _ in },
            held: held.map { held in { AnimatedValue(held) } }
        ).frame(width: size.width, height: size.height).background(Color.black))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func aSoundRowsSliderFollowsADragOfItsNumber() throws {
        let asProject = try row(-12, held: nil)
        let asHeld = try row(0, held: -12)
        #expect(asHeld == asProject)
        #expect(try row(0, held: nil) != asProject)
    }
}
