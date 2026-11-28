import CoreMedia
import Foundation

// Expressions (see docs/python-scripting.md, "Expressions in detail"): a
// Keyframing method whose signal is a few lines of Python. Like Audio
// Keys' sound, its samples arrive from elsewhere (the helper, through
// `ExpressionRunner`), into `ExpressionResults`; making keyframes stays
// here, synchronous and pure, from a result that fits the code, settings,
// base and reads as they are now. Nothing here runs Python.

/// Whether an expression's keyframes follow its samples smoothly, or hold
/// each value until it changes.
enum ExpressionKeys: String, CaseIterable, Identifiable, Sendable, ControlChoice {
    case smooth
    case stepped

    var id: Self { self }

    var name: String {
        switch self {
        case .smooth: "Smooth"
        case .stepped: "Stepped"
        }
    }
}

/// How many moments inside each frame an expression is also called at,
/// for Motion Blur to average values the code gave (see "Between frames").
enum BetweenFrames: String, CaseIterable, Identifiable, Sendable, ControlChoice {
    /// The clip's own shutter samples, up to 8, while it has Motion Blur.
    case auto
    case off
    case two = "2"
    case four = "4"
    case eight = "8"

    var id: Self { self }

    var name: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        case .two: "2"
        case .four: "4"
        case .eight: "8"
        }
    }
}

extension BetweenFrames {
    /// The most moments inside a frame an expression is called at: past
    /// them, motion blur's other moments read lines between these.
    static let mostMoments = 8

    /// The moments inside each frame an expression is also called at, in
    /// seconds from the frame. Auto follows the clip's own motion blur, at
    /// the compositor's own moments (`LayeredCompositor`): `n` of them
    /// across the shutter, open for `angle / 360` of the frame around the
    /// frame's time, at `shutter × ((i + 0.5) / n − 0.5)`, `n` up to 8; none
    /// without motion blur. 2, 4 and 8 spread that many over the whole
    /// frame, for readers Auto can't see (the blur on a clip nesting this
    /// timeline, Trails, a nesting timeline at a higher frame rate).
    func offsets(shutter: ClipShutter, frame: Double) -> [Double] {
        let count: Int
        var open = frame
        switch self {
        case .off:
            return []
        case .auto:
            guard let blur = shutter.motionBlur?.clamped, blur.samples > 1, blur.angle > 0 else { return [] }
            count = min(blur.samples, Self.mostMoments)
            open = frame * blur.angle / 360
        case .two: count = 2
        case .four: count = 4
        case .eight: count = 8
        }
        guard open > 0 else { return [] }
        return (0..<count).map { open * ((Double($0) + 0.5) / Double(count) - 0.5) }
    }
}

/// One thing an expression's last run read, in one timeline (any of the
/// project's): what puts it out of date when it changes.
struct KeyframingRead: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A control of a clip.
        case control(clip: UUID, effect: UUID, control: UUID)
        /// A clip's volume.
        case volume(clip: UUID)
        /// A clip's own properties: its place, trim, speed and name.
        case clip(UUID)
        /// A layer's own properties: its name and place.
        case layer(UUID)
        /// The timeline's size, frame rate and sections, and which layers
        /// it has.
        case settings
        /// Which layers the timeline has and what they are called: what a
        /// lookup by name depends on, found or not.
        case layerNames
        /// What `audio()` hears, as Audio Keys hears it.
        case heard(AudioKeysSource)
        /// A layer's beats.
        case beats(layer: UUID)
    }

    var timeline: UUID
    var kind: Kind
}

/// One run's answer for an expression: a value at each of its sample
/// times, or the error it raised.
struct ExpressionResult: Equatable, Sendable {
    /// The source time of each sample.
    var times: [CMTime]
    /// Each sample's `width` numbers, one after another.
    var values: [Double]
    var width: Int
    /// What the run read.
    var reads: [KeyframingRead]
    /// The exception, when the code raised: the control keeps the
    /// keyframes it had.
    var failure: ExpressionFailure?
    /// The fingerprint of what it was made from (`expressionPrint`), with
    /// `reads` as they were when it ran.
    var print: UInt64
    /// The fingerprint of `reads` alone as they were when it ran
    /// (`readsPrint`): while they are unchanged, the next run calls the
    /// code only for the samples whose rows changed.
    var readsPrint: UInt64 = 0
    /// What a run that worked was sent, for the next run of the same shape
    /// to start from: each run is a helper process of its own, which
    /// remembers nothing (code-review-notes.md, D9).
    var input: ExpressionInput?
}

