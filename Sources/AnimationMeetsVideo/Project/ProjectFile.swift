import CoreMedia
import Foundation

/// On-disk shape of `project.json`. Everything is referenced by stable ID,
/// times are exact rationals, and the encoder is deterministic, so saving an
/// unchanged project produces byte-identical output.
struct ProjectFile: Codable {
    static let currentVersion = 2

    /// Exact rational time written as `"value/timescale s"` with no space,
    /// for example `"1001/24000s"`. A whole number of seconds may be written
    /// as `"5s"`.
    struct TimeEntry: Codable {
        var time: CMTime

        init(_ time: CMTime) {
            self.time = time
        }

        init(from decoder: Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            guard text.hasSuffix("s") else {
                throw ProjectStoreError.invalidTime(text)
            }
            let body = text.dropLast()
            let parts = body.split(separator: "/", omittingEmptySubsequences: false)
            switch parts.count {
            case 1:
                guard let value = Int64(parts[0]) else { throw ProjectStoreError.invalidTime(text) }
                time = CMTime(value: value, timescale: 1)
            case 2:
                guard let value = Int64(parts[0]), let timescale = Int32(parts[1]), timescale > 0 else {
                    throw ProjectStoreError.invalidTime(text)
                }
                time = CMTime(value: value, timescale: timescale)
            default:
                throw ProjectStoreError.invalidTime(text)
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode("\(time.value)/\(time.timescale)s")
        }
    }

    struct SourceEntry: Codable {
        enum Kind: String, Codable { case media, timeline, adjustment }
        var kind: Kind
        /// The asset or timeline; absent for an adjustment clip.
        var id: UUID?
    }

    struct ClipEntry: Codable {
        var id: UUID
        var source: SourceEntry
        var startOffset: TimeEntry
        var trimStart: TimeEntry
        var trimEnd: TimeEntry
        var autoMatteEnabled: Bool
        /// `"video"` or `"audio"` once a video's sound is detached; absent
        /// while the clip plays everything its file has.
        var streams: String?
        var transitionIn: TransitionEntry?
        var transitionOut: TransitionEntry?
        /// Offset from the center of the picture; absent while (0, 0) and
        /// not animated.
        var anchorPoint: PropertyEntry<[Double]>?
        /// Absent while the stack is empty.
        var effects: [EffectEntry]?
        /// Decibels; absent while at 0 and not animated.
        var volume: PropertyEntry<Double>?
        /// Nested timelines only; absent unless set.
        var passThrough: Bool?
        /// Absent while the clip plays at its source's own speed with nothing
        /// else done to time.
        var time: ClipTimeEntry?
        /// Absent while there is no motion blur and no trails.
        var shutter: ShutterEntry?
    }

    /// Echo or trails: `count` copies, `delay` apart, each `decay` as strong
    /// as the one in front.
    struct EchoEntry: Codable {
        var count: Int
        var delay: TimeEntry
        var decay: Double

        init(count: Int, delay: CMTime, decay: Double) {
            self.count = count
            self.delay = TimeEntry(delay)
            self.decay = decay
        }
    }

    struct MotionBlurEntry: Codable {
        var angle: Double
        var samples: Int
    }

    /// What a clip does to time, written only for what isn't at its default.
    struct ClipTimeEntry: Codable {
        var speed: PropertyEntry<Double>?
        /// `"blend"` or `"opticalFlow"`.
        var frameBlending: String?
        var echo: EchoEntry?
        /// `"changePitch"` or `"mute"`.
        var sound: String?

        init?(_ time: ClipTime) {
            guard !time.isDefault else { return nil }
            speed = time.speed == AnimatedValue(100.0) ? nil : PropertyEntry(time.speed) { $0 }
            frameBlending = time.frameBlending == .off ? nil : time.frameBlending.rawValue
            echo = time.echo.map { EchoEntry(count: $0.count, delay: $0.delay, decay: $0.decay) }
            sound = time.sound == .keepPitch ? nil : time.sound.rawValue
        }

        var time: ClipTime {
            var time = ClipTime()
            if let speed {
                time.speed = speed.property(default: 100.0) { ClipTime.clampedSpeed($0) }
            }
            time.frameBlending = frameBlending.flatMap(FrameBlending.init(rawValue:)) ?? .off
            time.echo = echo.map { Echo(count: $0.count, delay: $0.delay.time, decay: $0.decay).clamped }
            time.sound = sound.flatMap(SoundMode.init(rawValue:)) ?? .keepPitch
            return time
        }
    }

