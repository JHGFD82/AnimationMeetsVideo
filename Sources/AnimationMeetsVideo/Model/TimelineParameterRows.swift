import CoreMedia
import Foundation

// Parameters in the timeline (see docs/parameter-rows.md): effect controls
// edited in rows under their layer, holding only the parameters picked
// for each clip. Which rows each clip has is how the timeline is looked
// at, not what plays, so it is kept with the view state, never in the
// project: showing or hiding a row is no undo step and no edit.

/// A parameter as the timeline's rows match it across clips: the kind of
/// its effect, which of the clip's effects of that kind it is (0 for the
/// first, so "Glow" and "Glow 2" are rows of their own), and its control.
struct ParameterRowKey: Hashable, Codable, Sendable {
    var effectKind: String
    var ordinal: Int
    var control: String

    init(effectKind: EffectKind, ordinal: Int, control: ControlKind) {
        self.effectKind = effectKind.rawValue
        self.ordinal = ordinal
        self.control = control.rawValue
    }

    /// The effect it is under, as a row group's key.
    var effectKey: String { "\(effectKind)#\(ordinal)" }
}

/// Which parameters each clip of a timeline has put in its rows.
struct TimelineParameterRows: Equatable, Sendable {
    /// Put in by hand (Show in Timeline, Show All in Timeline), by clip.
    var picked: [UUID: Set<ParameterRowKey>] = [:]
    /// Taken out by hand though keyframed, so adding a keyframe's putting
    /// it in doesn't bring it back, by clip.
    var removed: [UUID: Set<ParameterRowKey>] = [:]
    /// The effects folded closed under each layer, by layer and effect key.
    var closed: Set<String> = []

    var isEmpty: Bool { picked.isEmpty && removed.isEmpty && closed.isEmpty }

    /// The parameters `clip` has in the rows: those put in by hand, and
    /// with `addsKeyframed` those it has keyframes on, but for those taken
    /// out by hand.
    func keys(of clip: TimelineClip, addsKeyframed: Bool) -> Set<ParameterRowKey> {
        var keys = picked[clip.id] ?? []
        if addsKeyframed { keys.formUnion(clip.keyframedParameterKeys.subtracting(removed[clip.id] ?? [])) }
        // Only what the clip still has.
        return keys.filter { clip.parameter($0) != nil }
    }

    /// Puts `keys` in the rows of each of `clips`.
    mutating func show(_ keys: Set<ParameterRowKey>, on clips: [UUID]) {
        for clip in clips {
            picked[clip, default: []].formUnion(keys)
            removed[clip]?.subtract(keys)
            if removed[clip]?.isEmpty == true { removed[clip] = nil }
        }
    }

    /// Takes `keys` out of the rows of each of `clips`; their keyframes
    /// stay as they are.
    mutating func remove(_ keys: Set<ParameterRowKey>, from clips: [UUID]) {
        for clip in clips {
            picked[clip]?.subtract(keys)
            if picked[clip]?.isEmpty == true { picked[clip] = nil }
            removed[clip, default: []].formUnion(keys)
        }
    }

    /// For when adding keyframed parameters by themselves is turned off:
    /// the rows they had stay, as picked by hand.
    mutating func keepKeyframedRows(of clips: [TimelineClip]) {
        for clip in clips {
            let kept = clip.keyframedParameterKeys.subtracting(removed[clip.id] ?? [])
            if !kept.isEmpty { picked[clip.id, default: []].formUnion(kept) }
        }
    }

    func isClosed(_ effectKey: String, on layer: UUID) -> Bool {
        closed.contains("\(layer.uuidString) \(effectKey)")
    }

    mutating func setClosed(_ isClosed: Bool, _ effectKey: String, on layer: UUID) {
        let key = "\(layer.uuidString) \(effectKey)"
        if isClosed { closed.insert(key) } else { closed.remove(key) }
    }

    /// Without clips and layers `timeline` no longer has.
    func kept(in timeline: Timeline) -> TimelineParameterRows {
        let clips = Set(timeline.layers.flatMap { $0.clips.map(\.id) })
        let layers = Set(timeline.layers.map(\.id.uuidString))
        var kept = self
        kept.picked = picked.filter { clips.contains($0.key) }
        kept.removed = removed.filter { clips.contains($0.key) }
        kept.closed = closed.filter { layers.contains(String($0.prefix { $0 != " " })) }
        return kept
    }
}

