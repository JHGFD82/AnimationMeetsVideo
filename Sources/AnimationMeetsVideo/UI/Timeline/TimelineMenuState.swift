import CoreMedia
import SwiftUI

/// What the Timeline menu can do right now, so each item is offered only
/// when it would do something: Delete Selection with something selected,
/// a nudge with clips that can move that way, a split where the playhead
/// is in a clip, a step or jump with somewhere to go, a zoom short of its
/// limit. `TimelineMenuStatePublisher` works it out.
struct TimelineMenuState: Equatable {
    var canPlay = false
    var canGoBack = false
    var canGoForward = false
    var hasPreviousEdit = false
    var hasNextEdit = false
    var canSplit = false
    var canSplitAll = false
    var canNudgeEarlier = false
    var canNudgeLater = false
    var canDelete = false
    /// The clips Turn Off or On acts on, and what it would do to them;
    /// nil with none.
    var enabledToggle: EnabledToggle?
    var canZoomIn = false
    var canZoomOut = false

    enum EnabledToggle: Equatable {
        case turnOff(count: Int)
        case turnOn(count: Int)

        var title: String {
            switch self {
            case .turnOff(let count): count == 1 ? "Turn Clip Off" : "Turn Clips Off"
            case .turnOn(let count): count == 1 ? "Turn Clip On" : "Turn Clips On"
            }
        }
    }

    /// What depends on the selection, which the timeline's body already
    /// follows.
    struct Selection: Equatable {
        /// The clips a split, nudge or Turn Off acts on: those picked
        /// together, else the selected clip.
        var clips: Set<UUID>
        var canDelete: Bool
    }

    /// Works out the state for `timeline` with the playhead at `time`;
    /// nil, with no time to go by, offers every playhead item. `locked`
    /// are clips the motion designer has open, which nothing here may
    /// change (`ProjectState.lockedClipIDs`): an item that would touch one
    /// isn't offered.
    static func make(
        timeline: Timeline, selection: Selection, parkedAt time: CMTime?,
        zoomFraction: Double, isFitted: Bool, locked: Set<UUID> = []
    ) -> TimelineMenuState {
        var state = TimelineMenuState()
        let hasLength = timeline.duration > .zero
        state.canPlay = hasLength
        let clips = timeline.layers.flatMap(\.clips)
        let chosen = clips.filter { selection.clips.contains($0.id) }
        let touchesLocked = chosen.contains { locked.contains($0.id) }
        /// A split cuts every clip it finds, so one locked clip among them
        /// refuses it whole.
        func canSplit(_ found: [(layerID: UUID, clipID: UUID)]) -> Bool {
            !found.isEmpty && !found.contains { locked.contains($0.clipID) }
        }
        if let time {
            let now = timeline.snappedToFrame(time)
            let end = timeline.snappedToFrame(timeline.duration)
            state.canGoBack = now > .zero
            state.canGoForward = now < end
            let edges = clips.flatMap { [$0.startOffset, $0.endOffset] }.map { timeline.snappedToFrame($0) } + [end]
            state.hasPreviousEdit = edges.contains { $0 < now }
            state.hasNextEdit = edges.contains { $0 > now }
            state.canSplit = canSplit(timeline.clipsToSplit(at: now, selected: selection.clips, everyClip: false))
            state.canSplitAll = canSplit(timeline.clipsToSplit(at: now, selected: selection.clips, everyClip: true))
        } else {
            state.canGoBack = hasLength
            state.canGoForward = hasLength
            state.hasPreviousEdit = hasLength
            state.hasNextEdit = hasLength
            state.canSplit = clips.contains { !locked.contains($0.id) }
            state.canSplitAll = state.canSplit
        }
        if !chosen.isEmpty, !touchesLocked {
            // Clips move no further back than the timeline's start.
            state.canNudgeEarlier = chosen.map(\.startOffset).min().map { $0 > .zero } ?? false
            state.canNudgeLater = true
            state.enabledToggle = chosen.allSatisfy { !$0.enabled }
                ? .turnOn(count: chosen.count)
                : .turnOff(count: chosen.count)
        }
        state.canDelete = selection.canDelete && !touchesLocked
        state.canZoomIn = hasLength && zoomFraction < 1 - 1e-6
        state.canZoomOut = !isFitted
        return state
    }
}

private struct TimelineMenuStateKey: FocusedValueKey {
    typealias Value = TimelineMenuState
}

extension FocusedValues {
    var timelineMenuState: TimelineMenuState? {
        get { self[TimelineMenuStateKey.self] }
        set { self[TimelineMenuStateKey.self] = newValue }
    }
}

/// Publishes the Timeline menu's state from a view of its own, which
/// follows the playhead and the zoom so the timeline's body doesn't have
/// to: only this is worked out again on a scrub, and the menu bar is
/// rebuilt only when an item would turn on or off.
///
/// While playing it checks the playing time once a frame, so Split and
/// the jumps are offered exactly where they would act, mid-playback too.
/// PERFORMANCE NOTE: this is the one place the menu follows playback. If
/// playback or the menu bar feels slow, try lowering `playingChecksPerSecond`
/// (or check only while a menu is open) before looking elsewhere; see
/// docs/loose-ends.md.
struct TimelineMenuStatePublisher: View {
    let timeline: Timeline
    let selection: TimelineMenuState.Selection
    let playhead: PlayheadState
    let playback: PlaybackModel
    let viewportModel: TimelineViewportModel
    let viewport: () -> TimelineViewport
    /// Clips open in the motion designer, which no item may touch.
    let locked: Set<UUID>

    /// How often the playing time is checked: once a frame, at most 60.
    private var playingChecksPerSecond: Double { min(60, max(1, timeline.frameRate)) }

    var body: some View {
        if playback.isPlaying {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1 / playingChecksPerSecond)) { _ in
                published(at: playhead.actionTime)
            }
        } else {
            published(at: playhead.time)
        }
    }

    private func published(at time: CMTime) -> some View {
        let state = TimelineMenuState.make(
            timeline: timeline, selection: selection, parkedAt: time,
            zoomFraction: viewport().zoomFraction,
            isFitted: viewportModel.zoomedPixelsPerSecond == nil,
            locked: locked
        )
        return Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .focusedSceneValueUnlessDrafting(\.timelineMenuState, state)
    }
}
