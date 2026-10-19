import CoreMedia
import Foundation

// Keyframing effects (see docs/keyframing-effects.md) draw nothing: each
// writes ordinary keyframes onto a control below it in the stack, or onto
// the clip's volume or a sound effect's control, and keeps its settings so
// the keyframes can be made again. The keyframes it wrote carry its ID
// (`Keyframe.generatedBy`), so making them again replaces only its own.

/// Which beats Beat Keys follows.
enum BeatSelection: String, CaseIterable, Identifiable, Sendable {
    case every
    case downbeats

    var id: Self { self }

    var name: String {
        switch self {
        case .every: "Every Beat"
        case .downbeats: "Downbeats Only"
        }
    }
}

/// What Beat Keys does on each beat.
enum BeatShape: String, CaseIterable, Identifiable, Sendable {
    /// Up at the beat, back over the decay.
    case pulse
    /// Climbs by the peak at each beat.
    case step
    /// Rises from nothing at a beat to the peak at the next.
    case ramp
    /// Up at one beat, back down at the next.
    case alternate

    var id: Self { self }

    var name: String {
        switch self {
        case .pulse: "Pulse"
        case .step: "Step"
        case .ramp: "Ramp"
        case .alternate: "Alternate"
        }
    }
}

enum WiggleType: String, CaseIterable, Identifiable, Sendable {
    /// Perlin noise: curves that never change direction abruptly.
    case smooth
    /// Straight lines between random values.
    case jagged

    var id: Self { self }

    var name: String {
        switch self {
        case .smooth: "Smooth"
        case .jagged: "Jagged"
        }
    }
}

/// Whether a Wiggler moves each component of its target on its own.
enum WiggleDimensions: String, CaseIterable, Identifiable, Sendable {
    case independent
    case together

    var id: Self { self }

    var name: String {
        switch self {
        case .independent: "Independent"
        case .together: "Together"
        }
    }
}

enum OscillatorWave: String, CaseIterable, Identifiable, Sendable {
    case sine, triangle, square, sawtooth

    var id: Self { self }

    var name: String {
        switch self {
        case .sine: "Sine"
        case .triangle: "Triangle"
        case .square: "Square"
        case .sawtooth: "Sawtooth"
        }
    }
}

/// How Looper carries the target's keyframes on.
enum LoopMode: String, CaseIterable, Identifiable, Sendable {
    /// From the first keyframe again.
    case cycle
    /// Backward, then forward again.
    case pingPong
    /// Each cycle starts where the last ended.
    case offset
    /// On at the speed it was going.
    case `continue`

    var id: Self { self }

    var name: String {
        switch self {
        case .cycle: "Cycle"
        case .pingPong: "Ping-Pong"
        case .offset: "Offset"
        case .continue: "Continue"
        }
    }
}

/// Which way Looper repeats the keyframes.
enum LoopSide: String, CaseIterable, Identifiable, Sendable {
    case after
    case before
    case both

    var id: Self { self }

    var name: String {
        switch self {
        case .after: "After the Last"
        case .before: "Before the First"
        case .both: "Both Ways"
        }
    }
}

/// What a Keyframing effect writes to: a numeric control of an effect
/// below it, or of one of the clip's sound effects, or the clip's volume.
enum KeyframingTarget: Hashable, Sendable {
    case control(effectID: UUID, controlID: UUID)
    case volume
}

/// How a generated signal meets the target's own value.
enum KeyframingCombine: String, CaseIterable, Identifiable, Sendable {
    /// The target takes the generated value.
    case replace
    /// The generated value is added to the target's.
    case add
    /// The target's value is scaled by the generated one, as a percent
    /// more or less: 30 makes it 130%.
    case multiply

    var id: Self { self }

    var name: String {
        switch self {
        case .replace: "Replace"
        case .add: "Add"
        case .multiply: "Multiply"
        }
    }
}