    /// What a clip does with its finished picture.
    struct ShutterEntry: Codable {
        var motionBlur: MotionBlurEntry?
        var trails: EchoEntry?

        init?(_ shutter: ClipShutter) {
            guard !shutter.isOff else { return nil }
            motionBlur = shutter.motionBlur.map { MotionBlurEntry(angle: $0.angle, samples: $0.samples) }
            trails = shutter.trails.map { EchoEntry(count: $0.count, delay: $0.delay, decay: $0.decay) }
        }

        var shutter: ClipShutter {
            ClipShutter(
                motionBlur: motionBlur.map { MotionBlur(angle: $0.angle, samples: $0.samples).clamped },
                trails: trails.map { Trails(count: $0.count, delay: $0.delay.time, decay: $0.decay).clamped }
            )
        }
    }

    /// A transition at one end of a clip. `kind` is a `TransitionKind`
    /// name such as `"crossDissolve"`; an unknown kind is dropped on load.
    /// `curve` is absent for a linear one, `lead` (the part played before
    /// the cut by a way in joining two clips) when it is zero. The settings
    /// after them are written only for kinds that offer them: `color` is
    /// `[r, g, b]` from 0 to 1, `center` `[x, y]` as fractions of the frame
    /// from its top left, `matte` `"noise"` or the ID of a clip whose frame
    /// is the map. Kinds saved before a wipe's or slide's direction was a
    /// setting (`"wipeLeft"`, `"slideRight"`) are read with that direction.
    struct TransitionEntry: Codable {
        var kind: String
        var duration: TimeEntry
        var curve: [CurvePointEntry]?
        var lead: TimeEntry?
        var direction: String?
        var color: [Double]?
        var center: [Double]?
        var shape: String?
        var count: Int?
        var order: String?
        var amount: Double?
        var matte: String?

        init(_ transition: ClipTransition) {
            kind = transition.kind.rawValue
            duration = TimeEntry(transition.duration)
            curve = transition.curve == .linear ? nil : transition.curve.points.map(CurvePointEntry.init)
            lead = transition.lead == .zero ? nil : TimeEntry(transition.lead)
            let options = transition.options
            for setting in transition.kind.settings {
                switch setting {
                case .direction: direction = options.direction.rawValue
                case .color: color = [options.color.red, options.color.green, options.color.blue]
                case .center: center = [Double(options.center.x), Double(options.center.y)]
                case .shape: shape = options.shape.rawValue
                case .count: count = options.count
                case .order: order = options.order.rawValue
                case .amount: amount = options.amount
                case .matte:
                    switch options.matte {
                    case .noise: matte = "noise"
                    case .clip(let id): matte = id.uuidString
                    }
                }
            }
        }

        /// A curve that doesn't run from 0 to 1 is read as linear; a
        /// setting that can't be read keeps the kind's default.
        var transition: ClipTransition? {
            guard let saved = TransitionKind.saved(kind), duration.time > .zero else { return nil }
            let points = curve?.map(\.point)
            var options = saved.kind.defaultOptions
            if let direction = saved.direction { options.direction = direction }
            let offered = Set(saved.kind.settings)
            if offered.contains(.direction), let value = direction.flatMap(TransitionDirection.init(rawValue:)) {
                options.direction = value
            }
            if offered.contains(.color), let value = color, value.count == 3 {
                options.color = TransitionColor(red: value[0], green: value[1], blue: value[2])
            }
            if offered.contains(.center), let value = center, value.count == 2 {
                options.center = CGPoint(x: value[0], y: value[1])
            }
            if offered.contains(.shape), let value = shape.flatMap(IrisShape.init(rawValue:)) { options.shape = value }
            if offered.contains(.count), let count { options.count = count }
            if offered.contains(.order), let value = order.flatMap(GridOrder.init(rawValue:)) { options.order = value }
            if offered.contains(.amount), let amount { options.amount = amount }
            if offered.contains(.matte), let matte {
                options.matte = UUID(uuidString: matte).map(MatteSource.clip) ?? .noise
            }
            return ClipTransition(
                kind: saved.kind,
                duration: duration.time,
                curve: points.flatMap(TransitionCurve.init(points:)) ?? .linear,
                lead: CMTimeMaximum(.zero, CMTimeMinimum(lead?.time ?? .zero, duration.time)),
                options: options.clamped
            )
        }
    }