/// A parameter a clip has: its effect and control.
struct ClipParameter {
    var effect: Effect
    var control: EffectControl
}

extension TimelineClip {
    /// The effects whose controls can be rows: its picture effects but the
    /// Keyframing ones (which show as badges) and missing ones, and its
    /// sound effects.
    var parameterEffects: [Effect] {
        (effects + audioEffects).filter { !$0.kind.isKeyframing && $0.missing == nil }
    }

    /// Which of its effects of its kind `effect` is.
    func ordinal(of effect: Effect) -> Int {
        parameterEffects.filter { $0.kind == effect.kind }.firstIndex { $0.id == effect.id } ?? 0
    }

    /// The key of control `controlID` of effect `effectID`, if it can be a
    /// row: a number or a color, not a choice, a curve, a path or a
    /// gradient.
    func parameterKey(effect effectID: UUID, control controlID: UUID) -> ParameterRowKey? {
        guard let effect = parameterEffects.first(where: { $0.id == effectID }),
              let control = effect.controls.first(where: { $0.id == controlID }), control.isDrivable
        else { return nil }
        return ParameterRowKey(effectKind: effect.kind, ordinal: ordinal(of: effect), control: control.kind)
    }

    /// The keys of every control of `effectID` that can be a row.
    func parameterKeys(ofEffect effectID: UUID) -> Set<ParameterRowKey> {
        guard let effect = parameterEffects.first(where: { $0.id == effectID }) else { return [] }
        return Set(effect.controls.compactMap { parameterKey(effect: effectID, control: $0.id) })
    }

    /// Its effect and control for `key`, if it has them.
    func parameter(_ key: ParameterRowKey) -> ClipParameter? {
        let ofKind = parameterEffects.filter { $0.kind.rawValue == key.effectKind }
        guard ofKind.indices.contains(key.ordinal) else { return nil }
        let effect = ofKind[key.ordinal]
        guard let control = effect.controls.first(where: { $0.kind.rawValue == key.control }), control.isDrivable else { return nil }
        return ClipParameter(effect: effect, control: control)
    }

    /// The keys of its parameters with keyframes.
    var keyframedParameterKeys: Set<ParameterRowKey> {
        var keys: Set<ParameterRowKey> = []
        for effect in parameterEffects {
            for control in effect.controls where control.isAnimated && control.isDrivable {
                keys.insert(ParameterRowKey(effectKind: effect.kind, ordinal: ordinal(of: effect), control: control.kind))
            }
        }
        return keys
    }
}

/// A filter over the rows, as After Effects' U and UU: only the parameters
/// with keyframes, or only those changed from their defaults, keyframed
/// or not, put in the timeline or not.
enum ParameterRowFilter: Equatable, Sendable {
    case animated
    case changed

    /// What the timeline says while it is on.
    var note: String {
        switch self {
        case .animated: "Animated parameters (U)"
        case .changed: "Changed parameters (UU)"
        }
    }
}

extension TimelineClip {
    /// The keys of its parameters `filter` shows: keyframed ones, or those
    /// changed from what a new effect of the kind has (its shapes sized to
    /// `frame`).
    func parameterKeys(_ filter: ParameterRowFilter, frame: CGSize?) -> Set<ParameterRowKey> {
        var keys: Set<ParameterRowKey> = []
        for effect in parameterEffects {
            for control in effect.controls where control.isDrivable {
                let shows = switch filter {
                case .animated: control.isAnimated
                case .changed: control.isAnimated || !control.isAtDefault(like: effect.freshControl(control.kind, in: frame))
                }
                if shows { keys.insert(ParameterRowKey(effectKind: effect.kind, ordinal: ordinal(of: effect), control: control.kind)) }
            }
        }
        return keys
    }
}