/// What a Keyframing effect writes to, and how.
struct KeyframingSetup: Equatable, Sendable {
    /// Changing it lets go of the base, which belonged to the old target.
    var target: KeyframingTarget? {
        didSet { if target != oldValue { base = nil } }
    }
    /// The one component it drives (x of a Position, say), or nil for all.
    var component: Int?
    var combine = KeyframingCombine.add
    /// The span it writes to, in the clip's source time; nil is the whole
    /// clip. Keyframes outside it are kept.
    var range: CMTimeRange?
    /// The target as it was before this effect first wrote to it, so making
    /// the keyframes again adds to the original rather than to the last
    /// result. Nil until it has written.
    var base: AnimatedValue<ComponentValue>?
    /// Beat Keys: the layer whose beat map it follows.
    var beatLayer: UUID?
    /// A fingerprint of what it read when it last wrote (the clip's place,
    /// trim and speed, the frame rate, the beats), so a change to any of
    /// them shows it is out of date. Nil until it has written.
    var readPrint: UInt64?
    /// A fingerprint of the target as it left it, so an edit by hand since
    /// shows.
    var writtenPrint: UInt64?
}

/// Whether a Keyframing effect's keyframes still match what it reads.
enum KeyframingFreshness: Equatable {
    case current
    /// What it reads changed; making its keyframes again loses nothing.
    case outOfDate
    /// What it reads changed and its keyframes were edited by hand since,
    /// so the person decides: Regenerate or Keep Edits.
    case outOfDateWithEdits
}

/// A stable 64-bit fingerprint (FNV-1a), the same on every Mac and in
/// every run, unlike `Hasher`, since it is saved.
struct KeyframingPrint {
    private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func add(_ bits: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            value ^= (bits >> UInt64(shift)) & 0xFF
            value &*= 0x0000_0100_0000_01B3
        }
    }

    mutating func add(_ number: Double) { add(number.bitPattern) }
    mutating func add(_ time: CMTime) { add(time.seconds) }

    mutating func add(_ id: UUID?) {
        guard let id else { return add(UInt64(0)) }
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes { add(UInt64(byte)) }
        }
    }

    mutating func add<Value: Interpolatable>(_ animated: AnimatedValue<Value>, components: (Value) -> [Double]) {
        components(animated.value).forEach { add($0) }
        add(UInt64(animated.keyframes.count))
        for keyframe in animated.keyframes {
            add(keyframe.time)
            components(keyframe.value).forEach { add($0) }
            for ease in [keyframe.easeIn, keyframe.easeOut] {
                add(ease?.influence ?? -1)
                add(ease?.speed ?? -1)
            }
            add(keyframe.generatedBy)
        }
    }
}

// MARK: - Targets

extension TimelineClip {
    /// The numbers of a target, as components.
    func number(of target: KeyframingTarget) -> AnimatedValue<ComponentValue>? {
        switch target {
        case .volume: return volume.asComponents
        case .control(let effectID, let controlID):
            return effect(id: effectID)?.controls.first { $0.id == controlID }.map(\.number)
        }
    }

    /// Replaces a target's numbers.
    mutating func setNumber(_ number: AnimatedValue<ComponentValue>, of target: KeyframingTarget) {
        switch target {
        case .volume: volume = AnimatedValue(components: number)
        case .control(let effectID, let controlID):
            guard let stack = stack(holding: effectID), let e = self[keyPath: stack].index(of: effectID),
                  let c = self[keyPath: stack][e].controlIndex(controlID)
            else { return }
            self[keyPath: stack][e].controls[c].number = number
        }
    }

    /// A component limited to what the target allows.
    func clamped(_ component: Double, index: Int, of target: KeyframingTarget) -> Double {
        switch target {
        case .volume: return AudioLevel.clamped(component)
        case .control(let effectID, let controlID):
            guard let control = effect(id: effectID)?.controls.first(where: { $0.id == controlID }) else { return component }
            return control.kind.clamped(component, index: index)
        }
    }
}