/// The tables a run was sent, and what they must match for a later run to
/// reuse its samples.
struct ExpressionInput: Equatable, Sendable {
    struct Shape: Equatable, Sendable {
        /// What the samples depend on besides the code and the tables.
        var key: String
        var code: String
        var count: Int
        var width: Int
        /// Each table's name and numbers per sample, in the order sent.
        var tables: [String]
        var sizes: [Int]
    }

    var shape: Shape
    /// Every table, one after another, as `tables` lays them out.
    var tables: [Double]
}

/// An expression's error, as its note shows it.
struct ExpressionFailure: Equatable, Sendable {
    /// "Line 2: NameError: name 'tim' is not defined".
    var summary: String
    /// The moment it happened, in the timeline's seconds, when it isn't in
    /// every sample.
    var time: Double?
    /// Everything known about it, for the designer's Details: the whole
    /// traceback, or the app's own error.
    var details = ""
}

/// Expressions' results for the session, as `SpectrogramStore` keeps
/// spectrograms: several for each effect, so undo, redo and a value set
/// back to what it was find the result made before, and nothing runs.
final class ExpressionResults: @unchecked Sendable {
    static let shared = ExpressionResults()

    /// How many are kept for each effect; the oldest goes.
    static let keptPerEffect = 8

    private let lock = NSLock()
    private var results: [UUID: [ExpressionResult]] = [:]

    /// Keeps a result for an effect.
    func store(_ result: ExpressionResult, for effectID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var kept = results[effectID, default: []]
        kept.removeAll { $0.print == result.print }
        kept.append(result)
        if kept.count > Self.keptPerEffect { kept.removeFirst(kept.count - Self.keptPerEffect) }
        results[effectID] = kept
    }

    /// The effect's results, oldest first.
    func results(for effectID: UUID) -> [ExpressionResult] {
        lock.lock()
        defer { lock.unlock() }
        return results[effectID] ?? []
    }

    /// Forgets one effect's results. Only that effect's: the store is the
    /// app's one, shared by every test running at the same time, and
    /// clearing it all once took a result from under another test.
    func remove(for effectID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        results[effectID] = nil
    }
}

// MARK: - Fingerprints

extension EditingProject {
    /// The fingerprint of everything an expression's keyframes are made
    /// from: its code, inputs and settings, the clip's place, trim and
    /// speed, the frame rate, its range and component, the base it starts
    /// from, the clip's shutter, and each of `reads` as it is now.
    func expressionPrint(
        of effect: Effect, in clip: TimelineClip, of timeline: Timeline, base: AnimatedValue<ComponentValue>?, reads: [KeyframingRead]
    ) -> UInt64 {
        var fingerprint = KeyframingPrint()
        fingerprint.add(effect.expression ?? "")
        for control in effect.controls {
            fingerprint.add(control.kind.rawValue)
            fingerprint.add(control.choice)
            fingerprint.add(control.number) { $0.values }
        }
        for time in [clip.startOffset, clip.trimStart, clip.trimEnd, timeline.frameDuration] { fingerprint.add(time) }
        fingerprint.add(clip.time.speed)
        let setup = effect.keyframing
        if let range = setup?.range {
            fingerprint.add(range.start)
            fingerprint.add(range.end)
        }
        fingerprint.add(UInt64(bitPattern: Int64(setup?.component ?? -1)))
        // What `audio()` listens to and whose beats `beats` follows.
        switch setup?.audioSource {
        case nil: fingerprint.add(UInt64(0))
        case .mix?: fingerprint.add(UInt64(1))
        case .layer(let id)?:
            fingerprint.add(UInt64(2))
            fingerprint.add(id)
        case .clip(let id)?:
            fingerprint.add(UInt64(3))
            fingerprint.add(id)
        }
        fingerprint.add(setup?.beatLayer)
        if let base { fingerprint.add(base) { $0.values } } else { fingerprint.add(UInt64(0)) }
        if effect.choice(.betweenFrames, as: BetweenFrames.self) ?? .auto == .auto {
            // Its shutter's moments are called too (see "Between frames").
            fingerprint.add(clip.shutter.motionBlur?.angle ?? -1)
            fingerprint.add(Double(clip.shutter.motionBlur?.samples ?? 0))
        }
        addReads(reads, to: &fingerprint)
        return fingerprint.value
    }

