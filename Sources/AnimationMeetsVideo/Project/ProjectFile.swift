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
        enum Kind: String, Codable { case media, timeline, adjustment, graphic }
        var kind: Kind
        /// The asset or timeline; absent for an adjustment or shape clip.
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
        /// The sound's effects; absent while there are none.
        var audioEffects: [EffectEntry]?
        /// Decibels; absent while at 0 and not animated.
        var volume: PropertyEntry<Double>?
        /// −100 (left) to 100 (right); absent while centered and not
        /// animated.
        var pan: PropertyEntry<Double>?
        /// Nested timelines only; absent unless set.
        var passThrough: Bool?
        /// Absent while the clip plays at its source's own speed with nothing
        /// else done to time.
        var time: ClipTimeEntry?
        /// Absent while there is no motion blur and no trails.
        var shutter: ShutterEntry?
        /// The lowest layer an adjustment clip reaches; absent for every
        /// layer below it.
        var reach: UUID?
        /// `false` for a clip turned off; absent while it plays.
        var enabled: Bool?
        /// `true` for a clip whose sound is muted; absent while it sounds.
        var soundMuted: Bool?
        /// The song the clip follows; absent while it follows none.
        var music: MusicEntry?
        /// `false` for a clip set not to follow the music; absent while it
        /// does.
        var followsMusic: Bool? = nil
    }

    /// Where a clip is tied to a song (see `MusicAttachment`).
    struct MusicEntry: Codable {
        /// The song's clip.
        var song: UUID
        var asset: UUID
        /// The moment of the song, in its source time.
        var time: TimeEntry
        /// The frame of the clip the person chose; absent for its first.
        var frame: TimeEntry?

        init(_ attachment: MusicAttachment) {
            song = attachment.songClipID
            asset = attachment.assetID
            time = TimeEntry(attachment.songTime)
            frame = attachment.frame.map(TimeEntry.init)
        }

        var attachment: MusicAttachment {
            MusicAttachment(songClipID: song, assetID: asset, songTime: time.time, frame: frame?.time)
        }
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
    /// `audioCrossfade` is an `AudioCrossfade` name, absent when the
    /// transition follows the project's.
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
        var audioCrossfade: String?

        init(_ transition: ClipTransition) {
            kind = transition.kind.rawValue
            duration = TimeEntry(transition.duration)
            curve = transition.curve == .linear ? nil : transition.curve.points.map(CurvePointEntry.init)
            lead = transition.lead == .zero ? nil : TimeEntry(transition.lead)
            audioCrossfade = transition.audioCrossfade?.rawValue
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
                options: options.clamped,
                audioCrossfade: audioCrossfade.flatMap(AudioCrossfade.init(rawValue:))
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
        /// The Keyframing effect that wrote it; absent for one set by hand.
        var generatedBy: UUID?
        /// `true` for a hold keyframe; absent otherwise.
        var hold: Bool?

        init<V>(_ keyframe: Keyframe<V>, value: Value) {
            time = TimeEntry(keyframe.time)
            self.value = value
            easeIn = keyframe.easeIn.map(EaseEntry.init)
            easeOut = keyframe.easeOut.map(EaseEntry.init)
            generatedBy = keyframe.generatedBy
            hold = keyframe.hold ? true : nil
        }

        func keyframe<V>(_ value: V) -> Keyframe<V> {
            Keyframe(time: time.time, value: value, easeIn: easeIn?.ease, easeOut: easeOut?.ease, generatedBy: generatedBy, hold: hold ?? false)
        }
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
                keyframes = property.keyframes.map { KeyframeEntry($0, value: encode($0.value)) }
            } else {
                value = encode(property.value)
            }
        }

        func property<V: Interpolatable>(default fallback: V, decode: (Value) -> V?) -> AnimatedValue<V> {
            let frames = (keyframes ?? []).compactMap { entry in decode(entry.value).map(entry.keyframe) }
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
        /// Scale and shape size only; absent while as a new control's.
        var linked: Bool?
        /// Corners only; absent unless squircle.
        var squircle: Bool?
        var value: ControlValueEntry?
        var keyframes: [KeyframeEntry<ControlValueEntry>]?

        init(_ control: EffectControl) {
            id = control.id
            kind = control.kind.savedName
            enabled = control.enabled ? nil : false
            linked = control.kind.isLinkable && control.linked != control.kind.linksByDefault ? control.linked : nil
            squircle = control.kind == .cornerRadius && control.squircle ? true : nil
            if control.kind.isChoice {
                value = .text(control.choice ?? control.kind.defaultChoice ?? "")
            } else if control.number.isAnimated {
                keyframes = control.number.keyframes.map { KeyframeEntry($0, value: ControlValueEntry($0.value)) }
            } else {
                value = ControlValueEntry(control.number.value)
            }
        }

        /// The control, saved under its name within effects of `effect`'s
        /// kind. Nil only for a kind that effect doesn't list, which loading
        /// has already refused.
        func control(in effect: EffectKind) -> EffectControl? {
            guard let kind = effect.controlKind(savedAs: self.kind) else { return nil }
            var control = EffectControl(id: id, kind: kind, enabled: enabled ?? true)
            control.linked = linked ?? kind.linksByDefault
            control.squircle = squircle ?? false
            if kind.isChoice {
                if case .text(let name) = value { control.choice = name }
                return control
            }
            control.number = number(default: control.number.value)
            return control
        }

        /// Its numbers, keyframed or not, or `fallback` when it has none.
        func number(default fallback: ComponentValue) -> AnimatedValue<ComponentValue> {
            let frames = (keyframes ?? []).compactMap { entry in entry.value.components.map(entry.keyframe) }
            return AnimatedValue(value?.components ?? frames.first?.value ?? fallback, keyframes: frames)
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

    /// What a Keyframing effect writes to and how (`KeyframingSetup`).
    struct KeyframingEntry: Codable {
        /// The control's effect and ID, or `volume`; absent with no target.
        var effect: UUID?
        var control: UUID?
        var volume: Bool?
        /// Absent while it drives every component.
        var component: Int?
        /// Absent for Add.
        var combine: String?
        /// Absent for the whole clip.
        var start: TimeEntry?
        var end: TimeEntry?
        /// Absent until it has written.
        var base: PropertyEntry<ControlValueEntry>?
        var beatLayer: UUID?
        /// Audio Keys: `mix`, or the layer or clip it listens to.
        var listensToMix: Bool?
        var listensToLayer: UUID?
        var listensToClip: UUID?
        /// The fingerprints as hexadecimal, since JSON numbers lose 64-bit
        /// precision; absent until it has written.
        var readPrint: String?
        var writtenPrint: String?

        init(_ setup: KeyframingSetup) {
            switch setup.target {
            case .control(let effectID, let controlID)?:
                effect = effectID
                control = controlID
            case .volume?: volume = true
            case nil: break
            }
            component = setup.component
            combine = setup.combine == .add ? nil : setup.combine.rawValue
            start = setup.range.map { TimeEntry($0.start) }
            end = setup.range.map { TimeEntry($0.end) }
            base = setup.base.map { PropertyEntry($0, encode: ControlValueEntry.init) }
            beatLayer = setup.beatLayer
            switch setup.audioSource {
            case .mix?: listensToMix = true
            case .layer(let id)?: listensToLayer = id
            case .clip(let id)?: listensToClip = id
            case nil: break
            }
            readPrint = setup.readPrint.map { String($0, radix: 16) }
            writtenPrint = setup.writtenPrint.map { String($0, radix: 16) }
        }

        var setup: KeyframingSetup {
            var setup = KeyframingSetup()
            if let effect, let control {
                setup.target = .control(effectID: effect, controlID: control)
            } else if volume == true {
                setup.target = .volume
            }
            setup.component = component
            setup.combine = combine.flatMap(KeyframingCombine.init(rawValue:)) ?? .add
            if let start, let end { setup.range = CMTimeRange(start: start.time, end: end.time) }
            setup.base = base?.property(default: ComponentValue(values: [])) { $0.components }
            setup.beatLayer = beatLayer
            setup.audioSource = listensToLayer.map { .layer($0) } ?? listensToClip.map { .clip($0) } ?? (listensToMix == true ? .mix : nil)
            setup.readPrint = readPrint.flatMap { UInt64($0, radix: 16) }
            setup.writtenPrint = writtenPrint.flatMap { UInt64($0, radix: 16) }
            return setup
        }
    }

    /// A Text effect's words, the PostScript name of its font, and its
    /// styled runs.
    struct TextEntry: Codable {
        var string: String
        var font: String
        /// Absent while no letters are styled apart.
        var runs: [TextRunEntry]?

        init(_ content: TextContent) {
            string = content.string
            font = content.fontName
            runs = content.runs.isEmpty ? nil : content.runs.map(TextRunEntry.init)
        }

        var content: TextContent {
            TextContent(string: string, fontName: font, runs: (runs ?? []).map(\.run))
        }
    }

    /// Letters styled apart from the block: where they start and how many
    /// UTF-16 code units they span, and each setting they override.
    struct TextRunEntry: Codable {
        var start: Int
        var length: Int
        var font: String?
        var size: Double?
        var tracking: Double?
        var baselineShift: Double?
        var horizontalScale: Double?
        var verticalScale: Double?
        /// A `TextCase` name.
        var textCase: String?
        var underline: Bool?
        var strikethrough: Bool?
        var fill: [Double]?
        var stroke: [Double]?
        /// Thousandths of an em after the run's letters, set by hand.
        var kerning: Double?
        /// A `TextPosition` name.
        var position: String?

        init(_ run: TextRun) {
            start = run.start
            length = run.length
            let style = run.style
            font = style.fontName
            size = style.size
            tracking = style.tracking
            baselineShift = style.baselineShift
            horizontalScale = style.horizontalScale
            verticalScale = style.verticalScale
            textCase = style.textCase?.rawValue
            underline = style.underline
            strikethrough = style.strikethrough
            fill = style.fill
            stroke = style.stroke
            kerning = style.kerning
            position = style.position?.rawValue
        }

        var run: TextRun {
            TextRun(start: start, length: length, style: TextStyle(
                fontName: font, size: size, tracking: tracking, baselineShift: baselineShift,
                horizontalScale: horizontalScale, verticalScale: verticalScale, textCase: textCase.flatMap(TextCase.init(rawValue:)),
                underline: underline, strikethrough: strikethrough, fill: fill, stroke: stroke, kerning: kerning,
                position: position.flatMap(TextPosition.init(rawValue:))
            ))
        }

        static let shape = JSONShape.object(JSONObjectShape(fields: [
            .required("start", .integer), .required("length", .integer),
            .optional("font", .string), .optional("size", .number), .optional("tracking", .number),
            .optional("baselineShift", .number), .optional("horizontalScale", .number), .optional("verticalScale", .number),
            .optional("textCase", .choice(TextCase.allCases.map(\.rawValue), noun: "case")),
            .optional("underline", .bool), .optional("strikethrough", .bool),
            .optional("fill", .numbers(count: 4)), .optional("stroke", .numbers(count: 4)), .optional("kerning", .number),
            .optional("position", .choice(TextPosition.allCases.map(\.rawValue), noun: "position")),
        ]))
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
        /// For a Keyframing effect, what it writes to.
        var keyframing: KeyframingEntry?
        /// For a Text effect, its words and font.
        var text: TextEntry?
        /// Absent unless some are unresolved.
        var pasteChanges: [PasteChangeRecord]?
        /// Presets only: what the effect's input and Against were called
        /// when it was saved, since neither comes along.
        var inputName: String?
        var againstName: String?
        var controls: [ControlEntry]
        /// An effect from a package, as it was read; for a missing effect,
        /// what is written back.
        var saved: JSONValue?
        /// Whether its controls couldn't all be read, as a newer version of
        /// its package may save them.
        var controlsUnread = false

        private enum CodingKeys: String, CodingKey {
            case id, kind, name, enabled, movesAnchor, against, input, keyframing, text, pasteChanges, inputName, againstName, controls
        }

        init(_ effect: Effect) {
            if let missing = effect.missing {
                // As it was saved, but moved or turned off since.
                var saved = missing.saved
                saved["id"] = .string(effect.id.uuidString)
                saved["enabled"] = effect.enabled ? nil : .bool(false)
                self.saved = saved
                id = effect.id
                kind = missing.kind
                controls = []
                return
            }
            id = effect.id
            kind = effect.kind.rawValue
            name = effect.name
            enabled = effect.enabled ? nil : false
            movesAnchor = effect.kind == .transform && !effect.movesAnchor ? false : nil
            against = effect.kind.readsAgainst ? effect.against : nil
            input = effect.kind.takesInput ? effect.input.map(InputEntry.init) : nil
            keyframing = effect.keyframing.map(KeyframingEntry.init)
            text = effect.kind == .text ? effect.text.map(TextEntry.init) : nil
            pasteChanges = effect.pasteChanges.isEmpty ? nil : effect.pasteChanges.map(PasteChangeRecord.init)
            controls = effect.controls.map(ControlEntry.init)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            kind = try container.decode(String.self, forKey: .kind)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            let fromPackage = kind.contains(".")
            if fromPackage { saved = try JSONValue(from: decoder) }
            guard !fromPackage || EffectKind(rawValue: kind) != nil else {
                // Not installed: only what it is and whether it's on are read.
                controls = []
                return
            }
            movesAnchor = try container.decodeIfPresent(Bool.self, forKey: .movesAnchor)
            against = try container.decodeIfPresent(UUID.self, forKey: .against)
            input = try container.decodeIfPresent(InputEntry.self, forKey: .input)
            keyframing = try container.decodeIfPresent(KeyframingEntry.self, forKey: .keyframing)
            text = try container.decodeIfPresent(TextEntry.self, forKey: .text)
            pasteChanges = try container.decodeIfPresent([PasteChangeRecord].self, forKey: .pasteChanges)
            inputName = try container.decodeIfPresent(String.self, forKey: .inputName)
            againstName = try container.decodeIfPresent(String.self, forKey: .againstName)
            if fromPackage {
                let read = try? container.decode([ControlEntry].self, forKey: .controls)
                controls = read ?? []
                controlsUnread = read == nil
            } else {
                controls = try container.decode([ControlEntry].self, forKey: .controls)
            }
        }

        func encode(to encoder: Encoder) throws {
            if let saved {
                try saved.encode(to: encoder)
                return
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(enabled, forKey: .enabled)
            try container.encodeIfPresent(movesAnchor, forKey: .movesAnchor)
            try container.encodeIfPresent(against, forKey: .against)
            try container.encodeIfPresent(input, forKey: .input)
            try container.encodeIfPresent(keyframing, forKey: .keyframing)
            try container.encodeIfPresent(text, forKey: .text)
            try container.encodeIfPresent(pasteChanges, forKey: .pasteChanges)
            try container.encodeIfPresent(inputName, forKey: .inputName)
            try container.encodeIfPresent(againstName, forKey: .againstName)
            try container.encode(controls, forKey: .controls)
        }

        var effect: Effect? {
            if let saved {
                // From a package: missing when it isn't installed, or doesn't
                // list a control the effect was saved with.
                func missing(_ reason: MissingEffect.Reason) -> Effect {
                    .missing(MissingEffect(kind: kind, reason: reason, saved: saved), id: id, enabled: enabled ?? true)
                }
                guard let installed = EffectKind(rawValue: kind) else { return missing(.notInstalled) }
                if controlsUnread || controls.contains(where: { installed.controlKind(savedAs: $0.kind) == nil }) {
                    return missing(.needsNewerVersion)
                }
            }
            guard let kind = EffectKind(rawValue: kind) else { return nil }
            var made = controls.compactMap { $0.control(in: kind) }
            let legacy = controls.filter { Equalizer.legacyNames.contains($0.kind) }
            if kind == .equalizer, !legacy.isEmpty {
                // Saved before the EQ had bands: played as it was heard,
                // with any band saved alongside taking its place.
                let migrated = Equalizer.controls(migrating: legacy.map {
                    Equalizer.LegacyControl(
                        name: $0.kind, id: $0.id, enabled: $0.enabled ?? true, number: $0.number(default: ComponentValue(values: [0]))
                    )
                })
                made = migrated.map { old in made.first { $0.kind == old.kind } ?? old }
            }
            var effect = Effect(id: id, kind: kind, name: name, controls: made)
            effect.enabled = enabled ?? true
            effect.movesAnchor = movesAnchor ?? true
            effect.against = against
            effect.input = input?.input
            if kind.isKeyframing { effect.keyframing = keyframing?.setup ?? KeyframingSetup() }
            if kind == .text { effect.text = text?.content ?? TextContent() }
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
        /// −100 (left) to 100 (right), on Sound and Music layers; absent
        /// while centered and not animated.
        var pan: PropertyEntry<Double>?
        /// Sound and Music layers' sound effects; absent while there are
        /// none.
        var audioEffects: [EffectEntry]?
        /// True for an adjustment layer; absent otherwise.
        var adjustment: Bool?
        /// The lowest layer an adjustment layer reached, in projects saved
        /// before each adjustment clip had a reach of its own: read into
        /// the layer's clips, and never written.
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

    struct BeatEntry: Codable {
        var time: TimeEntry
        var position: Int
        /// Absent unless the person placed or moved the beat.
        var pinned: Bool?
    }

    struct BeatSectionEntry: Codable {
        var id: UUID
        var kind: String
        var start: TimeEntry
        var end: TimeEntry
        var beatsPerMeasure: Int
        /// Absent unless the person set the beats per measure.
        var measureSet: Bool?
        var steadiness: String
        var confirmed: Bool
        var beats: [BeatEntry]

        init(_ section: BeatSection) {
            id = section.id
            kind = section.kind.rawValue
            start = TimeEntry(section.start)
            end = TimeEntry(section.end)
            beatsPerMeasure = section.beatsPerMeasure
            measureSet = section.isMeasureSet ? true : nil
            steadiness = section.steadiness.rawValue
            confirmed = section.isConfirmed
            beats = section.beats.map { BeatEntry(time: TimeEntry($0.time), position: $0.position, pinned: $0.isPinned ? true : nil) }
        }

        /// The shape check has already limited the kind and steadiness to
        /// known names.
        var section: BeatSection {
            var section = BeatSection(
                id: id, kind: BeatSection.Kind(rawValue: kind) ?? .none, start: start.time, end: end.time,
                beatsPerMeasure: beatsPerMeasure, isMeasureSet: measureSet ?? false, steadiness: BeatSection.Steadiness(rawValue: steadiness) ?? .click,
                isConfirmed: confirmed,
                beats: beats.map { MappedBeat(time: $0.time.time, position: $0.position, isPinned: $0.pinned ?? false) }
            )
            section.normalize()
            return section
        }
    }

    struct BeatMapEntry: Codable {
        /// Absent unless the person chose to mark sections.
        var usesSections: Bool?
        var sections: [BeatSectionEntry]

        init(_ map: BeatMap) {
            usesSections = map.usesSections ? true : nil
            sections = map.sections.map(BeatSectionEntry.init)
        }

        var map: BeatMap {
            BeatMap(
                sections: sections.map(\.section).sorted { CMTimeCompare($0.start, $1.start) < 0 },
                usesSections: usesSections ?? false
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
        /// Absent until the person beat matches the asset.
        var beatMap: BeatMapEntry?
        /// Absent when the file is aligned with the original.
        var alignmentOffset: TimeEntry?
        /// How long the original file was; absent until the asset is replaced.
        var originalDuration: TimeEntry?
        /// Absent when the asset has never been replaced.
        var previousPaths: [String]?
        /// Absent in files written before replacement existed.
        var fileStamp: FileStamp?
        /// Absent unless the original was forgotten.
        var referenceForgotten: Bool?
        /// Absent unless the asset's scenes are not to be detected.
        var skipsSceneDetection: Bool?
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
    /// An `AudioCrossfade` name; absent while it is the default S-curve.
    var jointAudioCrossfade: String?
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
                .optional("easeIn", ease), .optional("easeOut", ease), .optional("generatedBy", .uuid), .optional("hold", .bool),
            ]))
        }
        static let keyframing = object([
            .optional("effect", .uuid), .optional("control", .uuid), .optional("volume", .bool),
            .optional("component", .integer),
            .optional("combine", .choice(KeyframingCombine.allCases.map(\.rawValue), noun: "combine mode")),
            .optional("start", .time), .optional("end", .time),
            .optional("base", property(.numberOrNumbers)), .optional("beatLayer", .uuid),
            .optional("readPrint", .string), .optional("writtenPrint", .string),
            .optional("listensToMix", .bool), .optional("listensToLayer", .uuid), .optional("listensToClip", .uuid),
        ])
        static func property(_ value: JSONShape) -> JSONShape {
            .object(object([.optional("value", value), .optional("keyframes", .array(keyframe(value)))], oneOf: [["value", "keyframes"]]))
        }

        static func control(_ kind: ControlKind) -> JSONObjectShape {
            let count = kind.defaultValues.count
            let value: JSONShape = switch kind {
            case .mode: .choice(BlendMode.allCases.map(\.rawValue), noun: "blend mode")
            case .matteMode: .choice(MatteMode.allCases.map(\.rawValue), noun: "matte mode")
            case _ where kind.isChoice: .choice(kind.choiceOptions.map(\.id), noun: kind.name.lowercased())
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
            if kind.isLinkable { fields.append(.optional("linked", .bool)) }
            if kind == .cornerRadius { fields.append(.optional("squircle", .bool)) }
            return object(fields, oneOf: kind.isChoice ? [] : [["value", "keyframes"]])
        }

        static func effect(_ kind: EffectKind, extra: [O.Field]) -> JSONObjectShape {
            var fields: [O.Field] = [
                .required("id", .uuid), .required("kind", .string), .optional("name", .string), .optional("enabled", .bool),
            ]
            if kind == .transform { fields.append(.optional("movesAnchor", .bool)) }
            if kind.readsAgainst { fields.append(.optional("against", .uuid)) }
            if kind.takesInput {
                fields.append(.optional("input", .object(object([
                    .optional("asset", .uuid), .optional("timeline", .uuid),
                    .optional("offset", .time), .optional("loops", .bool),
                ], oneOf: [["asset", "timeline"]]))))
            }
            if kind.isKeyframing { fields.append(.optional("keyframing", .object(keyframing))) }
            if kind == .text {
                fields.append(.optional("text", .object(object([
                    .required("string", .string), .required("font", .string), .optional("runs", .array(TextRunEntry.shape)),
                ]))))
            }
            fields += extra
            var controls = Dictionary(uniqueKeysWithValues: kind.controlKinds.map { ($0.savedName, control($0)) })
            if kind == .equalizer {
                // The controls it had before bands, which load as bands.
                let legacy = object([
                    .required("id", .uuid), .required("kind", .string), .optional("enabled", .bool),
                    .optional("value", .number), .optional("keyframes", .array(keyframe(.number))),
                ], oneOf: [["value", "keyframes"]])
                for name in Equalizer.legacyNames { controls[name] = legacy }
            }
            if kind.definition.package != nil {
                // Another version of the package may save controls this one
                // doesn't list; such an effect loads as missing.
                let other = JSONObjectShape(fields: [.required("id", .uuid), .required("kind", .string)], allowsOtherKeys: true)
                let others = JSONOtherTags(accepts: { _ in true }, shape: other)
                fields.append(.required("controls", .array(.taggedOr(key: "kind", noun: "control kind", controls, others: others))))
            } else {
                fields.append(.required("controls", .array(.tagged(key: "kind", noun: "control kind", controls))))
            }
            return object(fields)
        }

        /// The shape of a list of effects, with `extra` fields allowed on
        /// each (a project's effects may have paste changes, a preset's
        /// may say what was left behind). With `allowingMissing`, as a
        /// picture's effects are, a kind with a dot that isn't installed is
        /// a package's, kept as it is: only its ID, name and whether it is
        /// on are checked.
        static func effects(extra: [O.Field], allowingMissing: Bool = false) -> JSONShape {
            let byKind = Dictionary(uniqueKeysWithValues: EffectKind.all.map { ($0.rawValue, effect($0, extra: extra)) })
            guard allowingMissing else { return .array(.tagged(key: "kind", noun: "effect kind", byKind)) }
            let missing = JSONObjectShape(
                fields: [.required("id", .uuid), .required("kind", .string), .optional("name", .string), .optional("enabled", .bool)],
                allowsOtherKeys: true
            )
            let others = JSONOtherTags(accepts: { $0.contains(".") }, shape: missing)
            return .array(.taggedOr(key: "kind", noun: "effect kind", byKind, others: others))
        }
    }

    /// What a project file may contain. Loading checks a file against this
    /// before decoding it, so every key and value is one the app knows.
    /// Made at each load, since the effect kinds it knows are the
    /// registry's.
    static var shape: JSONShape {
        typealias O = JSONObjectShape
        func object(_ fields: [O.Field], oneOf: [[String]] = []) -> JSONObjectShape { ShapeKit.object(fields, oneOf: oneOf) }
        func keyframe(_ value: JSONShape) -> JSONShape { ShapeKit.keyframe(value) }
        func property(_ value: JSONShape) -> JSONShape { ShapeKit.property(value) }
        let pasteChanges: [O.Field] = [.optional("pasteChanges", .array(.object(object([
            .required("kind", .choice(PasteChange.Kind.allCases.map(\.rawValue), noun: "paste change")),
            .required("detail", .string), .optional("count", .integer),
        ]))))]
        // Package effects are all pictures', so only a picture's stack can
        // hold one that isn't installed.
        let effects = ShapeKit.effects(extra: pasteChanges, allowingMissing: true)
        let audioEffects = ShapeKit.effects(extra: pasteChanges)

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
            .optional("audioCrossfade", .choice(AudioCrossfade.allCases.map(\.rawValue), noun: "audio crossfade")),
        ]))
        let clip = JSONShape.object(object([
            .required("id", .uuid),
            .required("source", .tagged(key: "kind", noun: "source kind", [
                "media": object([.required("kind", .string), .required("id", .uuid)]),
                "timeline": object([.required("kind", .string), .required("id", .uuid)]),
                "adjustment": object([.required("kind", .string)]),
                "graphic": object([.required("kind", .string)]),
            ])),
            .required("startOffset", .time), .required("trimStart", .time), .required("trimEnd", .time),
            .required("autoMatteEnabled", .bool),
            .optional("streams", .choice(["video", "audio"], noun: "stream")),
            .optional("transitionIn", transition), .optional("transitionOut", transition),
            .optional("anchorPoint", property(.numbers(count: 2))),
            .optional("effects", effects), .optional("audioEffects", audioEffects),
            .optional("volume", property(.number)),
            .optional("pan", property(.number)),
            .optional("passThrough", .bool),
            .optional("reach", .uuid),
            .optional("enabled", .bool),
            .optional("soundMuted", .bool),
            .optional("music", .object(object([
                .required("song", .uuid), .required("asset", .uuid), .required("time", .time), .optional("frame", .time),
            ]))),
            .optional("followsMusic", .bool),
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
            .required("clips", .array(clip)), .optional("volume", property(.number)), .optional("pan", property(.number)),
            .optional("audioEffects", audioEffects),
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
        let beatMap = JSONShape.object(object([
            .optional("usesSections", .bool),
            .required("sections", .array(.object(object([
                .required("id", .uuid),
                .required("kind", .choice(BeatSection.Kind.allCases.map(\.rawValue), noun: "beat section kind")),
                .required("start", .time), .required("end", .time),
                .required("beatsPerMeasure", .integer), .optional("measureSet", .bool),
                .required("steadiness", .choice(BeatSection.Steadiness.allCases.map(\.rawValue), noun: "steadiness")),
                .required("confirmed", .bool),
                .required("beats", .array(.object(object([
                    .required("time", .time), .required("position", .integer), .optional("pinned", .bool),
                ])))),
            ])))),
        ]))
        let asset = JSONShape.object(object([
            .required("id", .uuid), .required("name", .string), .required("path", .string),
            .optional("sceneEdits", sceneEdits), .optional("beatMap", beatMap), .optional("alignmentOffset", .time), .optional("originalDuration", .time),
            .optional("previousPaths", .array(.string)),
            .optional("fileStamp", .object(object([.required("byteCount", .integer), .optional("modified", .number)]))),
            .optional("referenceForgotten", .bool),
            .optional("skipsSceneDetection", .bool),
            .optional("kind", .choice(MediaKind.allCases.map(\.rawValue), noun: "media kind")), .optional("duration", .time),
            .optional("frameRate", .number), .optional("codec", .string),
            .optional("colorSpace", .choice(ProjectColorSpace.allCases.map(\.rawValue), noun: "color space")),
            .optional("hasAudio", .bool),
        ]))
        return .object(object([
            .required("formatVersion", .integer), .required("id", .uuid), .required("name", .string),
            .required("rootTimelineID", .uuid), .optional("defaultSensitivity", .number),
            .optional("copiesMediaOnImport", .bool), .optional("canvasMargin", .number),
            .optional("jointAudioCrossfade", .choice(AudioCrossfade.allCases.map(\.rawValue), noun: "audio crossfade")),
            .required("assets", .array(asset)), .required("timelines", .array(timeline)),
        ]))
    }
}
