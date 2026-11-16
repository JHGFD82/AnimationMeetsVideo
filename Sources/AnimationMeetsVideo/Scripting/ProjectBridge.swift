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
        /// For an expression: the control it writes to, and that control
        /// as it was before it wrote. Reading its own target gives that
        /// base, which is `value`, and isn't a read that puts it out of
        /// date, or its own keyframes would.
        var ownTarget: KeyframingRead?
        var ownBase: AnimatedValue<ComponentValue>?
        /// For an expression: the timeline time of each of its samples,
        /// what its `audio()` listens to (Listen To) and the layer whose
        /// beats `beats` follows (Beats From).
        var sampleTimes: [CMTime] = []
        var audioSource: AudioKeysSource?
        var beatLayer: UUID?
    }

    let snapshot: EditingProject
    let context: Context
    /// The snapshot with the run's changes so far.
    private(set) var working: EditingProject
    /// For an expression: it only reads, and what it reads is noted.
    let readsOnly: Bool
    /// What an expression read, in the order first read: what puts its
    /// keyframes out of date when it changes.
    private(set) var reads: [KeyframingRead] = []
    private var readSet: Set<KeyframingRead> = []
    /// What Listen To hears at each sample, read once a run.
    private var heard: [[Double]]?

    init(project: EditingProject, context: Context = Context(), readsOnly: Bool = false) {
        snapshot = project
        working = project
        self.context = context
        self.readsOnly = readsOnly
    }

    /// Notes a read, for an expression.
    func noteRead(_ read: KeyframingRead) {
        guard readsOnly, read != context.ownTarget, readSet.insert(read).inserted else { return }
        reads.append(read)
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
        case "control_frames": return try readControlFrames(call)
        case "audio_levels": return try readAudioLevels(call)
        case "beat_times": return try readBeatTimes()
        case "noise": return try noiseValues(call)
        case "wiggle": return try wiggleValues(call)
        default:
            if readsOnly {
                throw ScriptCallError.readOnly("An expression reads the project; it can't change it. A script can.")
            }
            if let change = try change(call) { return change }
            throw ScriptCallError.value("The app doesn't know the call \u{201C}\(call.method)\u{201D}.")
        }
    }

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
        noteRead(KeyframingRead(timeline: timeline.id, kind: .settings))
        noteRead(KeyframingRead(timeline: timeline.id, kind: .layerNames))
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
        noteRead(KeyframingRead(timeline: timeline.id, kind: .layer(layer.id)))
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
        noteRead(KeyframingRead(timeline: timelineID, kind: .clip(clip.id)))
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
        noteRead(Self.read(of: target))
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
        noteRead(Self.read(of: target))
        guard let times = call["times"]?.array else { throw ScriptCallError.type("control_at takes a list of times") }
        let frames = try self.timeline(call, key: "target")
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
        let (timeline, layer) = try self.layer(call)
        noteRead(KeyframingRead(timeline: timeline.id, kind: .beats(layer: layer.id)))
        return .array(working.beatMarkers(in: layer, tracks: context.beatTracks).map { ScriptTime.json($0.time) })
    }

    /// A control's value at each frame of its clip, from the clip's start
    /// to its end on its timeline, for an expression to read at its own
    /// samples, in a straight line between frames: {start, frame, values},
    /// the times in seconds.
    private func readControlFrames(_ call: HelperCall) throws -> JSONValue {
        let target = try self.target(call)
        noteRead(Self.read(of: target))
        guard let timeline = working.timeline(id: target.timelineID) else { throw ScriptCallError.gone("The timeline is gone.") }
        let clip = target.clip
        let frame = timeline.frameDuration
        var values: [JSONValue] = []
        var time = clip.startOffset
        while time <= clip.endOffset {
            let source = CMTimeMinimum(CMTimeMaximum(clip.sourceTime(atTimelineTime: time), clip.trimStart), clip.trimEnd)
            if let base = context.ownBase, Self.read(of: target) == context.ownTarget {
                values.append(ScriptValue.json(base.value(at: source)))
            } else {
                switch target.kind {
                case .volume: values.append(.number(clip.volume.value(at: source)))
                case .control(let control):
                    values.append(control.kind.isChoice ? JSONValue(control.choice) : ScriptValue.json(control.number.value(at: source)))
                }
            }
            time = CMTimeAdd(time, frame)
        }
        return ["start": .number(clip.startOffset.seconds), "frame": .number(frame.seconds), "values": .array(values)]
    }

    /// How loud `low` to `high` Hz are at each of the expression's
    /// samples, 0 to 1 between `floor` and `ceiling` dB: what Listen To
    /// hears, by Audio Keys' arithmetic (`AudioKeysMath`).
    private func readAudioLevels(_ call: HelperCall) throws -> JSONValue {
        guard let own = context.ownTarget, let timeline = working.timeline(id: own.timeline) else {
            throw ScriptCallError.value("audio() is for expressions")
        }
        guard let source = context.audioSource else {
            throw ScriptCallError.value("audio() hears nothing: choose what it listens to under Listen To")
        }
        guard let low = call["low"]?.number, let high = call["high"]?.number, low.isFinite, high.isFinite else {
            throw ScriptCallError.type("audio() takes the lowest and highest frequency, in Hz")
        }
        let floor = call["floor"]?.number ?? -48, ceiling = call["ceiling"]?.number ?? 0
        noteRead(KeyframingRead(timeline: timeline.id, kind: .heard(source)))
        if heard == nil { heard = working.heardBands(source, in: timeline, at: context.sampleTimes) }
        guard let heard else {
            // When the sound has been read, what it hears changes, and the
            // expression runs again.
            throw ScriptCallError.value("The sound it listens to is still being read")
        }
        return .array(heard.map { bands in
            .number(AudioKeysMath.normalized(AudioKeysMath.level(of: bands, from: low, to: high), floor: floor, ceiling: ceiling))
        })
    }

    /// The beats of the layer under Beats From, in its timeline's time:
    /// [seconds, place in the measure (0 for a detected beat)].
    private func readBeatTimes() throws -> JSONValue {
        guard let own = context.ownTarget, let timeline = working.timeline(id: own.timeline) else {
            throw ScriptCallError.value("beats is for expressions")
        }
        guard let layerID = context.beatLayer else {
            throw ScriptCallError.value("beats follows nothing: choose a Sound or Music layer under Beats From")
        }
        guard let layer = timeline.layer(id: layerID) else { throw ScriptCallError.gone("The layer under Beats From is gone") }
        noteRead(KeyframingRead(timeline: timeline.id, kind: .beats(layer: layerID)))
        return .array(working.beatMarkers(in: layer, tracks: context.beatTracks).map { beat in
            [.number(beat.time.seconds), .number(Double(beat.position ?? 0))]
        })
    }

    /// Wiggler's noise stream for an expression's Seed and a dimension
    /// (0 for the first component, 1 for the next…), as Wiggler streams
    /// each component.
    private static func noiseStream(_ call: HelperCall) throws -> UInt64 {
        guard let seed = call["seed"]?.number, seed.isFinite, let dimension = call["dimension"]?.int, dimension >= 0 else {
            throw ScriptCallError.type("noise needs the expression's seed and a dimension")
        }
        return KeyframeGenerators.hash(UInt64(max(seed, 0)) &* 31 &+ UInt64(dimension))
    }

    /// `noise(x)`: Wiggler's smooth noise at each of `xs`, about -1 to 1.
    private func noiseValues(_ call: HelperCall) throws -> JSONValue {
        let stream = try Self.noiseStream(call)
        guard let xs = call["xs"]?.array else { throw ScriptCallError.type("noise() takes a number") }
        return try .array(xs.map { x in
            guard let x = x.number, x.isFinite else { throw ScriptCallError.value("noise() takes a finite number") }
            return .number(KeyframeGenerators.noise(x, stream: stream, smooth: true))
        })
    }

    /// `wiggle(frequency, amount)` before its amount: Wiggler's noise at
    /// `frequency` wiggles a second, at each of the expression's samples,
    /// from the start of its range, about -1 to 1.
    private func wiggleValues(_ call: HelperCall) throws -> JSONValue {
        let stream = try Self.noiseStream(call)
        guard let frequency = call["frequency"]?.number, frequency.isFinite else {
            throw ScriptCallError.type("wiggle() takes a frequency, in wiggles a second")
        }
        let octaves = max(min(call["octaves"]?.int ?? 1, 8), 1)
        let start = context.sampleTimes.first?.seconds ?? 0
        return .array(context.sampleTimes.map { time in
            .number(KeyframeGenerators.fractalNoise((time.seconds - start) * frequency, octaves: octaves, stream: stream, smooth: true))
        })
    }

    /// What reading a target is, as an expression's read.
    static func read(of target: Target) -> KeyframingRead {
        switch target.target {
        case .volume: KeyframingRead(timeline: target.timelineID, kind: .volume(clip: target.clip.id))
        case .control(let effectID, let controlID):
            KeyframingRead(timeline: target.timelineID, kind: .control(clip: target.clip.id, effect: effectID, control: controlID))
        }
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
        let timeline = try self.timeline(call)
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

    /// Takes a change made to a copy of the working copy, unless the app
    /// would refuse it by hand: a change to a clip a tool has open, or to
    /// keyframes a Keyframing method made. Then the working copy is left
    /// as it was and the line that asked raises `amv.Refused`. What
    /// follows from the change (methods whose clip or reads changed making
    /// their keyframes again) follows at once, so the reads after it see
    /// it, as the editor does after an edit.
    func commit(_ project: EditingProject) throws {
        for lock in context.locks where lock.isChanged(from: working, to: project) {
            let name = lock.clipIDs.first.map { working.clipName($0, in: lock.timelineID) } ?? "A clip"
            throw ScriptCallError.refused("\u{201C}\(name)\u{201D} is open in the Motion Designer, and nothing else may change it until it closes.")
        }
        if let edit = project.drivenKeyframesEdit(since: working) {
            throw ScriptCallError.refused("\(edit.controlName)'s keyframes are made by \(edit.methodName), which would write over them. Bake them first, with bake().")
        }
        var refreshed = project
        refreshed.refreshKeyframing(after: working)
        working = refreshed
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