    /// Each read as it is now, by the table in "What it reads, and going
    /// out of date".
    func addReads(_ reads: [KeyframingRead], to fingerprint: inout KeyframingPrint) {
        for read in reads {
            fingerprint.add(read.timeline)
            guard let timeline = timeline(id: read.timeline) else {
                fingerprint.add(UInt64(1))
                continue
            }
            switch read.kind {
            case .control(let clipID, let effectID, let controlID):
                fingerprint.add(UInt64(2))
                guard let clip = clipAndLayer(clipID, in: timeline.id)?.clip else { fingerprint.add(UInt64(3)); continue }
                // Read on its own clip's clock, which its place maps.
                for time in [clip.startOffset, clip.trimStart, clip.trimEnd] { fingerprint.add(time) }
                fingerprint.add(clip.time.speed)
                if let control = clip.effect(id: effectID)?.controls.first(id: controlID) {
                    fingerprint.add(control.number) { $0.values }
                } else {
                    fingerprint.add(UInt64(3))
                }
            case .volume(let clipID):
                fingerprint.add(UInt64(4))
                if let clip = clipAndLayer(clipID, in: timeline.id)?.clip { fingerprint.add(clip.volume) } else { fingerprint.add(UInt64(3)) }
            case .clip(let clipID):
                fingerprint.add(UInt64(5))
                guard let clip = clipAndLayer(clipID, in: timeline.id)?.clip else { fingerprint.add(UInt64(3)); continue }
                for time in [clip.startOffset, clip.trimStart, clip.trimEnd] { fingerprint.add(time) }
                fingerprint.add(clip.time.speed)
                fingerprint.add(clipName(clipID, in: timeline.id))
            case .layer(let layerID):
                fingerprint.add(UInt64(6))
                guard let index = timeline.layers.firstIndex(id: layerID) else { fingerprint.add(UInt64(3)); continue }
                fingerprint.add(UInt64(index))
                fingerprint.add(displayName(of: timeline.layers[index], in: timeline))
            case .settings:
                fingerprint.add(UInt64(7))
                fingerprint.add(timeline.frameSize.width)
                fingerprint.add(timeline.frameSize.height)
                fingerprint.add(timeline.frameRate)
                for section in timeline.sections {
                    fingerprint.add(section.name)
                    fingerprint.add(section.start)
                    fingerprint.add(section.end)
                }
                for layer in timeline.layers { fingerprint.add(layer.id) }
            case .layerNames:
                fingerprint.add(UInt64(8))
                for layer in timeline.layers {
                    fingerprint.add(layer.id)
                    fingerprint.add(displayName(of: layer, in: timeline))
                }
            case .heard(let source):
                fingerprint.add(UInt64(9))
                addHeard(source, in: timeline, to: &fingerprint)
            case .beats(let layerID):
                fingerprint.add(UInt64(10))
                if let layer = timeline.layer(id: layerID) {
                    for beat in beatMarkers(in: layer, tracks: DetectedBeats.shared.tracks) {
                        fingerprint.add(beat.time)
                        fingerprint.add(UInt64(beat.position ?? 0))
                    }
                }
            }
        }
    }

    /// The fingerprint of `reads` alone, as they are now.
    func readsPrint(_ reads: [KeyframingRead]) -> UInt64 {
        var fingerprint = KeyframingPrint()
        addReads(reads, to: &fingerprint)
        return fingerprint.value
    }

    /// The result in `ExpressionResults` that fits the expression as it is
    /// now, if there is one: made from this code, these settings and base,
    /// with what it read unchanged since.
    func fittingExpressionResult(
        of effect: Effect, in clip: TimelineClip, of timeline: Timeline, base: AnimatedValue<ComponentValue>?
    ) -> ExpressionResult? {
        ExpressionResults.shared.results(for: effect.id).last { result in
            result.print == expressionPrint(of: effect, in: clip, of: timeline, base: base, reads: result.reads)
        }
    }
}

// MARK: - Readers and loops

extension EditingProject {
    /// The timelines holding expressions that read `timelineIDs` (other
    /// than those timelines themselves), so an edit there reaches them.
    func expressionReaders(of timelineIDs: Set<UUID>) -> Set<UUID> {
        var readers: Set<UUID> = []
        for timeline in timelines where !timelineIDs.contains(timeline.id) {
            let reads = timeline.layers.contains { layer in
                layer.clips.contains { clip in
                    clip.hasKeyframingEffect && clip.effects.contains { effect in
                        effect.kind == .expression && (effect.keyframing?.reads ?? []).contains { timelineIDs.contains($0.timeline) }
                    }
                }
            }
            if reads { readers.insert(timeline.id) }
        }
        return readers
    }