    /// One point of a transition curve, in fractions of the transition.
    /// Handles are `[dx, dy]` offsets from the point; absent for none.
    struct CurvePointEntry: Codable {
        var time: Double
        var value: Double
        var `in`: [Double]?
        var out: [Double]?

        init(_ point: TransitionCurve.Point) {
            time = point.time
            value = point.value
            `in` = point.inHandle.map { [Double($0.dx), Double($0.dy)] }
            out = point.outHandle.map { [Double($0.dx), Double($0.dy)] }
        }

        var point: TransitionCurve.Point {
            func vector(_ pair: [Double]?) -> CGVector? {
                guard let pair, pair.count == 2 else { return nil }
                return CGVector(dx: pair[0], dy: pair[1])
            }
            return TransitionCurve.Point(time: time, value: value, inHandle: vector(`in`), outHandle: vector(out))
        }
    }

    /// One keyframe. Vector values are written as `[x, y]`. Eases are
    /// absent on linear sides.
    struct KeyframeEntry<Value: Codable>: Codable {
        var time: TimeEntry
        var value: Value
        var easeIn: EaseEntry?
        var easeOut: EaseEntry?
    }

    /// A keyframe side's temporal ease (`KeyframeEase`).
    struct EaseEntry: Codable {
        var influence: Double
        var speed: Double

        init(_ ease: KeyframeEase) {
            influence = ease.influence
            speed = ease.speed
        }

        var ease: KeyframeEase { KeyframeEase(influence: influence, speed: speed) }
    }

    /// A property's value, or its keyframes when animated.
    struct PropertyEntry<Value: Codable>: Codable {
        var value: Value?
        var keyframes: [KeyframeEntry<Value>]?

        init<V: Interpolatable>(_ property: AnimatedValue<V>, encode: (V) -> Value) {
            if property.isAnimated {
                keyframes = property.keyframes.map {
                    KeyframeEntry(
                        time: TimeEntry($0.time), value: encode($0.value),
                        easeIn: $0.easeIn.map(EaseEntry.init), easeOut: $0.easeOut.map(EaseEntry.init)
                    )
                }
            } else {
                value = encode(property.value)
            }
        }

        func property<V: Interpolatable>(default fallback: V, decode: (Value) -> V?) -> AnimatedValue<V> {
            let frames = (keyframes ?? []).compactMap { entry in
                decode(entry.value).map {
                    Keyframe(time: entry.time.time, value: $0, easeIn: entry.easeIn?.ease, easeOut: entry.easeOut?.ease)
                }
            }
            return AnimatedValue(value.flatMap(decode) ?? frames.first?.value ?? fallback, keyframes: frames)
        }
    }

    /// A control's value: a number, a list of numbers (position, scale) or
    /// the name of the option picked (a blend mode).
    enum ControlValueEntry: Codable, Equatable {
        case number(Double)
        case numbers([Double])
        case text(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else if let numbers = try? container.decode([Double].self) {
                self = .numbers(numbers)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let number): try container.encode(number)
            case .numbers(let numbers): try container.encode(numbers)
            case .text(let text): try container.encode(text)
            }
        }

        init(_ components: ComponentValue) {
            self = components.values.count == 1 ? .number(components.values[0]) : .numbers(components.values)
        }

        var components: ComponentValue? {
            switch self {
            case .number(let number): ComponentValue(values: [number])
            case .numbers(let numbers): ComponentValue(values: numbers)
            case .text: nil
            }
        }
    }

    /// One control of an effect: its value, or its keyframes when animated.
    struct ControlEntry: Codable {
        var id: UUID
        var kind: String
        /// Absent while enabled.
        var enabled: Bool?
        /// Scale only; absent while linked.
        var linked: Bool?
        var value: ControlValueEntry?
        var keyframes: [KeyframeEntry<ControlValueEntry>]?

