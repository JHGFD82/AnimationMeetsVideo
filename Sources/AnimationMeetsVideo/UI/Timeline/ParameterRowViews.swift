import AppKit
import CoreMedia
import SwiftUI

// A layer's parameter rows in the timeline (see docs/parameter-rows.md):
// in the names column, each effect as a row with an arrow and its
// controls under it, each with its value at the playhead, its stopwatch
// and keyframe buttons and a menu; under the clips, each control's
// keyframes as diamonds, in the timeline's time.

enum ParameterRowMetrics {
    /// An effect's row, which holds its arrow and name.
    static let groupHeight: CGFloat = 20
    /// A control's row.
    static let rowHeight: CGFloat = 24

    /// How tall a layer's rows are, effects closed by `isClosed` showing
    /// only their own row.
    static func height(of groups: [ParameterRowGroup], isClosed: (String) -> Bool) -> CGFloat {
        groups.reduce(0) { total, group in
            total + groupHeight + (isClosed(group.effectKey) ? 0 : CGFloat(group.rows.count) * rowHeight)
        }
    }
}

/// A layer's parameter rows in the names column.
struct ParameterRowHeaders: View {
    let groups: [ParameterRowGroup]
    let isClosed: (String) -> Bool
    /// Opens or closes an effect's rows; with every other effect's too when
    /// Option is held, as in the Finder.
    let onToggle: (_ effectKey: String, _ all: Bool) -> Void
    /// What a row shows and changes at the playhead.
    let state: (TimelineParameterRow) -> ParameterRowState
    let onSetComponent: (TimelineParameterRow, Int, Double) -> Void
    let onToggleAnimated: (TimelineParameterRow) -> Void
    let onToggleKeyframe: (TimelineParameterRow) -> Void
    let onRemove: (TimelineParameterRow) -> Void
    let onSeek: (CMTime) -> Void
    /// The playhead, snapped to a frame.
    let time: CMTime

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                let closed = isClosed(group.effectKey)
                HStack(spacing: 4) {
                    DisclosureChevron(isExpanded: !closed, label: "\(group.name)'s rows") {
                        onToggle(group.effectKey, NSEvent.modifierFlags.contains(.option))
                    }
                    Text(group.name)
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 30)
                .frame(height: ParameterRowMetrics.groupHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(group.name)
                .accessibilityValue(closed ? "Closed" : "Open")
                .accessibilityAction(named: closed ? "Open" : "Close") { onToggle(group.effectKey, false) }
                if !closed {
                    ForEach(group.rows) { row in
                        controlRow(row)
                    }
                }
            }
        }
    }

    private func controlRow(_ row: TimelineParameterRow) -> some View {
        let shown = state(row)
        let lowercase = row.name.lowercased()
        return HStack(spacing: 4) {
            AnimateToggle(name: lowercase, isAnimated: shown.isAnimated) { onToggleAnimated(row) }
                .disabled(shown.actingClipCount == 0)
            Text(row.name)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)
            if let values = shown.values {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    NumericField(
                        value: value, unit: shown.unit, fractionDigits: shown.dragStep < 1 ? 2 : 1, dragStep: shown.dragStep,
                        dragRange: shown.range, accessibilityName: values.count > 1 ? "\(row.name) \(shown.componentNames[safe: index] ?? "")" : row.name
                    ) { newValue in
                        onSetComponent(row, index, newValue)
                    }
                    .frame(width: values.count > 2 ? 40 : 56, alignment: .leading)
                }
            } else {
                Text(shown.actingClipCount == 0 ? "—" : "Mixed")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textTertiary)
                    .help(shown.actingClipCount == 0
                          ? "No clip with this setting is under the playhead or selected"
                          : "The clips it changes differ here")
                    .accessibilityLabel("\(row.name), \(shown.actingClipCount == 0 ? "no clip" : "mixed")")
            }
            Spacer(minLength: 4)
            if !shown.keyframeTimes.isEmpty {
                KeyframeNavigator(name: lowercase, keyframeTimes: shown.keyframeTimes, time: time, onSeek: onSeek) { onToggleKeyframe(row) }
            }
            Menu {
                Button("Remove from Timeline") { onRemove(row) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Remove from Timeline")
            .accessibilityLabel("\(row.name) options")
        }
        .padding(.leading, 34)
        .padding(.trailing, 8)
        .frame(height: ParameterRowMetrics.rowHeight)
        .contextMenu { Button("Remove from Timeline") { onRemove(row) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
        .accessibilityAction(named: "Remove from Timeline") { onRemove(row) }
    }
}

/// What a parameter row shows at the playhead, worked out by the timeline.
struct ParameterRowState {
    /// Its value at the playhead, or nil when the clips it acts on differ
    /// or there are none.
    var values: [Double]?
    var actingClipCount: Int
    var isAnimated: Bool
    /// Every keyframe of every clip on the row, in the timeline's time.
    var keyframeTimes: [CMTime]
    var unit: String
    var dragStep: Double
    var range: ClosedRange<Double>?
    var componentNames: [String]
}

/// A layer's parameter rows under its clips: each control's keyframes of
/// every clip on its row, in the timeline's time, to click, drag and
/// delete as on a volume row.
struct ParameterRowLanes: View {
    let groups: [ParameterRowGroup]
    let isClosed: (String) -> Bool
    /// Each row's keyframes, and the clip and source time each is at.
    let lane: (TimelineParameterRow) -> ParameterLaneMarks
    let currentTime: CMTime
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let snap: (CMTime) -> CMTime
    let onSeek: (CMTime) -> Void
    /// Changes one clip's keyframes of a row, in its source time.
    let onEdit: (TimelineParameterRow, UUID, (inout AnimatedValue<ComponentValue>) -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                Color.clear.frame(width: width, height: ParameterRowMetrics.groupHeight)
                if !isClosed(group.effectKey) {
                    ForEach(group.rows) { row in
                        let marks = lane(row)
                        KeyframeLane(
                            marks: marks.marks,
                            currentTime: currentTime,
                            pixelsPerSecond: pixelsPerSecond,
                            width: width,
                            height: ParameterRowMetrics.rowHeight,
                            snap: snap,
                            onSeek: onSeek,
                            onMove: { from, to, copy in
                                guard let at = marks.places[from] else { return }
                                let target = at.clip.shownSourceTime(atTimelineTime: to, frame: marks.frame)
                                onEdit(row, at.clip.id) { $0.moveKeyframe(at: at.source, to: target, copying: copy) }
                            },
                            onDelete: { time in
                                guard let at = marks.places[time] else { return }
                                onEdit(row, at.clip.id) { $0.removeKeyframe(at: at.source) }
                            },
                            onEase: { time, preset in
                                guard let at = marks.places[time] else { return }
                                onEdit(row, at.clip.id) { $0.applyEase(preset, at: at.source) }
                            }
                        )
                    }
                }
            }
        }
    }
}

/// A row's keyframes as its lane draws them, in the timeline's time, and
/// the clip and source time each of them is at.
struct ParameterLaneMarks {
    var marks: [KeyframeMark] = []
    var places: [CMTime: (clip: TimelineClip, source: CMTime)] = [:]
    /// The timeline's frame, for where a source time is shown.
    var frame: CMTime

    /// Those of `clips` for `key`, each where it plays, only those inside
    /// the clip's trim. Where two clips' keyframes fall at one time, the
    /// first's is kept.
    init(_ key: ParameterRowKey, of clips: [TimelineClip], frame: CMTime) {
        self.frame = frame
        for clip in clips {
            guard let parameter = clip.parameter(key) else { continue }
            for mark in parameter.control.number.marks where mark.time >= clip.trimStart && mark.time <= clip.trimEnd {
                let time = clip.timelineTime(forShownSourceTime: mark.time, frame: frame)
                guard places[time] == nil else { continue }
                var placed = mark
                placed.time = time
                marks.append(placed)
                places[time] = (clip, mark.time)
            }
        }
        marks.sort { $0.time < $1.time }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