    /// A control, wherever it is in the project.
    struct ControlAddress: Hashable, Sendable {
        var timeline: UUID
        var clip: UUID
        var effect: UUID
        var control: UUID
    }

    /// The expressions that read their own targets back, directly or
    /// through others, in whichever timelines, found from the saved reads:
    /// each, by effect ID, with the target of the next expression around
    /// the loop, for its note. They write nothing.
    func expressionCycles() -> [UUID: ControlAddress] {
        // Each expression: what it drives, and the controls it read.
        var drives: [ControlAddress: (effect: UUID, reads: [ControlAddress])] = [:]
        for timeline in timelines {
            for layer in timeline.layers {
                for clip in layer.clips where clip.hasKeyframingEffect {
                    for effect in clip.effects where effect.kind == .expression && effect.enabled {
                        guard case .control(let effectID, let controlID)? = effect.keyframing?.target else { continue }
                        let target = ControlAddress(timeline: timeline.id, clip: clip.id, effect: effectID, control: controlID)
                        let reads = (effect.keyframing?.reads ?? []).compactMap { read -> ControlAddress? in
                            guard case .control(let c, let e, let k) = read.kind else { return nil }
                            let address = ControlAddress(timeline: read.timeline, clip: c, effect: e, control: k)
                            // Reading its own target gives the base, not a loop.
                            return address == target ? nil : address
                        }
                        drives[target] = (effect.id, reads)
                    }
                }
            }
        }
        var cycles: [UUID: ControlAddress] = [:]
        // A depth-first walk from each driven control along what its
        // expression reads, through the controls other expressions drive.
        for start in drives.keys {
            var path: [ControlAddress] = []
            var onPath: Set<ControlAddress> = []
            var visited: Set<ControlAddress> = []
            func walk(_ node: ControlAddress) -> Bool {
                if onPath.contains(node) {
                    return node == start
                }
                guard !visited.contains(node), let driver = drives[node] else { return false }
                visited.insert(node)
                onPath.insert(node)
                path.append(node)
                for next in driver.reads where walk(next) {
                    return true
                }
                path.removeLast()
                onPath.remove(node)
                return false
            }
            if walk(start), let effect = drives[start]?.effect, path.count >= 1 {
                cycles[effect] = path.count > 1 ? path[1] : start
            }
        }
        return cycles
    }

    /// Whether an expression waits for a run: it is on and can write, isn't
    /// in a loop, and what it is made from changed since it last wrote (or
    /// it never has), with no result in the store that fits.
    func expressionIsWaiting(_ effect: Effect, in clip: TimelineClip, of timeline: Timeline) -> Bool {
        guard effect.kind == .expression, effect.enabled, let setup = effect.keyframing, setup.target != nil,
              Self.expressionIsAllowed(effect),
              keyframingTargetIsReachable(effect, in: clip), expressionCycles()[effect.id] == nil
        else { return false }
        let base = setup.base ?? setup.target.flatMap { clip.number(of: $0) }.map { Self.removingKeyframes(of: effect.id, from: $0) }
        let print = expressionPrint(of: effect, in: clip, of: timeline, base: base, reads: setup.reads)
        guard setup.readPrint != print else { return false }
        return fittingExpressionResult(of: effect, in: clip, of: timeline, base: base) == nil
    }

    /// Every expression waiting for a run, with its clip and timeline.
    func waitingExpressions() -> [(timelineID: UUID, clipID: UUID, effectID: UUID)] {
        var waiting: [(UUID, UUID, UUID)] = []
        for timeline in timelines {
            for layer in timeline.layers {
                for clip in layer.clips where clip.hasKeyframingEffect {
                    for effect in clip.effects where expressionIsWaiting(effect, in: clip, of: timeline) {
                        waiting.append((timeline.id, clip.id, effect.id))
                    }
                }
            }
        }
        return waiting
    }