extension EditingProject {
    /// What the Keyframing effect at `index` of a clip's stack can write
    /// to: each numeric control of the effects below it (not other
    /// Keyframing effects), then the clip's sound effects' and its volume,
    /// when it plays sound.
    func keyframingTargets(forEffectAt index: Int, in clip: TimelineClip) -> [KeyframingTarget] {
        func numeric(_ effects: ArraySlice<Effect>) -> [KeyframingTarget] {
            effects.filter { !$0.kind.isKeyframing }.flatMap { effect in
                effect.controls.filter { !$0.kind.isChoice }.map { KeyframingTarget.control(effectID: effect.id, controlID: $0.id) }
            }
        }
        var targets = numeric(clip.effects.dropFirst(index + 1))
        if playsAudio(clip) {
            targets += numeric(clip.audioEffects[...])
            targets.append(.volume)
        }
        return targets
    }

    /// Whether a Keyframing effect can write to its target: the target is
    /// still there and below it.
    func keyframingTargetIsReachable(_ effect: Effect, in clip: TimelineClip) -> Bool {
        guard let target = effect.keyframing?.target, let index = clip.effects.index(of: effect.id) else { return false }
        return keyframingTargets(forEffectAt: index, in: clip).contains(target)
    }

    /// What a target is called in the effects panel: "Transform · Position"
    /// or "Volume".
    func name(of target: KeyframingTarget, in clip: TimelineClip) -> String {
        switch target {
        case .volume: return "Volume"
        case .control(let effectID, let controlID):
            guard let effect = clip.effect(id: effectID), let control = effect.controls.first(where: { $0.id == controlID })
            else { return "Unavailable" }
            return "\(effect.displayName) · \(control.kind.name)"
        }
    }
}

// MARK: - Reading

extension EditingProject {
    /// Why a Keyframing effect writes nothing, if it doesn't. It is dimmed
    /// then, and what it wrote stays.
    func keyframingNote(for effect: Effect, in clip: TimelineClip) -> EffectNote? {
        guard let setup = effect.keyframing, setup.target != nil else {
            return EffectNote(text: "Choose a control below it to write keyframes to.", dims: true)
        }
        if !keyframingTargetIsReachable(effect, in: clip) {
            return EffectNote(text: "The control it writes to is gone or above it, so its keyframes stay as they are until it is pointed elsewhere.", dims: true)
        }
        if effect.kind == .beatKeys, setup.beatLayer == nil {
            return EffectNote(text: "Choose a Sound or Music layer whose beat map it follows.", dims: true)
        }
        if effect.kind.reshapesTarget, setup.base.map({ $0.keyframes.count < 2 }) ?? false {
            return EffectNote(text: "It reshapes the keyframes of the control it writes to, which has fewer than two.", dims: true)
        }
        return nil
    }

    /// How many keyframes a Keyframing effect has on its target.
    func generatedKeyframeCount(of effect: Effect, in clip: TimelineClip) -> Int {
        guard let target = effect.keyframing?.target, let number = clip.number(of: target) else { return 0 }
        return number.keyframes.filter { $0.generatedBy == effect.id }.count
    }

    /// What VoiceOver reads for a Keyframing effect: "Wiggler, driving
    /// Transform · Position, 48 keyframes".
    func keyframingSummary(of effect: Effect, in clip: TimelineClip) -> String {
        guard let target = effect.keyframing?.target else { return "\(effect.displayName), driving nothing" }
        let count = generatedKeyframeCount(of: effect, in: clip)
        return "\(effect.displayName), driving \(name(of: target, in: clip)), \(count) keyframe\(count == 1 ? "" : "s")"
    }
}

extension KeyframingSetup {
    /// Moves one end of the range to source time `time`, keeping the other
    /// (the clip's own while there is no range). Refused where it would
    /// leave nothing between them.
    mutating func setRange(start: CMTime? = nil, end: CMTime? = nil, in clip: TimelineClip) {
        let current = range ?? CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
        let new = CMTimeRange(start: start ?? current.start, end: end ?? current.end)
        guard new.end > new.start else { return }
        range = new == CMTimeRange(start: clip.trimStart, end: clip.trimEnd) ? nil : new
    }
}

