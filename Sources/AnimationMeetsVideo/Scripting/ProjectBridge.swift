import CoreMedia
import Foundation

/// Answers the helper's calls about the project (see
/// docs/python-scripting.md, "The bridge").
///
/// It answers from a snapshot: the project as it was when the run began.
/// That is a value, so the run sees one consistent project however long
/// it takes, off the main actor. Changes go to a working copy of it, which
/// the reads that follow see; the runner writes the working copy to the
/// project once, when the run ends without raising.
///
/// Objects in Python hold IDs and nothing else, so every read comes here.
/// Swift stays the only place a curve is evaluated, a clip's time mapped
/// or a layer's name made; the helper is handed the answers.
actor ProjectBridge {
    /// What a run reads besides the project.
    struct Context: Sendable {
        /// Where the project is saved, for `document()`'s relative paths.
        var packageURL: URL?
        /// The scenes found in each asset, by asset ID.
        var sceneTracks: [UUID: ChangeScoreTrack] = [:]
        /// The beats found in each asset, by asset ID.
        var beatTracks: [UUID: BeatTrack] = [:]
        /// Clips a tool has open, which nothing else may change
        /// (`ProjectState.lock`).
        var locks: [ProjectState.ClipLock] = []
    }

    let snapshot: EditingProject
    let context: Context
    /// The snapshot with the run's changes so far.
    private(set) var working: EditingProject

    init(project: EditingProject, context: Context = Context()) {
        snapshot = project
        working = project
        self.context = context
    }

    /// Whether the run has changed anything.
    var hasChanges: Bool { working != snapshot }

    /// The answer to one call: a value, or an error the helper raises at
    /// the line that made it.
    func answer(_ call: HelperCall) -> HelperReply {
        do {
            return .value(try respond(to: call))
        } catch let error as ScriptCallError {
            return .error(error)
        } catch {
            return .error(.value(error.localizedDescription))
        }
    }

    private func respond(to call: HelperCall) throws -> JSONValue {
        switch call.method {
        case "project": return readProject()
        case "document": return try readDocument()
        case "timeline": return try readTimeline(call)
        case "layer": return try readLayer(call)
        case "clip": return try readClip(call)
        case "effect": return try readEffect(call)
        case "control": return try readControl(call)
        case "control_at": return try readControlAt(call)
        case "source_time": return try readSourceTime(call)
        case "timeline_time": return try readTimelineTime(call)
        case "asset": return try readAsset(call)
        case "beats": return try readBeats(call)
        default:
            if let change = try change(call) { return change }
            throw ScriptCallError.value("The app doesn't know the call \u{201C}\(call.method)\u{201D}.")
        }
    }

    /// A change, if `call` is one; nil for any other call. Changes come
    /// in the step that adds them (see `ProjectBridge+Changes`).
    func change(_ call: HelperCall) throws -> JSONValue? { nil }

    // MARK: - Reads

    private func readProject() -> JSONValue {
        [
            "id": JSONValue(working.id),
            "name": .string(working.name),
            "root": JSONValue(working.rootTimelineID),
            "timelines": .array(working.timelines.map { JSONValue($0.id) }),
            "assets": .array(working.clips.map { JSONValue($0.id) }),
        ]
    }

    /// The project as `project.json` has it.
    private func readDocument() throws -> JSONValue {
        let package = context.packageURL ?? FileManager.default.temporaryDirectory.appending(path: "Untitled.amv")
        let data = try ProjectStore.encode(working, packageURL: package)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func readTimeline(_ call: HelperCall) throws -> JSONValue {
        let timeline = try self.timeline(call)
        return [
            "name": .string(timeline.name),
            "frame_size": [.number(timeline.frameSize.width), .number(timeline.frameSize.height)],
            "frame_rate": .number(timeline.frameRate),
            "frame": ScriptTime.json(timeline.frameDuration),
            "duration": ScriptTime.json(timeline.duration),
            "layers": .array(timeline.layers.map { JSONValue($0.id) }),
            "sections": .array(timeline.sections.map { section in
                ["name": .string(section.name), "start": ScriptTime.json(section.start), "end": ScriptTime.json(section.end)]
            }),
        ]
    }

    private func readLayer(_ call: HelperCall) throws -> JSONValue {
        let (timeline, layer) = try self.layer(call)
        return [
            "name": .string(working.displayName(of: layer, in: timeline)),
            "kind": .string(layer.kind.rawValue),
            "adjustment": .bool(layer.isAdjustment),
            "clips": .array(layer.clips.map { clip in
                [JSONValue(clip.id), ScriptTime.json(clip.startOffset), ScriptTime.json(clip.endOffset)]
            }),
        ]
    }

    private func readClip(_ call: HelperCall) throws -> JSONValue {
        let (timelineID, clip, layer) = try self.clip(call)
        let source: JSONValue = switch clip.source {
        case .media(let id): ["kind": "media", "id": JSONValue(id)]
        case .timeline(let id): ["kind": "timeline", "id": JSONValue(id)]
        case .adjustment: ["kind": "adjustment", "id": nil]
        case .graphic: ["kind": "graphic", "id": nil]
        }
        return [
            "layer": JSONValue(layer.id),
            "name": .string(working.clipName(clip.id, in: timelineID)),
            "start": ScriptTime.json(clip.startOffset),
            "end": ScriptTime.json(clip.endOffset),
            "trim_start": ScriptTime.json(clip.trimStart),
            "trim_end": ScriptTime.json(clip.trimEnd),
            "enabled": .bool(clip.enabled),
            "source": source,
            // Keyframing effects aren't shown in the stack, but they are in
            // it, and a script can find and remove them.
            "effects": .array(clip.effects.map { JSONValue($0.id) }),
            "sound_effects": .array(clip.audioEffects.map { JSONValue($0.id) }),
        ]
    }

    private func readEffect(_ call: HelperCall) throws -> JSONValue {
        let (_, _, effect) = try self.effect(call)
        return [
            "kind": .string(effect.missing?.kind ?? effect.kind.rawValue),
            "name": .string(effect.displayName),
            "enabled": .bool(effect.enabled),
            "controls": .array(effect.controls.map { control in
                [JSONValue(control.id), .string(control.kind.rawValue), .string(control.kind.name)]
            }),
        ]
    }

    private func readControl(_ call: HelperCall) throws -> JSONValue {
        let target = try self.target(call)
        let driver = working.keyframingEffect(driving: target.target, in: target.clip)
        switch target.kind {
        case .volume:
            let volume = target.clip.volume
            return [
                "kind": "volume", "name": "Volume", "value": .number(volume.value),
                "keyframes": .array(volume.keyframes.map { [ScriptTime.json($0.time), .number($0.value)] }),
                "driven_by": driver.map { JSONValue($0.id) } ?? .null,
            ]
        case .control(let control):
            return [
                "kind": .string(control.kind.rawValue),
                "name": .string(control.kind.name),
                "value": ScriptValue.json(of: control),
                "keyframes": .array(control.number.keyframes.map { [ScriptTime.json($0.time), ScriptValue.json($0.value)] }),
                "driven_by": driver.map { JSONValue($0.id) } ?? .null,
            ]
        }
    }

    private func readControlAt(_ call: HelperCall) throws -> JSONValue {
        let target = try self.target(call)
        guard let times = call["times"]?.array else { throw ScriptCallError.type("control_at takes a list of times") }
        let frames = try timeline(call, key: "target")
        return try .array(times.map { time in
            let at = try ScriptTime.time(time, in: frames)
            switch target.kind {
            case .volume: return .number(target.clip.volume.value(at: at))
            case .control(let control):
                if control.kind.isChoice { return JSONValue(control.choice) }
                return ScriptValue.json(control.number.value(at: at))
            }
        })
    }

    private func readSourceTime(_ call: HelperCall) throws -> JSONValue {
        let (timelineID, clip, _) = try self.clip(call)
        let time = try ScriptTime.time(call["time"], in: working.timeline(id: timelineID))
        return ScriptTime.json(clip.sourceTime(atTimelineTime: time))
    }

    private func readTimelineTime(_ call: HelperCall) throws -> JSONValue {
        let (timelineID, clip, _) = try self.clip(call)
        let time = try ScriptTime.time(call["time"], in: working.timeline(id: timelineID))
        return ScriptTime.json(clip.timelineTime(forSourceTime: time))
    }

    private func readAsset(_ call: HelperCall) throws -> JSONValue {
        let asset = try self.asset(call)
        let scenes = working.scenes(ofAsset: asset.id, track: context.sceneTracks[asset.id])
        return [
            "name": .string(asset.name),
            "path": JSONValue(asset.url?.path),
            "kind": .string(asset.kind.rawValue.lowercased()),
            "duration": ScriptTime.json(asset.duration),
            "scenes": .array(scenes.map { [ScriptTime.json($0.start), ScriptTime.json($0.end)] }),
        ]
    }

    private func readBeats(_ call: HelperCall) throws -> JSONValue {
        let (_, layer) = try self.layer(call)
        return .array(working.beatMarkers(in: layer, tracks: context.beatTracks).map { ScriptTime.json($0.time) })
    }

    // MARK: - Finding things

    func uuid(_ call: HelperCall, _ name: String, in arguments: [String: JSONValue]? = nil) throws -> UUID {
        guard let id = (arguments ?? call.arguments)[name]?.uuid else {
            throw ScriptCallError.type("\(call.method) needs a \(name) ID")
        }
        return id
    }

    func timeline(_ call: HelperCall, key: String? = nil) throws -> Timeline {
        let arguments = try key.map { try object(call, $0) }
        guard let timeline = working.timeline(id: try uuid(call, "timeline", in: arguments)) else {
            throw ScriptCallError.gone("The timeline is no longer in the project.")
        }
        return timeline
    }

    func layer(_ call: HelperCall) throws -> (Timeline, TimelineLayer) {
        let timeline = try timeline(call)
        guard let layer = timeline.layer(id: try uuid(call, "layer")) else {
            throw ScriptCallError.gone("The layer is no longer in \u{201C}\(timeline.name)\u{201D}.")
        }
        return (timeline, layer)
    }

    /// A clip, its timeline's ID and its layer, from `timeline` and
    /// `clip` in `arguments` (the call's own, by default).
    func clip(_ call: HelperCall, in arguments: [String: JSONValue]? = nil) throws -> (UUID, TimelineClip, TimelineLayer) {
        let timelineID = try uuid(call, "timeline", in: arguments)
        guard let found = working.clipAndLayer(try uuid(call, "clip", in: arguments), in: timelineID) else {
            throw ScriptCallError.gone("The clip is no longer in the project.")
        }
        return (timelineID, found.clip, found.layer)
    }

    func effect(_ call: HelperCall, in arguments: [String: JSONValue]? = nil) throws -> (UUID, TimelineClip, Effect) {
        let (timelineID, clip, _) = try self.clip(call, in: arguments)
        guard let effect = clip.effect(id: try uuid(call, "effect", in: arguments)) else {
            throw ScriptCallError.gone("The effect is no longer on the clip.")
        }
        return (timelineID, clip, effect)
    }

    /// A control, or a clip's volume, from the call's `target`.
    struct Target {
        enum Kind {
            case volume
            case control(EffectControl)
        }

        var timelineID: UUID
        var clip: TimelineClip
        var target: KeyframingTarget
        var kind: Kind
    }

    func target(_ call: HelperCall) throws -> Target {
        let arguments = try object(call, "target")
        if arguments["property"] == "volume" {
            let (timelineID, clip, _) = try self.clip(call, in: arguments)
            return Target(timelineID: timelineID, clip: clip, target: .volume, kind: .volume)
        }
        let (timelineID, clip, effect) = try self.effect(call, in: arguments)
        guard let control = effect.controls.first(id: try uuid(call, "control", in: arguments)) else {
            throw ScriptCallError.gone("The control is no longer on \u{201C}\(effect.displayName)\u{201D}.")
        }
        return Target(
            timelineID: timelineID, clip: clip,
            target: .control(effectID: effect.id, controlID: control.id), kind: .control(control)
        )
    }

    func asset(_ call: HelperCall) throws -> MediaClip {
        guard let asset = working.mediaClip(id: try uuid(call, "asset")) else {
            throw ScriptCallError.gone("The asset is no longer in the project.")
        }
        return asset
    }

    func object(_ call: HelperCall, _ name: String) throws -> [String: JSONValue] {
        guard let object = call[name]?.object else { throw ScriptCallError.type("\(call.method) needs a \(name)") }
        return object
    }

    /// Lets the changes in `ProjectBridge+Changes` replace the working
    /// copy.
    func setWorking(_ project: EditingProject) {
        working = project
    }
}

/// Times as they cross to the helper: exact, as [value, timescale], which
/// Python reads as a `Fraction` of seconds.
enum ScriptTime {
    /// A time for the helper; null for one that isn't a number.
    static func json(_ time: CMTime) -> JSONValue {
        guard time.isNumeric else { return .null }
        return [.number(Double(time.value)), .number(Double(time.timescale))]
    }

    /// The finest timescale a time from Python is kept at when its
    /// denominator doesn't fit a `CMTime`'s.
    static let fallbackTimescale: Int32 = 240_000

    /// A time from the helper: [numerator, denominator], taken exactly, or
    /// a number of seconds, rounded to a frame of `timeline` (to a
    /// microsecond-ish grid with none).
    static func time(_ value: JSONValue?, in timeline: Timeline?) throws -> CMTime {
        switch value {
        case .array(let parts)?:
            guard parts.count == 2, let numerator = parts[0].number, let denominator = parts[1].number,
                  numerator.isFinite, denominator > 0
            else { throw ScriptCallError.type("A time is a number of seconds") }
            if let n = parts[0].int, let d = parts[1].int, let timescale = Int32(exactly: d) {
                return CMTime(value: Int64(n), timescale: timescale)
            }
            return CMTime(seconds: numerator / denominator, preferredTimescale: fallbackTimescale)
        case .number(let seconds)?:
            guard seconds.isFinite, abs(seconds) < 1e9 else { throw ScriptCallError.value("A time must be a finite number of seconds") }
            let time = CMTime(seconds: seconds, preferredTimescale: fallbackTimescale)
            return timeline?.frameAligned(time, .nearest) ?? time
        default:
            throw ScriptCallError.type("A time is a number of seconds")
        }
    }
}

/// Control values as they cross to the helper: a number for one
/// component, a list for several, and a choice's option as its name.
enum ScriptValue {
    static func json(of control: EffectControl) -> JSONValue {
        if control.kind.isChoice { return JSONValue(control.choice) }
        return json(control.number.value)
    }

    static func json(_ value: ComponentValue) -> JSONValue {
        value.values.count == 1 ? .number(value.values[0]) : .array(value.values.map(JSONValue.number))
    }

    /// A value from the helper for a control of `kind`, with its limits
    /// applied. A single number for a vector sets every component.
    static func components(_ value: JSONValue?, for kind: ControlKind, count: Int) throws -> ComponentValue {
        let numbers: [Double]
        switch value {
        case .number(let number)?: numbers = Array(repeating: number, count: max(count, 1))
        case .array(let items)?:
            numbers = try items.map { item in
                guard let number = item.number else { throw ScriptCallError.type("\(kind.name)'s value is made of numbers") }
                return number
            }
            guard numbers.count == count else {
                throw ScriptCallError.value("\(kind.name) takes \(count) numbers, not \(numbers.count)")
            }
        default:
            throw ScriptCallError.type("\(kind.name)'s value is a number or a list of numbers")
        }
        guard numbers.allSatisfy(\.isFinite) else { throw ScriptCallError.value("\(kind.name)'s value must be finite") }
        return ComponentValue(values: numbers.enumerated().map { kind.clamped($1, index: $0) })
    }
}