    /// What an export started now would miss, since it isn't written yet:
    /// expressions waiting for a run, and Keyframing effects out of date
    /// that will be made again; nil when everything is written. An export
    /// takes the project as it is when it starts, so it would have their
    /// values from before while the viewer goes on to show the new ones
    /// (F107). Effects out of date with hand edits wait for the person, and
    /// the viewer shows what the export would.
    func keyframesStillComing() -> String? {
        let waiting = Set(waitingExpressions().map(\.effectID))
        var stale = Set<UUID>()
        for timeline in timelines {
            for layer in timeline.layers {
                for clip in layer.clips where clip.hasKeyframingEffect {
                    for effect in clip.effects where !waiting.contains(effect.id)
                        && keyframingFreshness(of: effect, in: clip, of: timeline) == .outOfDate {
                        stale.insert(effect.id)
                    }
                }
            }
        }
        var parts: [String] = []
        if !waiting.isEmpty {
            parts.append(waiting.count == 1 ? "an expression is still running" : "\(waiting.count) expressions are still running")
        }
        if !stale.isEmpty {
            parts.append(stale.count == 1 ? "a Keyframing effect is still being made again" : "\(stale.count) Keyframing effects are still being made again")
        }
        guard let first = parts.first else { return nil }
        let sentence = ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: ", and ")
        return sentence + ". An export now would have the values from before them. Wait until they finish, or export anyway."
    }

    /// Whether this Mac allows an expression's code to run (see
    /// docs/python-scripting.md, "Safety"). One that isn't plays exactly
    /// as saved: its keyframes are in the project. It just isn't run again.
    static func expressionIsAllowed(_ effect: Effect) -> Bool {
        CodeApproval.allowsCode(effect.expression ?? "")
    }

    /// Every expression in the project, for Review Expressions… and Allow
    /// All in This Project.
    func expressions() -> [(timelineID: UUID, clipID: UUID, effect: Effect)] {
        var found: [(UUID, UUID, Effect)] = []
        for timeline in timelines {
            for layer in timeline.layers {
                for clip in layer.clips where clip.hasKeyframingEffect {
                    for effect in clip.effects where effect.kind == .expression { found.append((timeline.id, clip.id, effect)) }
                }
            }
        }
        return found
    }

    /// What an expression's note says, if anything: that it isn't allowed
    /// yet, its loop, its error, or that it is running.
    func expressionNote(for effect: Effect, in clip: TimelineClip, of timeline: Timeline) -> EffectNote? {
        if !Self.expressionIsAllowed(effect) {
            return EffectNote(text: "Expression not allowed yet: its code came from somewhere else, so it plays as saved and doesn't run until you allow it.", dims: true)
        }
        if let next = expressionCycles()[effect.id] {
            let name = clipAndLayer(next.clip, in: next.timeline).map { self.name(of: .control(effectID: next.effect, controlID: next.control), in: $0.clip) } ?? "a control"
            return EffectNote(text: "It reads \(name), whose expression reads it back, so it writes nothing.", dims: true)
        }
        let setup = effect.keyframing
        let base = setup?.base ?? setup?.target.flatMap { clip.number(of: $0) }.map { Self.removingKeyframes(of: effect.id, from: $0) }
        if let result = fittingExpressionResult(of: effect, in: clip, of: timeline, base: base), let failure = result.failure {
            let when = failure.time.map { String(format: " (at %.2f s)", $0) } ?? ""
            return EffectNote(text: "Expression has an error. " + failure.summary + when, dims: true)
        }
        if expressionIsWaiting(effect, in: clip, of: timeline) {
            return EffectNote(text: "Running\u{2026}", dims: false)
        }
        return nil
    }
}

// MARK: - Making keyframes

extension Notification.Name {
    /// A result was put in `ExpressionResults`; the editor makes the
    /// keyframes of the expressions it fits, as when analysis arrives.
    static let expressionResultsChanged = Notification.Name("expressionResultsChanged")
}

extension EditingProject {
    /// Makes the keyframes of every expression whose result has landed
    /// since it last wrote. Not an edit: the code was the edit, and the
    /// result arriving is like analysis arriving. Returns whether
    /// anything changed.
    @discardableResult
    mutating func applyExpressionResults() -> Bool {
        var changed = false
        for timelineID in timelines.map(\.id) {
            guard let timeline = timeline(id: timelineID) else { continue }
            for layer in timeline.layers {
                for clip in layer.clips where clip.hasKeyframingEffect {
                    for effect in clip.effects where effect.kind == .expression && effect.enabled {
                        guard let setup = effect.keyframing, let target = setup.target, let current = clip.number(of: target) else { continue }
                        let base = setup.base ?? Self.removingKeyframes(of: effect.id, from: current)
                        guard let result = fittingExpressionResult(of: effect, in: clip, of: timeline, base: base),
                              result.print != setup.readPrint
                        else { continue }
                        changed = regenerateKeyframes(ofEffect: effect.id, onClip: clip.id, in: timelineID) || changed
                    }
                }
            }
        }
        return changed
    }