// MARK: - Making keyframes

extension EditingProject {
    /// The fingerprint of what a Keyframing effect reads, as things are.
    func keyframingReadPrint(of effect: Effect, in clip: TimelineClip, of timeline: Timeline) -> UInt64 {
        var fingerprint = KeyframingPrint()
        for time in [clip.startOffset, clip.trimStart, clip.trimEnd, timeline.frameDuration] { fingerprint.add(time) }
        fingerprint.add(clip.time.speed) { [$0] }
        if let range = effect.keyframing?.range {
            fingerprint.add(range.start)
            fingerprint.add(range.end)
        }
        if effect.kind == .beatKeys, let layer = effect.keyframing?.beatLayer.flatMap({ timeline.layer(id: $0) }) {
            for beat in beatMarkers(in: layer, tracks: [:]) {
                fingerprint.add(beat.time)
                fingerprint.add(UInt64(beat.position ?? 0))
            }
        }
        return fingerprint.value
    }

    /// Whether a Keyframing effect's keyframes match what it reads now.
    /// One that is off, can't reach its target or hasn't written is
    /// current: there is nothing to make again.
    func keyframingFreshness(of effect: Effect, in clip: TimelineClip, of timeline: Timeline) -> KeyframingFreshness {
        guard effect.enabled, let setup = effect.keyframing, let read = setup.readPrint, let target = setup.target,
              keyframingTargetIsReachable(effect, in: clip), let number = clip.number(of: target),
              read != keyframingReadPrint(of: effect, in: clip, of: timeline)
        else { return .current }
        return Self.fingerprint(of: number) == setup.writtenPrint ? .outOfDate : .outOfDateWithEdits
    }

    static func fingerprint(of number: AnimatedValue<ComponentValue>) -> UInt64 {
        var fingerprint = KeyframingPrint()
        fingerprint.add(number) { $0.values }
        return fingerprint.value
    }

    /// Makes the keyframes of every Keyframing effect that is out of date
    /// again, leaving those with hand edits for the person to decide.
    /// Returns whether anything changed. Run after each edit, so the new
    /// keyframes are part of the same undo step.
    @discardableResult
    mutating func refreshKeyframing() -> Bool {
        let before = self
        for timeline in timelines {
            for layer in timeline.layers {
                for clip in layer.clips {
                    for effect in clip.effects where effect.kind.isKeyframing
                        && keyframingFreshness(of: effect, in: clip, of: timeline) == .outOfDate {
                        regenerateKeyframes(ofEffect: effect.id, onClip: clip.id, in: timeline.id)
                    }
                }
            }
        }
        return self != before
    }

    /// Keeps a Keyframing effect's hand-edited keyframes, taking what it
    /// reads now as what they were made from. It asks again when what it
    /// reads next changes.
    mutating func keepKeyframingEdits(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID) {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip, let timeline = timeline(id: timelineID),
              let effect = clip.effect(id: effectID)
        else { return }
        let read = keyframingReadPrint(of: effect, in: clip, of: timeline)
        editClip(clipID, in: timelineID) { clip in
            if let index = clip.effects.index(of: effectID) { clip.effects[index].keyframing?.readPrint = read }
        }
    }

    /// Makes the keyframes of the Keyframing effect `effectID` again from
    /// its settings, replacing those it wrote before. Does nothing while it
    /// is off or its target can't be reached, leaving what it wrote.
    mutating func regenerateKeyframes(ofEffect effectID: UUID, onClip clipID: UUID, in timelineID: UUID) {
        guard let (clip, _) = clipAndLayer(clipID, in: timelineID), let timeline = timeline(id: timelineID),
              let effect = clip.effects.first(where: { $0.id == effectID }), effect.enabled,
              var setup = effect.keyframing, let target = setup.target,
              keyframingTargetIsReachable(effect, in: clip), let current = clip.number(of: target)
        else { return }
        let base = setup.base ?? Self.removingKeyframes(of: effectID, from: current)
        setup.base = base
        setup.readPrint = keyframingReadPrint(of: effect, in: clip, of: timeline)
        let written = Self.generated(
            effect, setup: setup, base: base, target: target, clip: clip, timeline: timeline,
            beats: setup.beatLayer.flatMap { layerID in timeline.layer(id: layerID).map { beatMarkers(in: $0, tracks: [:]) } } ?? []
        )
        setup.writtenPrint = Self.fingerprint(of: written)
        editClip(clipID, in: timelineID) { clip in
            clip.setNumber(written, of: target)
            if let index = clip.effects.index(of: effectID) { clip.effects[index].keyframing = setup }
        }
    }