        init(_ control: EffectControl) {
            id = control.id
            kind = control.kind.rawValue
            enabled = control.enabled ? nil : false
            linked = control.kind == .scale && !control.linked ? false : nil
            if control.kind.isChoice {
                value = .text(control.choice ?? BlendMode.normal.rawValue)
            } else if control.number.isAnimated {
                keyframes = control.number.keyframes.map {
                    KeyframeEntry(
                        time: TimeEntry($0.time), value: ControlValueEntry($0.value),
                        easeIn: $0.easeIn.map(EaseEntry.init), easeOut: $0.easeOut.map(EaseEntry.init)
                    )
                }
            } else {
                value = ControlValueEntry(control.number.value)
            }
        }

        /// Nil only for a kind this version doesn't have, which loading has
        /// already refused.
        var control: EffectControl? {
            guard let kind = ControlKind(rawValue: kind) else { return nil }
            var control = EffectControl(id: id, kind: kind, enabled: enabled ?? true)
            control.linked = linked ?? true
            if kind.isChoice {
                if case .text(let name) = value { control.choice = name }
                return control
            }
            let fallback = control.number.value
            let frames = (keyframes ?? []).compactMap { entry in
                entry.value.components.map {
                    Keyframe(time: entry.time.time, value: $0, easeIn: entry.easeIn?.ease, easeOut: entry.easeOut?.ease)
                }
            }
            control.number = AnimatedValue(value?.components ?? frames.first?.value ?? fallback, keyframes: frames)
            return control
        }
    }

    /// The picture an effect takes: an asset or a timeline of the project,
    /// where it starts, and whether it loops.
    struct InputEntry: Codable {
        var asset: UUID?
        var timeline: UUID?
        /// Absent while it starts at its own start.
        var offset: TimeEntry?
        /// Absent unless it loops.
        var loops: Bool?

        init(_ input: EffectInput) {
            switch input.source {
            case .asset(let id): asset = id
            case .timeline(let id): timeline = id
            }
            offset = input.offset == .zero ? nil : TimeEntry(input.offset)
            loops = input.loops ? true : nil
        }

        /// Nil for one that names neither, which loading has refused.
        var input: EffectInput? {
            guard let source: EffectInput.Source = asset.map({ .asset($0) }) ?? timeline.map({ .timeline($0) }) else { return nil }
            return EffectInput(source: source, offset: offset?.time ?? .zero, loops: loops ?? false)
        }
    }

    /// One effect of a clip's stack. `kind` is an `EffectKind` name such as
    /// `"transform"`.
    struct EffectEntry: Codable {
        var id: UUID
        var kind: String
        /// Absent while it has the kind's plain name.
        var name: String?
        /// Absent while enabled.
        var enabled: Bool?
        /// Transform only; absent while it moves the anchor.
        var movesAnchor: Bool?
        /// Blending only: the ID of the effect it blends against. Absent for
        /// the backdrop.
        var against: UUID?
        /// For an effect that takes a picture, the one dropped on it.
        var input: InputEntry?
        /// Absent unless some are unresolved.
        var pasteChanges: [PasteChangeRecord]?
        /// Presets only: what the effect's input and Against were called
        /// when it was saved, since neither comes along.
        var inputName: String?
        var againstName: String?
        var controls: [ControlEntry]

        init(_ effect: Effect) {
            id = effect.id
            kind = effect.kind.rawValue
            name = effect.name
            enabled = effect.enabled ? nil : false
            movesAnchor = effect.kind == .transform && !effect.movesAnchor ? false : nil
            against = effect.kind == .blending ? effect.against : nil
            input = effect.kind.takesInput ? effect.input.map(InputEntry.init) : nil
            pasteChanges = effect.pasteChanges.isEmpty ? nil : effect.pasteChanges.map(PasteChangeRecord.init)
            controls = effect.controls.map(ControlEntry.init)
        }

        var effect: Effect? {
            guard let kind = EffectKind(rawValue: kind) else { return nil }
            var effect = Effect(id: id, kind: kind, name: name, controls: controls.compactMap(\.control))
            effect.enabled = enabled ?? true
            effect.movesAnchor = movesAnchor ?? true
            effect.against = against
            effect.input = input?.input
            effect.pasteChanges = (pasteChanges ?? []).compactMap(\.change)
            return effect
        }
    }