/// An effect's rows under a layer: its name and its controls' rows.
struct ParameterRowGroup: Identifiable, Equatable {
    var effectKey: String
    /// As the first clip that has it names it: "Glow", "Glow 2".
    var name: String
    var rows: [TimelineParameterRow]

    var id: String { effectKey }
}

/// One parameter's row under a layer: the clips it is for, those whose
/// keyframes its lane draws.
struct TimelineParameterRow: Identifiable, Equatable {
    var key: ParameterRowKey
    var name: String
    var clips: [UUID]

    var id: ParameterRowKey { key }
}

extension EditingProject {
    /// The rows `layer` shows: the parameters of its clips in `selected`,
    /// or of every clip on it when none of them is, one row a parameter
    /// whatever clips have it, grouped by effect, in the order the clips
    /// and their stacks have them. With `filter`, those it shows instead of
    /// those put in the timeline, a new effect's shapes sized to `frame`.
    func parameterRows(
        on layer: TimelineLayer, rows: TimelineParameterRows, addsKeyframed: Bool, selected: Set<UUID>,
        filter: ParameterRowFilter? = nil, frame: CGSize? = nil
    ) -> [ParameterRowGroup] {
        let clips = layer.clips.sorted { $0.startOffset < $1.startOffset }
        let picked = clips.filter { selected.contains($0.id) }
        let shown = picked.isEmpty ? clips : picked
        var groups: [ParameterRowGroup] = []
        for clip in shown {
            let keys = filter.map { clip.parameterKeys($0, frame: frame) } ?? rows.keys(of: clip, addsKeyframed: addsKeyframed)
            guard !keys.isEmpty else { continue }
            for effect in clip.parameterEffects {
                let ordinal = clip.ordinal(of: effect)
                for control in effect.controls {
                    let key = ParameterRowKey(effectKind: effect.kind, ordinal: ordinal, control: control.kind)
                    guard keys.contains(key) else { continue }
                    var g = groups.firstIndex { $0.effectKey == key.effectKey }
                    if g == nil {
                        groups.append(ParameterRowGroup(effectKey: key.effectKey, name: effect.displayName, rows: []))
                        g = groups.count - 1
                    }
                    if let r = groups[g!].rows.firstIndex(where: { $0.key == key }) {
                        if !groups[g!].rows[r].clips.contains(clip.id) { groups[g!].rows[r].clips.append(clip.id) }
                    } else {
                        groups[g!].rows.append(TimelineParameterRow(key: key, name: control.kind.name, clips: [clip.id]))
                    }
                }
            }
        }
        return groups
    }

    /// The clips a row acts on: those of `selected` on `layer` that have
    /// it, or with none, the one under `time` that has it.
    func parameterActingClips(_ row: TimelineParameterRow, on layer: TimelineLayer, selected: Set<UUID>, at time: CMTime) -> [TimelineClip] {
        let having = layer.clips.filter { row.clips.contains($0.id) }
        let picked = having.filter { selected.contains($0.id) }
        if !picked.isEmpty { return picked }
        return having.filter { time >= $0.startOffset && time < $0.endOffset }
    }

    /// A row's value at timeline `time`: the clips' it acts on, if they
    /// agree; nil when they differ or there are none.
    func parameterValue(_ key: ParameterRowKey, of clips: [TimelineClip], at time: CMTime) -> [Double]? {
        let values = clips.compactMap { clip in clip.parameter(key)?.control.values(at: clip.sourceTime(atTimelineTime: time)) }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Changes the row's control on each of `clips`, at the playhead's
    /// time in each, as one edit.
    mutating func editParameter(
        _ key: ParameterRowKey, of clips: [UUID], in timelineID: UUID, _ change: (inout EffectControl, _ sourceTime: CMTime) -> Void,
        at time: CMTime
    ) {
        for clipID in clips {
            guard let clip = clipAndLayer(clipID, in: timelineID)?.clip, let parameter = clip.parameter(key) else { continue }
            let source = clip.sourceTime(atTimelineTime: time)
            let controlID = parameter.control.id
            editEffect(parameter.effect.id, ofClip: clipID, in: timelineID) { effect in
                guard let c = effect.controlIndex(controlID) else { return }
                change(&effect.controls[c], source)
            }
        }
    }
}
