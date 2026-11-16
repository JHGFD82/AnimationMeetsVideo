import CoreMedia
import Foundation

// The changes a script can make (the table in docs/python-scripting.md,
// "The amv module"). Each goes through the function the editor's own
// controls call, on a copy of the working copy, and is taken by `commit`,
// so a script can't leave the project in a state the app couldn't have
// made. A change with no such function isn't offered; the table grows by
// adding a case here.

extension ProjectBridge {
    /// A change, if `call` is one; nil for any other call.
    func change(_ call: HelperCall) throws -> JSONValue? {
        var project = working
        let result: JSONValue
        switch call.method {
        // MARK: Project and timelines
        case "add_timeline":
            let main = project.timeline(id: project.rootTimelineID) ?? project.timelines[0]
            var size = main.frameSize
            if let pair = call["frame_size"]?.array, pair.count == 2, let width = pair[0].number, let height = pair[1].number {
                guard width >= 1, height >= 1, width <= 16_384, height <= 16_384 else {
                    throw ScriptCallError.value("A frame size is two whole numbers of pixels, up to 16384")
                }
                size = CGSize(width: width.rounded(), height: height.rounded())
            }
            let rate = call["frame_rate"]?.number ?? main.frameRate
            guard rate.isFinite, rate >= 1, rate <= 1000 else { throw ScriptCallError.value("A frame rate is from 1 to 1000") }
            let name = try nonEmpty(call["name"]?.string ?? "Timeline", what: "A timeline's name")
            result = JSONValue(project.addTimeline(name: name, frameSize: size, frameRate: rate, colorSpace: main.colorSpace))
        case "set_timeline_name":
            let timeline = try self.timeline(call)
            project.renameTimeline(timeline.id, to: try nonEmpty(call["name"]?.string, what: "A timeline's name"))
            result = .null
        case "place":
            let timeline = try self.timeline(call)
            let asset = try self.asset(call)
            guard let placed = project.placeAsset(asset.id, intoTimeline: timeline.id) else {
                throw ScriptCallError.value("\u{201C}\(asset.name)\u{201D} can't be placed on \u{201C}\(timeline.name)\u{201D}")
            }
            result = JSONValue(placed.clipID)

        // MARK: Layers
        case "set_layer_name":
            let (timeline, layer) = try self.layer(call)
            let name = call["name"]?.string?.trimmingCharacters(in: .whitespaces)
            project.renameLayer(layer.id, in: timeline.id, to: name?.isEmpty == false ? name : nil)
            result = .null
        case "move_layer":
            let (timeline, layer) = try self.layer(call)
            guard let index = call["index"]?.int else { throw ScriptCallError.type("move() takes an index") }
            project.moveLayer(layer.id, in: timeline.id, toIndex: index)
            result = .null
        case "delete_layer":
            let (timeline, layer) = try self.layer(call)
            project.deleteLayer(layer.id, in: timeline.id)
            result = .null

        // MARK: Clips
        case "set_start":
            let (timelineID, clip, layer) = try self.clip(call)
            let time = try ScriptTime.time(call["time"], in: project.timeline(id: timelineID))
            project.moveClip(clip.id, in: timelineID, layer: layer.id, to: time)
            result = .null
        case "set_trim_start", "set_trim_end":
            let (timelineID, clip, layer) = try self.clip(call)
            let time = try ScriptTime.time(call["time"], in: project.timeline(id: timelineID))
            if call.method == "set_trim_start" {
                project.trimClipStart(clip.id, in: timelineID, layer: layer.id, to: time, sceneTracks: context.sceneTracks)
            } else {
                project.trimClipEnd(clip.id, in: timelineID, layer: layer.id, to: time, sceneTracks: context.sceneTracks)
            }
            result = .null
        case "split":
            let (timelineID, clip, layer) = try self.clip(call)
            let time = try ScriptTime.time(call["time"], in: project.timeline(id: timelineID))
            guard time > clip.startOffset, time < clip.endOffset else {
                throw ScriptCallError.value("A clip is split at a time strictly inside it, between its start and end")
            }
            let before = Set(layer.clips.map(\.id))
            project.split(clip.id, in: timelineID, layer: layer.id, atTimelineTime: time)
            let halves = (project.timeline(id: timelineID)?.layer(id: layer.id)?.clips ?? [])
                .filter { !before.contains($0.id) }
                .sorted { $0.startOffset < $1.startOffset }
            guard halves.count == 2 else { throw ScriptCallError.value("The clip couldn't be split there") }
            result = [JSONValue(halves[0].id), JSONValue(halves[1].id)]
        case "delete_clip":
            let (timelineID, clip, layer) = try self.clip(call)
            project.deleteClip(clip.id, in: timelineID, layer: layer.id)
            result = .null

        // MARK: Effects
        case "add_effect":
            let (timelineID, clip, _) = try self.clip(call)
            let kind = try effectKind(call["kind"]?.string)
            if let sound = call["sound"]?.bool, sound != kind.isAudio {
                throw ScriptCallError.value(kind.isAudio
                    ? "\(kind.name) is a sound effect: add it to sound_effects"
                    : "\(kind.name) isn't a sound effect: add it to effects")
            }
            guard let id = project.addEffect(kind, toClip: clip.id, in: timelineID, at: call["index"]?.int) else {
                throw ScriptCallError.value("\u{201C}\(working.clipName(clip.id, in: timelineID))\u{201D} can't take \(kind.name)")
            }
            result = JSONValue(id)
        case "remove_effect":
            let (timelineID, clip, effect) = try self.effect(call)
            project.removeEffect(effect.id, fromClip: clip.id, in: timelineID)
            result = .null
        case "move_effect":
            let (timelineID, clip, effect) = try self.effect(call)
            guard let index = call["index"]?.int else { throw ScriptCallError.type("move() takes an index") }
            project.moveEffect(effect.id, ofClip: clip.id, in: timelineID, toIndex: index)
            result = .null
        case "set_effect":
            let (timelineID, clip, effect) = try self.effect(call)
            let renames = call.arguments.keys.contains("name")
            let name = call["name"]?.string?.trimmingCharacters(in: .whitespaces)
            let enabled = call["enabled"]?.bool
            project.editEffect(effect.id, ofClip: clip.id, in: timelineID) { effect in
                if renames { effect.name = name?.isEmpty == false ? name : nil }
                if let enabled { effect.enabled = enabled }
            }
            result = .null

        // MARK: Controls
        case "set_control":
            let target = try self.target(call)
            guard case .control(let control) = target.kind, case .control(let effectID, let controlID) = target.target else {
                throw ScriptCallError.type("A clip's volume can't be set from a script yet")
            }
            if control.kind.isChoice {
                guard let option = call["value"]?.string else {
                    throw ScriptCallError.type("\(control.kind.name) is a choice: give one of \(Self.options(of: control.kind))")
                }
                guard control.kind.choiceOptions.contains(where: { $0.id == option }) else {
                    throw ScriptCallError.value("\(control.kind.name) has no option \u{201C}\(option)\u{201D}: give one of \(Self.options(of: control.kind))")
                }
                project.editEffect(effectID, ofClip: target.clip.id, in: target.timelineID) { effect in
                    if let c = effect.controlIndex(controlID) { effect.controls[c].choice = option }
                }
            } else {
                guard !control.number.isAnimated else {
                    throw ScriptCallError.value("\(control.kind.name) is keyframed: set its keyframes, or set them to [] first")
                }
                let value = try ScriptValue.components(call["value"], for: control.kind, count: control.number.value.values.count)
                project.editEffect(effectID, ofClip: target.clip.id, in: target.timelineID) { effect in
                    if let c = effect.controlIndex(controlID) { effect.controls[c].number = AnimatedValue(value) }
                }
            }
            result = .null
        case "set_keyframes":
            let target = try self.target(call)
            guard case .control(let control) = target.kind, case .control(let effectID, let controlID) = target.target else {
                throw ScriptCallError.type("A clip's volume can't be set from a script yet")
            }
            guard !control.kind.isChoice else { throw ScriptCallError.type("\(control.kind.name) is a choice, which has no keyframes") }
            guard let pairs = call["keyframes"]?.array else { throw ScriptCallError.type("keyframes is a list of (time, value)") }
            let timeline = project.timeline(id: target.timelineID)
            let count = control.number.value.values.count
            let keyframes = try pairs.map { pair -> Keyframe<ComponentValue> in
                guard let parts = pair.array, parts.count == 2 else { throw ScriptCallError.type("A keyframe is a (time, value) pair") }
                return Keyframe(time: try ScriptTime.time(parts[0], in: timeline), value: try ScriptValue.components(parts[1], for: control.kind, count: count))
            }
            let held = control.number.value(at: target.clip.trimStart)
            project.editEffect(effectID, ofClip: target.clip.id, in: target.timelineID) { effect in
                if let c = effect.controlIndex(controlID) {
                    effect.controls[c].number = AnimatedValue(keyframes.first?.value ?? held, keyframes: keyframes)
                }
            }
            result = .null
        case "drive":
            let target = try self.target(call)
            let kind = try effectKind(call["method"]?.string)
            guard kind.isKeyframing else {
                throw ScriptCallError.value("\(kind.name) isn't a Keyframing method, such as wiggler, oscillator or beatKeys")
            }
            guard let id = project.setKeyframing(kind, driving: target.target, onClip: target.clip.id, in: target.timelineID) else {
                throw ScriptCallError.value("That control can't be driven by \(kind.name)")
            }
            let settings = call["settings"]?.object ?? [:]
            if !settings.isEmpty {
                guard let method = project.clipAndLayer(target.clip.id, in: target.timelineID)?.clip.effect(id: id) else {
                    throw ScriptCallError.gone("The method's effect went")
                }
                var edited = method
                for (name, value) in settings.sorted(by: { $0.key < $1.key }) {
                    guard let c = edited.controls.firstIndex(where: { $0.kind.rawValue == name || $0.kind.name == name }) else {
                        let names = edited.controls.map(\.kind.rawValue).joined(separator: ", ")
                        throw ScriptCallError.lookup("\(kind.name) has no setting \u{201C}\(name)\u{201D}: it has \(names)")
                    }
                    let controlKind = edited.controls[c].kind
                    if controlKind.isChoice {
                        guard let option = value.string, controlKind.choiceOptions.contains(where: { $0.id == option }) else {
                            throw ScriptCallError.value("\(controlKind.name) is one of \(Self.options(of: controlKind))")
                        }
                        edited.controls[c].choice = option
                    } else {
                        let count = edited.controls[c].number.value.values.count
                        edited.controls[c].number = AnimatedValue(try ScriptValue.components(value, for: controlKind, count: count))
                    }
                }
                project.editEffect(id, ofClip: target.clip.id, in: target.timelineID) { $0.controls = edited.controls }
            }
            result = JSONValue(id)
        case "bake":
            let target = try self.target(call)
            guard let driver = project.keyframingEffect(driving: target.target, in: target.clip) else {
                throw ScriptCallError.value("Nothing drives that control, so there is nothing to bake")
            }
            project.bakeKeyframing(driver.id, ofClip: target.clip.id, in: target.timelineID)
            result = .null

        // MARK: Assets
        case "set_asset_name":
            let asset = try self.asset(call)
            project.renameMedia(asset.id, to: try nonEmpty(call["name"]?.string, what: "An asset's name"))
            result = .null

        default:
            return nil
        }
        try commit(project)
        return result
    }

    /// An effect kind by the name it is saved under ("gaussianBlur") or
    /// shown under ("Gaussian Blur").
    private func effectKind(_ name: String?) throws -> EffectKind {
        guard let name else { throw ScriptCallError.type("An effect's kind is a name, such as \"gaussianBlur\"") }
        if let kind = EffectKind(rawValue: name), kind != .missing { return kind }
        let all = EffectKind.all + [.audioKeys, .beatKeys, .wiggler, .oscillator, .smoother, .looper, .timeStep, .overshoot]
        if let kind = all.first(where: { $0.name == name }) { return kind }
        throw ScriptCallError.lookup("There is no effect called \u{201C}\(name)\u{201D}")
    }

    private func nonEmpty(_ name: String?, what: String) throws -> String {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            throw ScriptCallError.value("\(what) can't be empty")
        }
        return trimmed
    }

    private static func options(of kind: ControlKind) -> String {
        kind.choiceOptions.map { "\"\($0.id)\"" }.joined(separator: ", ")
    }
}