    /// Puts a Keyframing effect's target back as it was before the effect
    /// wrote to it, for when the effect is deleted.
    mutating func restoreKeyframingBase(ofEffect effectID: UUID, onClip clipID: UUID, in timelineID: UUID) {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip, let effect = clip.effect(id: effectID),
              let target = effect.keyframing?.target, let base = effect.keyframing?.base, clip.number(of: target) != nil
        else { return }
        editClip(clipID, in: timelineID) { $0.setNumber(base, of: target) }
    }

    /// Removes a Keyframing effect, leaving the keyframes it wrote as
    /// plain keyframes.
    mutating func bakeKeyframing(_ effectID: UUID, ofClip clipID: UUID, in timelineID: UUID) {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip, let effect = clip.effect(id: effectID) else { return }
        editClip(clipID, in: timelineID) { clip in
            if let target = effect.keyframing?.target { clip.releaseKeyframes(of: effectID, on: target) }
            clip.effects.removeAll { $0.id == effectID }
        }
    }

    /// `number` without the keyframes `effectID` wrote; the value it holds
    /// where there are none left is what was showing at the first of them.
    static func removingKeyframes(of effectID: UUID, from number: AnimatedValue<ComponentValue>) -> AnimatedValue<ComponentValue> {
        let kept = number.keyframes.filter { $0.generatedBy != effectID }
        guard kept.count != number.keyframes.count else { return number }
        return AnimatedValue(kept.first?.value ?? number.keyframes.first?.value ?? number.value, keyframes: kept)
    }

    /// The target's new numbers: `base` outside the effect's range, and
    /// what it makes inside, reduced to the keyframes the curve needs.
    private static func generated(
        _ effect: Effect, setup: KeyframingSetup, base: AnimatedValue<ComponentValue>, target: KeyframingTarget,
        clip: TimelineClip, timeline: Timeline, beats: [BeatMarker]
    ) -> AnimatedValue<ComponentValue> {
        let whole = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
        let range = setup.range.map { $0.intersection(whole) } ?? whole
        guard range.duration > .zero else { return base }
        let sampling = KeyframeSampling(clip: clip, range: range, frame: timeline.frameDuration)
        let baseSamples = sampling.sources.map { base.value(at: $0).values }
        guard let width = baseSamples.first?.count, width > 0 else { return base }
        let components = setup.component.map { $0 < width ? [$0] : [] } ?? Array(0..<width)
        let signal = KeyframeSignal(effect: effect, sampling: sampling, base: base, baseSamples: baseSamples, beats: beats)

        var samples = baseSamples
        if effect.kind.reshapesTarget {
            let shaped = signal.reshaped()
            for k in samples.indices { for c in components { samples[k][c] = shaped[k][c] } }
        } else {
            for k in samples.indices {
                for c in components {
                    let made = signal.value(at: k, component: c)
                    switch setup.combine {
                    case .replace: samples[k][c] = made
                    case .add: samples[k][c] += made
                    case .multiply: samples[k][c] *= 1 + made / 100
                    }
                }
            }
        }
        for k in samples.indices { for c in components { samples[k][c] = clip.clamped(samples[k][c], index: c, of: target) } }

        let tolerance: [Double] = effect.kind == .timeStep
            ? Array(repeating: 1e-9, count: width)
            : KeyframeGenerators.tolerances(samples, percent: signal.number(.tolerance, at: 0, default: 0.5))
        let kept = KeyframeGenerators.reduced(times: sampling.sources.map(\.seconds), samples: samples, tolerance: tolerance)
        var keyframes = kept.map {
            Keyframe(time: sampling.sources[$0], value: ComponentValue(values: samples[$0]), generatedBy: effect.id)
        }
        // Outside the range the target keeps its own keyframes, or its value
        // from a frame past each end, so the generated ones don't hold on.
        keyframes += base.keyframes.filter { !range.containsTime($0.time) && $0.time != range.end }
        if !base.isAnimated {
            for edge in [sampling.before, sampling.after].compactMap({ $0 }) where whole.containsTime(edge) || edge == whole.end {
                keyframes.append(Keyframe(time: edge, value: base.value, generatedBy: effect.id))
            }
        }
        return AnimatedValue(base.value, keyframes: keyframes)
    }
}