    /// One paste change an effect still has to resolve.
    struct PasteChangeRecord: Codable {
        var kind: String
        var detail: String
        /// Absent for changes that aren't about a number of keyframes.
        var count: Int?

        init(_ change: PasteChange) {
            kind = change.kind.rawValue
            detail = change.detail
            count = change.kind == .keyframesOutside ? change.count : nil
        }

        var change: PasteChange? {
            PasteChange.Kind(rawValue: kind).map { PasteChange(kind: $0, detail: detail, count: count ?? 0) }
        }
    }

    struct LayerEntry: Codable {
        var id: UUID
        var customName: String?
        /// `LayerKind`'s raw value. Absent in projects saved before layers
        /// had kinds, which get one from their clips on load.
        var kind: String
        var clips: [ClipEntry]
        /// Decibels, on Sound and Music layers; absent while at 0 and not
        /// animated.
        var volume: PropertyEntry<Double>?
        /// True for an adjustment layer; absent otherwise.
        var adjustment: Bool?
        /// The lowest layer an adjustment layer reaches; absent for every
        /// layer below it.
        var reach: UUID?
    }

    struct TimelineEntry: Codable {
        var id: UUID
        var name: String
        var width: Double
        var height: Double
        var frameRate: Double
        var colorSpace: String
        var layers: [LayerEntry]
        /// Absent while the timeline has no sections.
        var sections: [SectionEntry]?
    }

    struct SectionEntry: Codable {
        var id: UUID
        var name: String
        var start: TimeEntry
        var end: TimeEntry
    }

    struct RegionEntry: Codable {
        var id: UUID
        var start: TimeEntry
        var end: TimeEntry
        var value: Double
    }

    struct SceneEditsEntry: Codable {
        var sensitivity: Double?
        var regions: [RegionEntry]
        var manualCuts: [TimeEntry]
        var ignoredCuts: [TimeEntry]

        init(_ edits: SceneEdits) {
            sensitivity = edits.sensitivity
            regions = edits.regions.map { RegionEntry(id: $0.id, start: TimeEntry($0.start), end: TimeEntry($0.end), value: $0.value) }
            manualCuts = edits.manualCuts.map(TimeEntry.init)
            ignoredCuts = edits.ignoredCuts.map(TimeEntry.init)
        }

        var edits: SceneEdits {
            SceneEdits(
                sensitivity: sensitivity,
                regions: regions.map { SensitivityRegion(id: $0.id, start: $0.start.time, end: $0.end.time, value: $0.value) },
                manualCuts: manualCuts.map(\.time),
                ignoredCuts: ignoredCuts.map(\.time)
            )
        }
    }

    struct AssetEntry: Codable {
        var id: UUID
        var name: String
        /// Relative to the package when the file is inside it, otherwise an
        /// absolute path.
        var path: String
        /// Absent when the person hasn't edited the scene list.
        var sceneEdits: SceneEditsEntry?
        /// Absent when the file is aligned with the original.
        var alignmentOffset: TimeEntry?
        /// Absent when the asset has never been replaced.
        var previousPaths: [String]?
        /// Absent in files written before replacement existed.
        var fileStamp: FileStamp?
        /// Absent unless the original was forgotten.
        var referenceForgotten: Bool?
        /// What the file was when last saved (a `MediaKind` name, its
        /// length, rate, codec, `ProjectColorSpace` name and whether it
        /// has sound), so an asset whose file can't be opened stays in the
        /// project, offline, rather than being dropped. Absent in files
        /// written before this.
        var kind: String?
        var duration: TimeEntry?
        var frameRate: Double?
        var codec: String?
        var colorSpace: String?
        var hasAudio: Bool?
    }

    var formatVersion: Int
    var id: UUID
    var name: String
    var rootTimelineID: UUID
    /// Absent in files written before scene detection; reads as balanced.
    var defaultSensitivity: Double?
    /// Absent while imports are copied into the package (the default).
    var copiesMediaOnImport: Bool?
    /// Absent while it is the default, half a frame on each side.
    var canvasMargin: Double?
    var assets: [AssetEntry]
    var timelines: [TimelineEntry]
}

struct ProjectFileHeader: Decodable {
    var formatVersion: Int?
}

// MARK: - Shape

