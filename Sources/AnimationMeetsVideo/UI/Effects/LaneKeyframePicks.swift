import CoreMedia
import Observation
import SwiftUI

/// What a lane of the effects panel does to its keyframes, by their source
/// times: made from the one edit of the value it shows, so every kind of
/// lane (a control, a font axis, a run's setting, speed, volume) offers
/// the same.
struct LaneKeyframeEdits {
    /// From, to, and whether Option copies it instead.
    var move: (CMTime, CMTime, Bool) -> Void
    /// Several at once, from where each was to where it goes.
    var moveMany: ([CMTime: CMTime]) -> Void
    var delete: ([CMTime]) -> Void
    var ease: ([CMTime], KeyframeEase.Preset) -> Void

    init<Value>(edit: @escaping (@escaping (inout AnimatedValue<Value>) -> Void) -> Void) {
        move = { from, to, copy in edit { $0.moveKeyframe(at: from, to: to, copying: copy) } }
        moveMany = { moves in edit { $0.moveKeyframes(moves) } }
        delete = { times in edit { value in for time in times { value.removeKeyframe(at: time) } } }
        ease = { times, preset in edit { value in for time in times { value.applyEase(preset, at: time) } } }
    }
}

/// The keyframes picked in the effects panel's lanes, across its controls,
/// as clips are picked on the timeline (see `SelectClick`): a click picks
/// one, Command-click adds or takes out, Shift-click picks the keyframes
/// from the last clicked to it across the lanes between, and dragging in
/// empty lane space draws a lasso. A drag of a picked keyframe, Delete and
/// the eases act on them all. Each lane registers what it shows and how to
/// edit it as it is drawn (`register`), so what is picked can be edited
/// whatever lane it is in; that registry isn't watched.
@MainActor @Observable
final class LaneKeyframePicks {
    /// A keyframe in a lane: the lane's parameter and its source time.
    struct Key: Hashable {
        var lane: ParameterKey
        var time: CMTime
    }

    private(set) var picked = SelectionSet<Key>()
    /// How far, in lane time, the picked keyframes are being dragged, for
    /// every picked diamond to be drawn there.
    private(set) var dragShift: CMTime?

    /// A lane as it was last drawn.
    struct Lane {
        /// Where the whole lane is, in window coordinates.
        var frame: CGRect = .null
        /// Its keyframes' source times, in order.
        var times: [CMTime]
        var geometry: ClipLaneGeometry
        var edits: LaneKeyframeEdits
    }

    @ObservationIgnored private(set) var lanes: [ParameterKey: Lane] = [:]

    var isEmpty: Bool { picked.isEmpty }

    func contains(_ lane: ParameterKey, _ time: CMTime) -> Bool { picked.contains(Key(lane: lane, time: time)) }

    // MARK: Lanes

    func register(_ lane: ParameterKey, times: [CMTime], geometry: ClipLaneGeometry, edits: LaneKeyframeEdits) {
        lanes[lane] = Lane(frame: lanes[lane]?.frame ?? .null, times: times, geometry: geometry, edits: edits)
    }

    func place(_ lane: ParameterKey, at frame: CGRect) {
        lanes[lane]?.frame = frame
    }

    func forget(_ lane: ParameterKey) {
        lanes[lane] = nil
    }

    /// Where a keyframe's diamond is, in window coordinates; nil outside
    /// the trimmed clip or when its lane hasn't been placed.
    func center(of key: Key) -> CGPoint? {
        guard let lane = lanes[key.lane], !lane.frame.isNull,
              key.time >= lane.geometry.clip.trimStart, key.time <= lane.geometry.clip.trimEnd
        else { return nil }
        let x = lane.frame.minX + CGFloat(lane.geometry.lane(fromSource: key.time).seconds) * lane.geometry.pixelsPerSecond
        return CGPoint(x: x, y: lane.frame.midY)
    }

    private var allKeys: [Key] {
        lanes.flatMap { lane, entry in entry.times.map { Key(lane: lane, time: $0) } }
    }

    /// Whether a window point is within `reach` of a keyframe's diamond.
    func isNearKeyframe(_ point: CGPoint, reach: CGFloat = 9) -> Bool {
        allKeys.contains { key in center(of: key).map { hypot($0.x - point.x, $0.y - point.y) <= reach } == true }
    }

    // MARK: Picking

    /// A click on a keyframe, as `click` says. Shift picks, on the lanes
    /// from the one last clicked to this one, every keyframe between the
    /// two in time.
    func click(_ key: Key, _ click: SelectClick) {
        guard click == .extend, let anchor = picked.anchor,
              let from = center(of: anchor), let to = center(of: key)
        else {
            return picked.click(key, click == .extend ? .only : click, in: [])
        }
        let rows = min(from.y, to.y)...max(from.y, to.y)
        let times = min(anchor.time, key.time)...max(anchor.time, key.time)
        let run = allKeys.filter { candidate in
            guard let at = center(of: candidate) else { return false }
            return rows.contains(at.y) && times.contains(candidate.time)
        }
        picked.set(Set(run).union([anchor, key]), anchor: anchor)
    }