extension TimelineClip {
    /// Unmarks the keyframes `effectID` wrote on `target`, so they are
    /// plain keyframes no effect will replace.
    mutating func releaseKeyframes(of effectID: UUID, on target: KeyframingTarget) {
        guard let number = number(of: target) else { return }
        let released = AnimatedValue(number.value, keyframes: number.keyframes.map { keyframe in
            var plain = keyframe
            if plain.generatedBy == effectID { plain.generatedBy = nil }
            return plain
        })
        setNumber(released, of: target)
    }
}

// MARK: - Sampling

/// The moments a Keyframing effect is evaluated at: each frame of the
/// timeline the clip's range plays over, as heard, so a retimed clip's
/// pulses land on the beat.
struct KeyframeSampling {
    /// The source time of each sample.
    var sources: [CMTime]
    /// Seconds since the first sample, in the timeline's time.
    var elapsed: [Double]
    /// The timeline time of the first sample.
    var start: CMTime
    /// The source time a frame before the first sample and after the last,
    /// for holding the target's value outside the range.
    var before: CMTime?
    var after: CMTime?
    var frameSeconds: Double

    init(clip: TimelineClip, range: CMTimeRange, frame: CMTime) {
        let a = clip.timelineTime(forSourceTime: range.start)
        let b = clip.timelineTime(forSourceTime: range.end)
        start = CMTimeMinimum(a, b)
        let end = CMTimeMaximum(a, b)
        frameSeconds = frame.seconds
        var sources: [CMTime] = [], elapsed: [Double] = []
        var k: Int32 = 0
        while true {
            let time = CMTimeAdd(start, CMTimeMultiply(frame, multiplier: k))
            guard time <= end else { break }
            sources.append(Self.clamp(clip.sourceTime(atTimelineTime: time), to: range))
            elapsed.append(CMTimeSubtract(time, start).seconds)
            k += 1
        }
        // The end itself, when the range doesn't end on a frame.
        if let last = elapsed.last, CMTimeSubtract(end, start).seconds - last > 1e-6 {
            sources.append(Self.clamp(clip.sourceTime(atTimelineTime: end), to: range))
            elapsed.append(CMTimeSubtract(end, start).seconds)
        }
        self.sources = sources
        self.elapsed = elapsed
        let outside = [CMTimeSubtract(start, frame), CMTimeAdd(end, frame)].map { clip.sourceTime(atTimelineTime: $0) }
        let earlier = outside.min(by: <)!, later = outside.max(by: <)!
        before = earlier < range.start ? earlier : nil
        after = later > range.end ? later : nil
    }

    private static func clamp(_ time: CMTime, to range: CMTimeRange) -> CMTime {
        CMTimeMinimum(CMTimeMaximum(time, range.start), range.end)
    }

    /// How long the range plays, in seconds of the timeline.
    var duration: Double { elapsed.last ?? 0 }
}

/// What one Keyframing effect makes at each sample.
private struct KeyframeSignal {
    let effect: Effect
    let sampling: KeyframeSampling
    let base: AnimatedValue<ComponentValue>
    let baseSamples: [[Double]]
    /// Phase in cycles at each sample, for the kinds with a frequency.
    private var cycles: [Double] = []
    /// Beat Keys' chosen beats.
    private var pulses: [KeyframeGenerators.Pulse] = []