extension ProjectFile {
    /// The pieces of the schema that projects and presets share: the effects.
    enum ShapeKit {
        typealias O = JSONObjectShape
        static func object(_ fields: [O.Field], oneOf: [[String]] = []) -> JSONObjectShape {
            JSONObjectShape(fields: fields, oneOf: oneOf)
        }

        static let ease = JSONShape.object(object([.required("influence", .number), .required("speed", .number)]))
        static func keyframe(_ value: JSONShape) -> JSONShape {
            .object(object([
                .required("time", .time), .required("value", value),
                .optional("easeIn", ease), .optional("easeOut", ease),
            ]))
        }
        static func property(_ value: JSONShape) -> JSONShape {
            .object(object([.optional("value", value), .optional("keyframes", .array(keyframe(value)))], oneOf: [["value", "keyframes"]]))
        }

        static func control(_ kind: ControlKind) -> JSONObjectShape {
            let count = kind.defaultValues.count
            let value: JSONShape = switch kind {
            case .mode: .choice(BlendMode.allCases.map(\.rawValue), noun: "blend mode")
            case .matteMode: .choice(MatteMode.allCases.map(\.rawValue), noun: "matte mode")
            default: count > 1 ? .numbers(count: count) : .number
            }
            var fields: [O.Field] = [
                .required("id", .uuid), .required("kind", .string), .optional("enabled", .bool),
            ]
            if kind.isChoice {
                fields.append(.required("value", value))
            } else {
                fields += [.optional("value", value), .optional("keyframes", .array(keyframe(value)))]
            }
            if kind == .scale { fields.append(.optional("linked", .bool)) }
            return object(fields, oneOf: kind.isChoice ? [] : [["value", "keyframes"]])
        }

        static func effect(_ kind: EffectKind, extra: [O.Field]) -> JSONObjectShape {
            var fields: [O.Field] = [
                .required("id", .uuid), .required("kind", .string), .optional("name", .string), .optional("enabled", .bool),
            ]
            switch kind {
            case .transform: fields.append(.optional("movesAnchor", .bool))
            case .blending: fields.append(.optional("against", .uuid))
            case .color: break
            case .matte:
                fields.append(.optional("input", .object(object([
                    .optional("asset", .uuid), .optional("timeline", .uuid),
                    .optional("offset", .time), .optional("loops", .bool),
                ], oneOf: [["asset", "timeline"]]))))
            }
            fields += extra
            let controls = Dictionary(uniqueKeysWithValues: kind.controlKinds.map { ($0.rawValue, control($0)) })
            fields.append(.required("controls", .array(.tagged(key: "kind", noun: "control kind", controls))))
            return object(fields)
        }

        /// The shape of a list of effects, with `extra` fields allowed on
        /// each (a project's effects may have paste changes, a preset's
        /// may say what was left behind).
        static func effects(extra: [O.Field]) -> JSONShape {
            let byKind = Dictionary(uniqueKeysWithValues: EffectKind.allCases.map { ($0.rawValue, effect($0, extra: extra)) })
            return .array(.tagged(key: "kind", noun: "effect kind", byKind))
        }
    }