    /// A press on a keyframe that is being dragged: one not picked is
    /// picked alone, or added with Shift or Command. Whether others move
    /// with it.
    func pressForDrag(_ key: Key, _ click: SelectClick) -> Bool {
        picked.press(key, click)
        return picked.count > 1
    }

    /// The keyframes with a diamond inside `rect` (window coordinates),
    /// with `kept`.
    func lasso(_ rect: CGRect, keeping kept: Set<Key>) {
        picked.lasso(Set(allKeys.filter { center(of: $0).map(rect.contains) == true }), keeping: kept)
    }

    func clear() {
        picked.clear()
        dragShift = nil
    }

    /// Every keyframe in the trimmed clip, in every lane shown (⌘A).
    /// False with none.
    @discardableResult
    func selectAll() -> Bool {
        let all = allKeys.filter { center(of: $0) != nil }
        guard !all.isEmpty else { return false }
        picked.set(Set(all))
        return true
    }

    // MARK: Editing what is picked

    /// The picked keyframes, by lane.
    private var pickedByLane: [ParameterKey: [CMTime]] {
        Dictionary(grouping: picked.items, by: \.lane).mapValues { $0.map(\.time) }
    }

    /// Where the picked keyframes go shifted `shift` in lane time: each
    /// put back on a frame, in source time, by lane.
    private func moves(by shift: CMTime) -> [ParameterKey: [CMTime: CMTime]] {
        var result: [ParameterKey: [CMTime: CMTime]] = [:]
        for (laneKey, times) in pickedByLane {
            guard let lane = lanes[laneKey] else { continue }
            let g = lane.geometry
            for time in times {
                let laneTime = CMTimeAdd(g.lane(fromSource: time), shift)
                let snapped = g.lane(fromTimeline: g.timeline.snappedToFrame(g.timeline(fromLane: laneTime)))
                result[laneKey, default: [:]][time] = g.source(fromLane: snapped)
            }
        }
        return result
    }

    /// How far, in lane time, the picked keyframes can go toward `shift`:
    /// no keyframe passes one in its lane that isn't picked.
    func allowedShift(_ shift: CMTime) -> CMTime {
        var lower = CMTime.negativeInfinity, upper = CMTime.positiveInfinity
        for (laneKey, times) in pickedByLane {
            guard let lane = lanes[laneKey] else { continue }
            let g = lane.geometry
            let range = KeyframeTimes.shiftRange(
                of: Set(times.map { g.lane(fromSource: $0) }), among: lane.times.map { g.lane(fromSource: $0) }, gap: g.timeline.frameDuration
            )
            lower = CMTimeMaximum(lower, range.lower)
            upper = CMTimeMinimum(upper, range.upper)
        }
        return CMTimeMinimum(CMTimeMaximum(shift, lower), upper)
    }

    /// A step of a drag of the picked keyframes, `shift` in lane time;
    /// what it is held to.
    func drag(by shift: CMTime) -> CMTime {
        let allowed = allowedShift(shift)
        if dragShift != allowed { dragShift = allowed }
        return allowed
    }

    /// Moves the picked keyframes as far as the drag left them, and picks
    /// them where they land; nil drops the drag.
    func endDrag(commit: Bool) {
        defer { dragShift = nil }
        guard commit, let shift = dragShift, shift != .zero else { return }
        let all = moves(by: shift)
        for (laneKey, moves) in all { lanes[laneKey]?.edits.moveMany(moves) }
        let anchor = picked.anchor.flatMap { key in all[key.lane]?[key.time].map { Key(lane: key.lane, time: $0) } }
        picked.set(Set(all.flatMap { lane, moves in moves.values.map { Key(lane: lane, time: $0) } }), anchor: anchor)
    }

    /// Moves the picked keyframes `frames` frames, later when positive, as
    /// far as they can go: the arrow keys' and VoiceOver's way to drag
    /// them. False with none picked.
    @discardableResult
    func nudge(frames: Int) -> Bool {
        guard let lane = picked.items.first.flatMap({ lanes[$0.lane] }) else { return false }
        let step = CMTimeMultiply(lane.geometry.timeline.frameDuration, multiplier: Int32(clamping: frames))
        dragShift = allowedShift(step)
        endDrag(commit: true)
        return true
    }

    /// Deletes the picked keyframes. False with none.
    @discardableResult
    func deletePicked() -> Bool {
        guard !picked.isEmpty else { return false }
        for (laneKey, times) in pickedByLane { lanes[laneKey]?.edits.delete(times) }
        picked.clear()
        return true
    }

    func easePicked(_ preset: KeyframeEase.Preset) {
        for (laneKey, times) in pickedByLane { lanes[laneKey]?.edits.ease(times, preset) }
    }
}