    init(effect: Effect, sampling: KeyframeSampling, base: AnimatedValue<ComponentValue>, baseSamples: [[Double]], beats: [BeatMarker]) {
        self.effect = effect
        self.sampling = sampling
        self.base = base
        self.baseSamples = baseSamples
        switch effect.kind {
        case .wiggler: cycles = integratedPhase(.wiggleFrequency, default: 2)
        case .oscillator: cycles = integratedPhase(.oscillatorFrequency, default: 1)
        case .beatKeys: pulses = chosenPulses(beats)
        default: break
        }
    }

    /// A number setting at sample `k` (its first component).
    func number(_ kind: ControlKind, at k: Int, default fallback: Double) -> Double {
        guard let control = effect.control(kind), control.enabled, sampling.sources.indices.contains(k) else { return fallback }
        return control.values(at: sampling.sources[k]).first ?? fallback
    }

    /// The phase at each sample of a frequency that may be keyframed: the
    /// sum of how many cycles each frame before it played.
    private func integratedPhase(_ kind: ControlKind, default fallback: Double) -> [Double] {
        var phase = 0.0
        return sampling.elapsed.indices.map { k in
            if k > 0 {
                phase += number(kind, at: k - 1, default: fallback) * (sampling.elapsed[k] - sampling.elapsed[k - 1])
            }
            return phase
        }
    }

    private func chosenPulses(_ beats: [BeatMarker]) -> [KeyframeGenerators.Pulse] {
        let start = sampling.start
        let downbeatsOnly = effect.choice(.beatSelection, as: BeatSelection.self) == .downbeats
        let candidates = beats.filter { $0.time >= start && (!downbeatsOnly || $0.isDownbeat) }
        let every = max(Int(number(.everyBeats, at: 0, default: 1)), 1)
        let offset = max(Int(number(.beatOffset, at: 0, default: 0)), 0)
        let accent = number(.accent, at: 0, default: 50) / 100
        return candidates.enumerated().compactMap { index, beat in
            guard index >= offset, (index - offset) % every == 0 else { return nil }
            let elapsed = CMTimeSubtract(beat.time, start).seconds
            let k = min(sampling.elapsed.lowerBound(of: elapsed) { $0 }, sampling.elapsed.count - 1)
            let peak = number(.peak, at: max(k, 0), default: 10)
            return KeyframeGenerators.Pulse(time: elapsed, height: beat.isDownbeat && !downbeatsOnly ? peak * (1 + accent) : peak)
        }
    }

    /// A signal kind's value at sample `k` for component `c`.
    func value(at k: Int, component c: Int) -> Double {
        let elapsed = sampling.elapsed[k]
        switch effect.kind {
        case .wiggler:
            let together = effect.choice(.wiggleDimensions, as: WiggleDimensions.self) == .together
            let smooth = effect.choice(.wiggleType, as: WiggleType.self) != .jagged
            let seed = UInt64(max(number(.seed, at: 0, default: 1), 0))
            let stream = KeyframeGenerators.hash(seed &* 31 &+ UInt64(together ? 0 : c))
            let octaves = Int(number(.octaves, at: 0, default: 1))
            return number(.magnitude, at: k, default: 10)
                * KeyframeGenerators.fractalNoise(cycles[k], octaves: octaves, stream: stream, smooth: smooth)
        case .oscillator:
            let wave = effect.choice(.wave, as: OscillatorWave.self) ?? .sine
            let phase = number(.phase, at: k, default: 0) / 360
            let envelope = KeyframeGenerators.fadeEnvelope(
                elapsed: elapsed, total: sampling.duration, fade: number(.fade, at: k, default: 0)
            )
            return number(.amplitude, at: k, default: 10) * envelope * KeyframeGenerators.wave(wave, at: cycles[k] + phase)
        case .beatKeys:
            return KeyframeGenerators.beatSignal(
                at: elapsed, pulses: pulses, shape: effect.choice(.beatShape, as: BeatShape.self) ?? .pulse,
                decay: number(.decay, at: k, default: 250) / 1000
            )
        default:
            return 0
        }
    }