    /// What a project file may contain. Loading checks a file against this
    /// before decoding it, so every key and value is one the app knows.
    static let shape: JSONShape = {
        typealias O = JSONObjectShape
        func object(_ fields: [O.Field], oneOf: [[String]] = []) -> JSONObjectShape { ShapeKit.object(fields, oneOf: oneOf) }
        func keyframe(_ value: JSONShape) -> JSONShape { ShapeKit.keyframe(value) }
        func property(_ value: JSONShape) -> JSONShape { ShapeKit.property(value) }
        let effects = ShapeKit.effects(extra: [.optional("pasteChanges", .array(.object(object([
            .required("kind", .choice(PasteChange.Kind.allCases.map(\.rawValue), noun: "paste change")),
            .required("detail", .string), .optional("count", .integer),
        ]))))])

        let curvePoint = JSONShape.object(object([
            .required("time", .number), .required("value", .number),
            .optional("in", .numbers(count: 2)), .optional("out", .numbers(count: 2)),
        ]))
        let echo = JSONShape.object(object([.required("count", .integer), .required("delay", .time), .required("decay", .number)]))
        let transition = JSONShape.object(object([
            .required("kind", .choice(TransitionKind.savedNames, noun: "transition kind")),
            .required("duration", .time), .optional("curve", .array(curvePoint)), .optional("lead", .time),
            .optional("direction", .choice(TransitionDirection.allCases.map(\.rawValue), noun: "transition direction")),
            .optional("color", .numbers(count: 3)), .optional("center", .numbers(count: 2)),
            .optional("shape", .choice(IrisShape.allCases.map(\.rawValue), noun: "iris shape")),
            .optional("count", .integer),
            .optional("order", .choice(GridOrder.allCases.map(\.rawValue), noun: "grid order")),
            .optional("amount", .number), .optional("matte", .string),
        ]))
        let clip = JSONShape.object(object([
            .required("id", .uuid),
            .required("source", .tagged(key: "kind", noun: "source kind", [
                "media": object([.required("kind", .string), .required("id", .uuid)]),
                "timeline": object([.required("kind", .string), .required("id", .uuid)]),
                "adjustment": object([.required("kind", .string)]),
            ])),
            .required("startOffset", .time), .required("trimStart", .time), .required("trimEnd", .time),
            .required("autoMatteEnabled", .bool),
            .optional("streams", .choice(["video", "audio"], noun: "stream")),
            .optional("transitionIn", transition), .optional("transitionOut", transition),
            .optional("anchorPoint", property(.numbers(count: 2))),
            .optional("effects", effects),
            .optional("volume", property(.number)),
            .optional("passThrough", .bool),
            .optional("time", .object(object([
                .optional("speed", property(.number)),
                .optional("frameBlending", .choice(["blend", "opticalFlow"], noun: "frame blending")),
                .optional("echo", echo),
                .optional("sound", .choice(["changePitch", "mute"], noun: "sound mode")),
            ]))),
            .optional("shutter", .object(object([
                .optional("motionBlur", .object(object([.required("angle", .number), .required("samples", .integer)]))),
                .optional("trails", echo),
            ]))),
        ]))
        let layer = JSONShape.object(object([
            .required("id", .uuid), .optional("customName", .string),
            .required("kind", .choice(LayerKind.allCases.map(\.rawValue), noun: "layer kind")),
            .required("clips", .array(clip)), .optional("volume", property(.number)),
            .optional("adjustment", .bool), .optional("reach", .uuid),
        ]))
        let timeline = JSONShape.object(object([
            .required("id", .uuid), .required("name", .string),
            .required("width", .number), .required("height", .number), .required("frameRate", .number),
            .required("colorSpace", .choice(ProjectColorSpace.allCases.map(\.rawValue), noun: "color space")),
            .required("layers", .array(layer)),
            .optional("sections", .array(.object(object([
                .required("id", .uuid), .required("name", .string), .required("start", .time), .required("end", .time),
            ])))),
        ]))
        let sceneEdits = JSONShape.object(object([
            .optional("sensitivity", .number),
            .required("regions", .array(.object(object([
                .required("id", .uuid), .required("start", .time), .required("end", .time), .required("value", .number),
            ])))),
            .required("manualCuts", .array(.time)),
            .required("ignoredCuts", .array(.time)),
        ]))
        let asset = JSONShape.object(object([
            .required("id", .uuid), .required("name", .string), .required("path", .string),
            .optional("sceneEdits", sceneEdits), .optional("alignmentOffset", .time),
            .optional("previousPaths", .array(.string)),
            .optional("fileStamp", .object(object([.required("byteCount", .integer), .optional("modified", .number)]))),
            .optional("referenceForgotten", .bool),
            .optional("kind", .choice(["Video", "Audio"], noun: "media kind")), .optional("duration", .time),
            .optional("frameRate", .number), .optional("codec", .string),
            .optional("colorSpace", .choice(ProjectColorSpace.allCases.map(\.rawValue), noun: "color space")),
            .optional("hasAudio", .bool),
        ]))
        return .object(object([
            .required("formatVersion", .integer), .required("id", .uuid), .required("name", .string),
            .required("rootTimelineID", .uuid), .optional("defaultSensitivity", .number),
            .optional("copiesMediaOnImport", .bool), .optional("canvasMargin", .number),
            .required("assets", .array(asset)), .required("timelines", .array(timeline)),
        ]))
    }()
}
