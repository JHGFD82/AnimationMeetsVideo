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
    private func picture(of host: NSHostingView<some View>, lanes: Bool = false) throws -> Data {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        // The values, or the lanes beside them (where a keyframe is drawn).
        let region = lanes
            ? CGRect(x: EffectsPanelMetrics.labelWidth * scale, y: 0, width: CGFloat(rep.pixelsWide) - EffectsPanelMetrics.labelWidth * scale, height: CGFloat(rep.pixelsHigh))
            : CGRect(x: 0, y: 0, width: 260 * scale, height: CGFloat(rep.pixelsHigh))
        let image = try #require(rep.cgImage?.cropping(to: region))
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// A rectangle's corner radius, whose reset arrow (beside the row's menu)
    /// appears with the first step of a held drag, not once it ends.
    @Test func aResetArrowAppearsAsADragIsHeld() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let created = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(created)
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

        /// The strip beside the rows' menus, where the arrow is.
        func arrows() throws -> Data {
            for _ in 0..<5 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                host.layoutSubtreeIfNeeded()
            }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            let strip = CGRect(x: 268 * scale, y: 0, width: 28 * scale, height: CGFloat(rep.pixelsHigh))
            let image = try #require(rep.cgImage?.cropping(to: strip))
            return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
        let before = try arrows()

        state.beginHold()
        state.hold {
            state.value.editClip(shape.clipID, in: timelineID) { clip in
                for index in clip.effects[0].controls.indices where clip.effects[0].controls[index].kind == .cornerRadius {
                    clip.effects[0].controls[index].setComponent(0, to: 40, at: .zero)
                }
            }
        }
        #expect(try arrows() != before, "The reset arrow should show while the drag is held")
        state.endHold()
    }

    /// A rectangle's corner radius with the stopwatch on and a keyframe at the
    /// start, the playhead a second in with none there.
    @Test func aKeyframeDraggedIntoBeingIsDrawnAtOnce() throws {
        var project = EditingProject.empty
        let timelineID = project.rootTimelineID
        let created = project.addShapeLayer(.rectangle, to: timelineID)
        let shape = try #require(created)
        project.editClip(shape.clipID, in: timelineID) { clip in
            for index in clip.effects[0].controls.indices where clip.effects[0].controls[index].kind == .cornerRadius {
                clip.effects[0].controls[index].number.setAnimated(true, at: .zero)
            }
        }
        let selection = TimelineSelection(timelineID: timelineID, layerID: shape.layerID, timelineClipID: shape.clipID)
        let state = ProjectState(project)
        let size = CGSize(width: 520, height: 420)
        let host = NSHostingView(rootView: EffectsPanel(
            project: Binding(get: { state.value }, set: { state.value = $0 }), timelineID: timelineID, selection: selection,
            playheadTime: CMTime(seconds: 1, preferredTimescale: 600), state: EffectsPanelState(), onSeek: { _ in },
            onSelectTransition: { _ in }
        ).environment(state).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host

        func drag(_ project: inout EditingProject) {
            project.editClip(shape.clipID, in: timelineID) { clip in
                for index in clip.effects[0].controls.indices where clip.effects[0].controls[index].kind == .cornerRadius {
                    clip.effects[0].controls[index].setComponent(0, to: 40, at: CMTime(seconds: 1, preferredTimescale: 600))
                }
            }
        }
        let before = try picture(of: host, lanes: true)

        state.beginHold()
        state.hold { drag(&state.value) }
        let held = try picture(of: host, lanes: true)
        #expect(held != before, "The keyframe should be in the lane while the drag is held")

        state.endHold()
        drag(&state.value)
        #expect(try picture(of: host, lanes: true) == held)
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

/// Where an action finds the playhead while the project plays.
@MainActor
struct PlayheadActionTimeTests {
    @Test func anActionReadsThePlayersTimeWhilePlayingAndTheParkedTimeOtherwise() {
        let playhead = PlayheadState(time: .zero)
        var playing: CMTime?
        playhead.liveTime = { playing }
        let time = PlayheadTime(playhead)
        #expect(time.current == .zero)

        playing = CMTime(seconds: 3, preferredTimescale: 600)
        #expect(time.current == playing)
        // What is drawn stays with the parked playhead.
        #expect(time.now == .zero)

        playing = nil
        playhead.time = CMTime(seconds: 1, preferredTimescale: 600)
        #expect(time.current == playhead.time)
    }
}