    /// For the kinds that reshape the target: its new value at every
    /// sample.
    func reshaped() -> [[Double]] {
        switch effect.kind {
        case .smoother:
            return KeyframeGenerators.smoothed(baseSamples, width: Int(number(.smoothing, at: 0, default: 5)))
        case .timeStep:
            let hold = max(Int(number(.hold, at: 0, default: 2)), 1)
            return baseSamples.indices.map { baseSamples[$0 / hold * hold] }
        case .looper:
            return looped()
        case .overshoot:
            return bounced()
        default:
            return baseSamples
        }
    }

    private func looped() -> [[Double]] {
        guard let span = base.animatedRange, span.lowerBound < span.upperBound else { return baseSamples }
        let mode = effect.choice(.loopMode, as: LoopMode.self) ?? .cycle
        let side = effect.choice(.loopSide, as: LoopSide.self) ?? .after
        let start = span.lowerBound.seconds, end = span.upperBound.seconds
        let first = base.value(atSeconds: start).values, last = base.value(atSeconds: end).values
        let step = sampling.frameSeconds
        return sampling.sources.indices.map { k in
            let time = sampling.sources[k].seconds
            let isAfter = time > end, isBefore = time < start
            guard (isAfter && side != .before) || (isBefore && side != .after) else { return baseSamples[k] }
            if mode == .continue {
                // On in a straight line, at the speed of its last (or first)
                // frame.
                let edge = isAfter ? end : start
                let inside = base.value(atSeconds: isAfter ? end - step : start + step).values
                let at = isAfter ? last : first
                return at.indices.map { c in at[c] + (at[c] - inside[c]) / step * abs(time - edge) }
            }
            let read = KeyframeGenerators.loopRead(time, start: start, end: end, mode: mode)
            let value = base.value(atSeconds: read.time).values
            guard mode == .offset else { return value }
            return value.indices.map { c in value[c] + read.cycles * (last[c] - first[c]) }
        }
    }

    private func bounced() -> [[Double]] {
        let stiffness = number(.stiffness, at: 0, default: 200)
        let damping = number(.damping, at: 0, default: 8)
        let mass = number(.mass, at: 0, default: 1)
        guard let firstSource = sampling.sources.first, let lastSource = sampling.sources.last else { return baseSamples }
        // Each keyframe in the range sets off a bounce at the speed the
        // curve arrived at it, in the timeline's time.
        let kicks: [(elapsed: Double, velocity: [Double])] = base.keyframes.compactMap { keyframe in
            guard keyframe.time > firstSource, keyframe.time <= lastSource else { return nil }
            let k = sampling.sources.lowerBound(of: keyframe.time) { $0 }
            guard k > 0, k < sampling.sources.count else { return nil }
            let dt = sampling.elapsed[k] - sampling.elapsed[k - 1]
            guard dt > 0 else { return nil }
            let arriving = base.value(at: keyframe.time).values
            let before = baseSamples[k - 1]
            let velocity = arriving.indices.map { c in (arriving[c] - (c < before.count ? before[c] : arriving[c])) / dt }
            let fraction = sampling.sources[k] == sampling.sources[k - 1] ? 0
                : (keyframe.time.seconds - sampling.sources[k - 1].seconds) / (sampling.sources[k].seconds - sampling.sources[k - 1].seconds)
            return (sampling.elapsed[k - 1] + dt * fraction, velocity)
        }
        return baseSamples.indices.map { k in
            var value = baseSamples[k]
            for kick in kicks {
                for c in value.indices where c < kick.velocity.count {
                    value[c] += KeyframeGenerators.bounce(
                        elapsed: sampling.elapsed[k] - kick.elapsed, velocity: kick.velocity[c],
                        stiffness: stiffness, damping: damping, mass: mass
                    )
                }
            }
            return value
        }
    }
}
