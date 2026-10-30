import AppKit
import CoreMedia
import SwiftUI
import Testing
@testable import AnimationMeetsVideo

/// The Timelines tab's filmstrips skimmed and opened with real events (see
/// `EventHarness`; run with `UI_EVENTS=1`).
@MainActor
@Suite(.serialized, .enabled(if: EventHarness.isEnabled))
struct TimelineFilmstripsInteractionTests {
    private static let size = CGSize(width: 400, height: 300)

    /// The Main timeline, four seconds of an adjustment clip.
    private func project() -> EditingProject {
        var project = EditingProject.empty
        let clip = TimelineClip(source: .adjustment, startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        project.timelines[0].layers = [TimelineLayer(customName: nil, kind: .video, clips: [clip])]
        return project
    }

    private struct Host: View {
        let project: EditingProject
        let skim: BrowserSkim
        let onOpen: (UUID) -> Void
        @State var picked = BrowserSelection<UUID>()
        @State var renamingID: UUID?
        @State var dropHovered: Set<TimelineDropPart> = []

        var body: some View {
            TimelineFilmstrips(
                project: project, activeTimelineID: project.rootTimelineID, order: project.timelines.map(\.id),
                picked: $picked, renamingID: $renamingID, dropHovered: $dropHovered,
                onOpen: onOpen, onRename: { _, _ in }, onEmbedInto: { _, _ in false },
                onEmbed: { _ in }, onDuplicate: { _ in }, onDelete: { _ in }, onFindAll: { _ in },
                menu: { _ in AnyView(EmptyView()) }
            )
            .environment(skim)
        }
    }

    /// The strip's mouse view. The harness's borderless window never
    /// becomes key, so its tracking area, active only in the key window,
    /// doesn't see the pointer: moves are handed to it as that would.
    private func stripView(in harness: EventHarness) throws -> NSView {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let root = try #require(harness.window.contentView)
        return try #require(all(root).first { $0 is FilmstripMouseView.MouseView })
    }

    private func event(_ type: NSEvent.EventType, at x: CGFloat, over view: NSView, in harness: EventHarness) throws -> NSEvent {
        let rect = view.convert(view.bounds, to: nil)
        return try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: rect.minX + x, y: rect.midY), modifierFlags: [], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
    }

    @Test func aTimelineOpenedFromItsStripIsntSkimmedUntilThePointerLeaves() async throws {
        let project = project()
        let skim = BrowserSkim()
        defer { skim.end() }
        var opened: [UUID] = []
        // As the editor does, opening ends the skim.
        let harness = EventHarness(Host(project: project, skim: skim) { opened.append($0); skim.end() }, size: Self.size)
        try await harness.settle()
        let strip = try stripView(in: harness)

        strip.mouseMoved(with: try event(.mouseMoved, at: 20, over: strip, in: harness))
        try await harness.settle()
        #expect(skim.isActive)

        let rect = strip.convert(strip.bounds, to: nil)
        try await harness.doubleClick(at: CGPoint(x: rect.minX + 20, y: harness.window.frame.height - rect.midY))
        #expect(opened == [project.rootTimelineID])
        #expect(!skim.isActive)

        // Still over the strip: no skim.
        strip.mouseMoved(with: try event(.mouseMoved, at: 60, over: strip, in: harness))
        try await harness.settle()
        #expect(!skim.isActive)

        // Out and back in, it skims again.
        strip.mouseExited(with: try event(.mouseMoved, at: 200, over: strip, in: harness))
        strip.mouseMoved(with: try event(.mouseMoved, at: 20, over: strip, in: harness))
        try await harness.settle()
        #expect(skim.isActive)
    }
}
