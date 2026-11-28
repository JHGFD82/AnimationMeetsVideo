import CoreMedia
import SwiftUI

// A layer's parameter rows (docs/parameter-rows.md): what each row shows
// at the playhead, and what its value field, stopwatch, keyframe buttons,
// arrow and diamonds do, for `TimelineAreas` to lay out beside the volume
// rows.
extension TimelineView {
    /// The rows of `block` in the names column, at the parked playhead.
    func parameterHeaders(of block: LayerBlock) -> some View {
        let layer = block.layer
        return PlayheadReader(playhead: playhead) { parked in
            let time = timeline.snappedToFrame(parked)
            ParameterRowHeaders(
                groups: block.parameterGroups,
                isClosed: { parameterRows.isClosed($0, on: layer.id) },
                onToggle: { key, all in toggleParameterGroup(key, of: block, all: all) },
                state: { parameterRowState($0, on: layer, at: time) },
                onSetComponent: { row, index, value in
                    editParameterRow(row, on: layer, at: time) { control, source in control.setComponent(index, to: value, at: source) }
                },
                onToggleAnimated: { row in
                    let animated = parameterRowState(row, on: layer, at: time).isAnimated
                    editParameterRow(row, on: layer, at: time) { control, source in control.number.setAnimated(!animated, at: source) }
                },
                onToggleKeyframe: { row in
                    editParameterRow(row, on: layer, at: time) { control, source in control.number.toggleKeyframe(at: source) }
                },
                onRemove: { row in viewMemory?.parameterRows.change(timelineID) { $0.remove([row.key], from: row.clips) } },
                onSeek: scrubAction,
                time: time
            )
        }
    }

    /// The rows of `block` under its clips.
    func parameterLanes(of block: LayerBlock, pixelsPerSecond: CGFloat, width: CGFloat) -> some View {
        let layer = block.layer
        let timelineID = timelineID
        return PlayheadReader(playhead: playhead) { parked in
            ParameterRowLanes(
                groups: block.parameterGroups,
                isClosed: { parameterRows.isClosed($0, on: layer.id) },
                lane: { row in ParameterLaneMarks(row.key, of: layer.clips.filter { row.clips.contains($0.id) }, frame: timeline.frameDuration) },
                currentTime: timeline.snappedToFrame(parked),
                pixelsPerSecond: pixelsPerSecond,
                width: width,
                snap: { timeline.snappedToFrame($0) },
                onSeek: scrubAction,
                onEdit: { row, clipID, change in
                    // The host applies the change before `dispatch`
                    // returns, so the action needn't keep it.
                    withoutActuallyEscaping(change) { change in
                        host.dispatch(TimelineAction.editProject { project in
                            guard let clip = project.clipAndLayer(clipID, in: timelineID)?.clip, let parameter = clip.parameter(row.key) else { return }
                            let controlID = parameter.control.id
                            project.editEffect(parameter.effect.id, ofClip: clipID, in: timelineID) { effect in
                                if let c = effect.controlIndex(controlID) { change(&effect.controls[c].number) }
                            }
                        })
                    }
                }
            )
        }
    }

    /// What `row` shows at timeline `time`: the value of the clips it acts
    /// on, whether they are keyframed, and every keyframe on the row.
    func parameterRowState(_ row: TimelineParameterRow, on layer: TimelineLayer, at time: CMTime) -> ParameterRowState {
        let acting = project.parameterActingClips(row, on: layer, selected: selectedClipIDs, at: time)
        let clips = layer.clips.filter { row.clips.contains($0.id) }
        let kind = clips.lazy.compactMap { $0.parameter(row.key)?.control.kind }.first
        return ParameterRowState(
            values: acting.isEmpty ? nil : project.parameterValue(row.key, of: acting, at: time, frame: project.timeline(id: timelineID)?.frameDuration ?? .zero),
            actingClipCount: acting.count,
            isAnimated: acting.contains { $0.parameter(row.key)?.control.isAnimated == true },
            keyframeTimes: ParameterLaneMarks(row.key, of: clips, frame: project.timeline(id: timelineID)?.frameDuration ?? .zero).marks.map(\.time),
            unit: kind?.unit ?? "",
            dragStep: kind?.dragStep ?? 1,
            range: kind?.range,
            componentNames: kind?.componentNames ?? []
        )
    }

    /// Changes `row`'s control on each clip it acts on at `time`, at the
    /// playhead's time in each, as one edit; a driven control refuses it,
    /// as every hand edit of one is refused.
    func editParameterRow(
        _ row: TimelineParameterRow, on layer: TimelineLayer, at time: CMTime, _ change: @escaping (inout EffectControl, CMTime) -> Void
    ) {
        let clips = project.parameterActingClips(row, on: layer, selected: selectedClipIDs, at: time).map(\.id)
        guard !clips.isEmpty else { return }
        let timelineID = timelineID
        host.dispatch(TimelineAction.editProject { $0.editParameter(row.key, of: clips, in: timelineID, change, at: time) })
    }

    /// Opens or closes an effect's rows on a layer; with `all`, every one
    /// of its effects as this one goes.
    func toggleParameterGroup(_ effectKey: String, of block: LayerBlock, all: Bool) {
        let layerID = block.layer.id
        let closes = !parameterRows.isClosed(effectKey, on: layerID)
        let keys = all ? block.parameterGroups.map(\.effectKey) : [effectKey]
        viewMemory?.parameterRows.change(timelineID) { rows in
            for key in keys { rows.setClosed(closes, key, on: layerID) }
        }
    }
}