    /// Makes an expression's keyframes from the result that fits, if one
    /// does; otherwise leaves the control as it is, waiting for a run.
    /// Returns whether anything changed. Called by `regenerateKeyframes`.
    mutating func regenerateExpression(
        _ effect: Effect, setup: KeyframingSetup, base: AnimatedValue<ComponentValue>, target: KeyframingTarget,
        clip: TimelineClip, timeline: Timeline, current: AnimatedValue<ComponentValue>
    ) -> Bool {
        var setup = setup
        let effectID = effect.id
        // In a loop it writes nothing, and keeps the keyframes it had.
        guard expressionCycles()[effectID] == nil,
              let result = fittingExpressionResult(of: effect, in: clip, of: timeline, base: base)
        else {
            // The base is kept, so a result made from it fits when it lands.
            guard setup != effect.keyframing else { return false }
            editClip(clip.id, in: timeline.id) { clip in
                if let index = clip.effects.index(of: effectID) { clip.effects[index].keyframing = setup }
            }
            return true
        }
        setup.reads = result.reads
        setup.readPrint = result.print
        let written = result.failure == nil
            ? Self.writtenFromExpression(result, effect: effect, setup: setup, base: base, target: target, clip: clip, timeline: timeline)
            : current
        setup.writtenPrint = Self.fingerprint(of: written)
        guard written != current || setup != effect.keyframing else { return false }
        editClip(clip.id, in: timeline.id) { clip in
            clip.setNumber(written, of: target)
            if let index = clip.effects.index(of: effectID) { clip.effects[index].keyframing = setup }
        }
        return true
    }

    /// The target's new numbers from a result: `base` outside the effect's
    /// range, and the result's samples inside, clamped to the control's
    /// limits and thinned to Tolerance, or with Stepped a held keyframe at
    /// each side of every jump.
    static func writtenFromExpression(
        _ result: ExpressionResult, effect: Effect, setup: KeyframingSetup, base: AnimatedValue<ComponentValue>,
        target: KeyframingTarget, clip: TimelineClip, timeline: Timeline
    ) -> AnimatedValue<ComponentValue> {
        let range = writtenRange(setup, of: clip)
        let count = result.times.count
        guard range.duration > .zero, count > 0, result.width > 0, result.values.count == count * result.width else { return base }
        let (baseSamples, width) = base.flatValues(at: result.times)
        guard width > 0 else { return base }
        let components = setup.component.map { (0..<width).contains($0) ? [$0] : [] } ?? Array(0..<width)
        let clamp = clip.clamp(for: target)
        var samples = baseSamples
        for k in 0..<count {
            for (n, c) in components.enumerated() {
                // A single number for a vector sets every component.
                let made = result.values[k * result.width + (result.width == 1 ? 0 : min(n, result.width - 1))]
                samples[k * width + c] = clamp(made, c)
            }
        }
        func value(at k: Int) -> ComponentValue { ComponentValue(values: Array(samples[(k * width)..<((k + 1) * width)])) }
        let kept: [Int]
        if effect.choice(.expressionKeys, as: ExpressionKeys.self) == .stepped {
            kept = KeyframeGenerators.steps(samples, components: width)
        } else {
            let percent = effect.control(.tolerance)?.number.value.values.first ?? 0.5
            let tolerance = KeyframeGenerators.tolerances(samples, components: width, percent: percent)
            kept = KeyframeGenerators.reduced(times: result.times.map(\.seconds), samples: samples, tolerance: tolerance)
        }
        var keyframes = kept.map { Keyframe(time: result.times[$0], value: value(at: $0), generatedBy: effect.id) }
        // Outside the range the target keeps its own keyframes, or its value
        // from a frame past each end, as every method's do.
        keyframes += base.keyframes.filter { !range.containsTime($0.time) && $0.time != range.end }
        if !base.isAnimated {
            let whole = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
            let sampling = KeyframeSampling(clip: clip, range: range, frame: timeline.frameDuration)
            for edge in [sampling.before, sampling.after].compactMap({ $0 }) where whole.containsTime(edge) || edge == whole.end {
                keyframes.append(Keyframe(time: edge, value: base.value, generatedBy: effect.id))
            }
        }
        return AnimatedValue(base.value, keyframes: keyframes)
    }
}
