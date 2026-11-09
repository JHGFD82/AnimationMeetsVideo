import CoreMedia
import SwiftUI

/// What the Timeline menu can do right now, so each item is offered only
/// when it would do something: Delete Selection with something selected,
/// a nudge with clips that can move that way, a split where the playhead
/// is in a clip, a step or jump with somewhere to go, a zoom short of its
/// limit. `TimelineMenuStatePublisher` works it out.
struct TimelineMenuState: Equatable {
    var canPlay = false
    /// While playing, the playhead isn't followed here (it would rebuild
    /// the menu bar on every tick), so the moves that depend on where it
    /// is stay offered and the actions decide.
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

    /// Works out the state for `timeline` with the playhead parked at
    /// `time` (nil while playing).
    static func make(
        timeline: Timeline, selection: Selection, parkedAt time: CMTime?,
        zoomFraction: Double, isFitted: Bool
    ) -> TimelineMenuState {
        var state = TimelineMenuState()
        let hasLength = timeline.duration > .zero
        state.canPlay = hasLength
        let clips = timeline.layers.flatMap(\.clips)
        let chosen = clips.filter { selection.clips.contains($0.id) }
        if let time {
            let now = timeline.snappedToFrame(time)
            let end = timeline.snappedToFrame(timeline.duration)
            state.canGoBack = now > .zero
            state.canGoForward = now < end
            let edges = clips.flatMap { [$0.startOffset, $0.endOffset] }.map { timeline.snappedToFrame($0) } + [end]
            state.hasPreviousEdit = edges.contains { $0 < now }
            state.hasNextEdit = edges.contains { $0 > now }
            state.canSplit = !timeline.clipsToSplit(at: now, selected: selection.clips, everyClip: false).isEmpty
            state.canSplitAll = !timeline.clipsToSplit(at: now, selected: selection.clips, everyClip: true).isEmpty
        } else {
            state.canGoBack = hasLength
            state.canGoForward = hasLength
            state.hasPreviousEdit = hasLength
            state.hasNextEdit = hasLength
            state.canSplit = !clips.isEmpty
            state.canSplitAll = !clips.isEmpty
        }
        if !chosen.isEmpty {
            // Clips move no further back than the timeline's start.
            state.canNudgeEarlier = chosen.map(\.startOffset).min().map { $0 > .zero } ?? false
            state.canNudgeLater = true
            state.enabledToggle = chosen.allSatisfy { !$0.enabled }
                ? .turnOn(count: chosen.count)
                : .turnOff(count: chosen.count)
        }
        state.canDelete = selection.canDelete
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
/// follows the parked playhead and the zoom so the timeline's body doesn't
/// have to: only this is worked out again on a scrub, and the menu bar is
/// rebuilt only when an item would turn on or off.
struct TimelineMenuStatePublisher: View {
    let timeline: Timeline
    let selection: TimelineMenuState.Selection
    let playhead: PlayheadState
    let playback: PlaybackModel
    let viewportModel: TimelineViewportModel
    let viewport: () -> TimelineViewport

    var body: some View {
        let shown = viewport()
        let state = TimelineMenuState.make(
            timeline: timeline, selection: selection,
            parkedAt: playback.isPlaying ? nil : playhead.time,
            zoomFraction: shown.zoomFraction,
            isFitted: viewportModel.zoomedPixelsPerSecond == nil
        )
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .focusedSceneValueUnlessDrafting(\.timelineMenuState, state)
    }
}
