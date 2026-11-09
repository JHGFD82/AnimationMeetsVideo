import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The Timeline menu offers an item only when it would do something.
@MainActor @Suite struct TimelineMenuStateTests {
    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    /// A root timeline holding one ten-second clip at `start`.
    private func timeline(clipAt start: Double = 0) throws -> (Timeline, UUID) {
        var project = EditingProject.empty
        let media = MediaClip(name: "Clip", kind: .video, url: nil, duration: seconds(10), frameRate: 24, colorSpace: .rec709, codecName: "H.264")
        let imported = project.importClip(media, intoTimeline: project.rootTimelineID)
        let ids = try #require(imported)
        project.moveClip(ids.clipID, in: project.rootTimelineID, layer: ids.layerID, to: seconds(start))
        return (try #require(project.timeline(id: project.rootTimelineID)), ids.clipID)
    }

    private func state(
        _ timeline: Timeline, clips: Set<UUID> = [], canDelete: Bool = false, at time: Double? = 0,
        zoom: Double = 0, fitted: Bool = true, locked: Set<UUID> = []
    ) -> TimelineMenuState {
        TimelineMenuState.make(
            timeline: timeline, selection: .init(clips: clips, canDelete: canDelete),
            parkedAt: time.map { seconds($0) }, zoomFraction: zoom, isFitted: fitted, locked: locked
        )
    }

    @Test func aClipOpenInTheMotionDesignerIsOfferedNothing() throws {
        let (timeline, clip) = try timeline(clipAt: 2)
        let shown = state(timeline, clips: [clip], canDelete: true, at: 5, locked: [clip])
        #expect(!shown.canDelete)
        #expect(!shown.canNudgeEarlier && !shown.canNudgeLater)
        #expect(shown.enabledToggle == nil)
        #expect(!shown.canSplit && !shown.canSplitAll)
        // With nothing selected, a split at the playhead would cut it too.
        let unselected = state(timeline, at: 5, locked: [clip])
        #expect(!unselected.canSplit && !unselected.canSplitAll)
        // Away from it, the playhead items are as ever.
        let before = state(timeline, at: 1, locked: [clip])
        #expect(before.canGoBack && before.hasNextEdit)
        // With no time to go by, a split needs a clip that isn't locked.
        #expect(!state(timeline, at: nil, locked: [clip]).canSplit)
        // Unlocked, all of it comes back.
        let free = state(timeline, clips: [clip], canDelete: true, at: 5)
        #expect(free.canDelete && free.canSplit && free.enabledToggle != nil)
    }

    @Test func nothingSelectedOffersNoSelectionItems() throws {
        let (timeline, _) = try timeline()
        let shown = state(timeline, at: 5)
        #expect(!shown.canDelete)
        #expect(!shown.canNudgeEarlier && !shown.canNudgeLater)
        #expect(shown.enabledToggle == nil)
        // A split with nothing selected cuts every clip there.
        #expect(shown.canSplit && shown.canSplitAll)
    }

    @Test func aSelectedClipOffersWhatActsOnIt() throws {
        let (timeline, clip) = try timeline(clipAt: 2)
        let shown = state(timeline, clips: [clip], canDelete: true, at: 5)
        #expect(shown.canDelete)
        #expect(shown.canNudgeEarlier && shown.canNudgeLater)
        #expect(shown.enabledToggle == .turnOff(count: 1))
        #expect(shown.enabledToggle?.title == "Turn Clip Off")
    }

    @Test func aClipAtTheStartCantBeNudgedEarlier() throws {
        let (timeline, clip) = try timeline(clipAt: 0)
        let shown = state(timeline, clips: [clip], canDelete: true)
        #expect(!shown.canNudgeEarlier)
        #expect(shown.canNudgeLater)
    }

    @Test func thePlayheadDecidesSteppingJumpingAndSplitting() throws {
        let (timeline, clip) = try timeline(clipAt: 2)
        let atStart = state(timeline, at: 0)
        #expect(!atStart.canGoBack && atStart.canGoForward)
        #expect(!atStart.hasPreviousEdit && atStart.hasNextEdit)
        #expect(!atStart.canSplit && !atStart.canSplitAll)
        let atEnd = state(timeline, clips: [clip], at: timeline.duration.seconds)
        #expect(atEnd.canGoBack && !atEnd.canGoForward)
        #expect(atEnd.hasPreviousEdit && !atEnd.hasNextEdit)
        // A selected clip the playhead isn't in isn't split.
        #expect(!atEnd.canSplit)
    }

    @Test func withNoTimeEveryPlayheadItemIsOffered() throws {
        let (timeline, _) = try timeline()
        let shown = state(timeline, at: nil)
        #expect(shown.canGoBack && shown.canGoForward && shown.hasPreviousEdit && shown.hasNextEdit && shown.canSplit)
    }

    @Test func zoomStopsAtItsLimits() throws {
        let (timeline, _) = try timeline()
        let fitted = state(timeline, zoom: 0, fitted: true)
        #expect(fitted.canZoomIn && !fitted.canZoomOut)
        let closest = state(timeline, zoom: 1, fitted: false)
        #expect(!closest.canZoomIn && closest.canZoomOut)
    }
}
