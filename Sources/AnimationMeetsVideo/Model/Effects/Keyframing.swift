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
    /// Audio Keys: what it listens to.
    var audioSource: AudioKeysSource?
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

    mutating func add(_ text: String?) {
        guard let text else { return add(UInt64(0)) }
        add(UInt64(text.utf8.count + 1))
        for byte in text.utf8 { add(UInt64(byte)) }
    }
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
            add(UInt64(keyframe.hold ? 1 : 0))
            add(keyframe.generatedBy)
        }
    }
}

extension KeyframingPrint {
    /// A number and its keyframes, as `add(animated) { [$0] }` adds them,
    /// without an array for each value.
    mutating func add(_ animated: AnimatedValue<Double>) {
        add(animated.value)
        add(UInt64(animated.keyframes.count))
        for keyframe in animated.keyframes {
            add(keyframe.time)
            add(keyframe.value)
            add(keyframe.easeIn?.influence ?? -1)
            add(keyframe.easeIn?.speed ?? -1)
            add(keyframe.easeOut?.influence ?? -1)
            add(keyframe.easeOut?.speed ?? -1)
            add(UInt64(keyframe.hold ? 1 : 0))
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
            return effect(id: effectID)?.controls.first(id: controlID).map(\.number)
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

    /// What limits a target's components (a component and its index in,
    /// the limited one out), looked up once for many.
    func clamp(for target: KeyframingTarget) -> (Double, Int) -> Double {
        switch target {
        case .volume: return { component, _ in AudioLevel.clamped(component) }
        case .control(let effectID, let controlID):
            guard let kind = effect(id: effectID)?.controls.first(id: controlID)?.kind else { return { component, _ in component } }
            return { kind.clamped($0, index: $1) }
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
                effect.controls.filter { !$0.kind.isChoice && !$0.kind.isCurve }.map { KeyframingTarget.control(effectID: effect.id, controlID: $0.id) }
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
    /// still there and below it, one of `keyframingTargets`.
    func keyframingTargetIsReachable(_ effect: Effect, in clip: TimelineClip) -> Bool {
        guard let target = effect.keyframing?.target, let index = clip.effects.index(of: effect.id) else { return false }
        switch target {
        case .volume:
            return playsAudio(clip)
        case .control(let effectID, let controlID):
            func holds(_ effects: ArraySlice<Effect>) -> Bool {
                effects.contains { effect in
                    effect.id == effectID && !effect.kind.isKeyframing
                        && effect.controls.contains { $0.id == controlID && !$0.kind.isChoice && !$0.kind.isCurve }
                }
            }
            return holds(clip.effects[(index + 1)...]) || (playsAudio(clip) && holds(clip.audioEffects[...]))
        }
    }

    /// What a target is called in the effects panel: "Transform · Position"
    /// or "Volume".
    func name(of target: KeyframingTarget, in clip: TimelineClip) -> String {
        switch target {
        case .volume: return "Volume"
        case .control(let effectID, let controlID):
            guard let effect = clip.effect(id: effectID), let control = effect.controls.first(id: controlID)
            else { return "Unavailable" }
            return "\(effect.displayName) · \(control.kind.name)"
        }
    }

    /// The timeline the clip with ID `clipID` is in.
    func timeline(holdingClip clipID: UUID) -> Timeline? {
        timelines.first { $0.layers.contains { $0.clips.contains { $0.id == clipID } } }
    }
}

// MARK: - Reading

extension EditingProject {
    /// Why a Keyframing effect writes nothing, if it doesn't. It is dimmed
    /// then, and what it wrote stays. `timeline` is the clip's, looked up
    /// when not given.
    func keyframingNote(for effect: Effect, in clip: TimelineClip, of timeline: Timeline? = nil) -> EffectNote? {
        guard let setup = effect.keyframing, setup.target != nil else {
            return EffectNote(text: "Choose a control below it to write keyframes to.", dims: true)
        }
        if !keyframingTargetIsReachable(effect, in: clip) {
            return EffectNote(text: "The control it writes to is gone or above it, so its keyframes stay as they are until it is pointed elsewhere.", dims: true)
        }
        if effect.kind == .audioKeys {
            guard let source = setup.audioSource else {
                return EffectNote(text: "Choose what it listens to.", dims: true)
            }
            if let timeline = timeline ?? self.timeline(holdingClip: clip.id) {
                let heard = heardClips(source, in: timeline)
                if heard.isEmpty {
                    return EffectNote(text: "Nothing it listens to plays sound from a file in this timeline.", dims: true)
                }
                if heard.contains(where: { !SpectrogramStore.shared.hasSpectrogram(for: $0.url) }) {
                    return EffectNote(text: "Reading the sound…", dims: false)
                }
            }
        }
        if effect.kind == .beatKeys {
            guard let layerID = setup.beatLayer else {
                return EffectNote(text: "Choose a Sound or Music layer whose beats it follows.", dims: true)
            }
            if let layer = (timeline ?? self.timeline(holdingClip: clip.id))?.layer(id: layerID),
               !layerHasBeats(layer, tracks: DetectedBeats.shared.tracks) {
                return EffectNote(text: "That layer has no beats yet: confirm a beat map in Beat Match, or wait for its beats to be found.", dims: true)
            }
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
    /// `tracks` are the detected beats, read from `DetectedBeats` when not
    /// given.
    func keyframingReadPrint(of effect: Effect, in clip: TimelineClip, of timeline: Timeline, tracks: [UUID: BeatTrack]? = nil) -> UInt64 {
        var fingerprint = KeyframingPrint()
        for time in [clip.startOffset, clip.trimStart, clip.trimEnd, timeline.frameDuration] { fingerprint.add(time) }
        fingerprint.add(clip.time.speed)
        if let range = effect.keyframing?.range {
            fingerprint.add(range.start)
            fingerprint.add(range.end)
        }
        if effect.kind == .audioKeys, let source = effect.keyframing?.audioSource {
            addHeard(source, in: timeline, to: &fingerprint)
        }
        if effect.kind == .beatKeys, let layer = effect.keyframing?.beatLayer.flatMap({ timeline.layer(id: $0) }) {
            for beat in beatMarkers(in: layer, tracks: tracks ?? DetectedBeats.shared.tracks) {
                fingerprint.add(beat.time)
                fingerprint.add(UInt64(beat.position ?? 0))
            }
        }
        return fingerprint.value
    }

    /// Whether a Keyframing effect's keyframes match what it reads now.
    /// One that is off, can't reach its target or hasn't written is
    /// current: there is nothing to make again.
    func keyframingFreshness(
        of effect: Effect, in clip: TimelineClip, of timeline: Timeline, tracks: [UUID: BeatTrack]? = nil
    ) -> KeyframingFreshness {
        keyframingCheck(of: effect, in: clip, of: timeline, tracks: tracks).freshness
    }

    /// Its freshness, and the fingerprint of what it reads when that was
    /// needed to tell.
    private func keyframingCheck(
        of effect: Effect, in clip: TimelineClip, of timeline: Timeline, tracks: [UUID: BeatTrack]?
    ) -> (freshness: KeyframingFreshness, read: UInt64?) {
        guard effect.enabled, let setup = effect.keyframing, let made = setup.readPrint, let target = setup.target,
              keyframingTargetIsReachable(effect, in: clip), let number = clip.number(of: target)
        else { return (.current, nil) }
        let read = keyframingReadPrint(of: effect, in: clip, of: timeline, tracks: tracks)
        guard read != made else { return (.current, read) }
        return (Self.fingerprint(of: number) == setup.writtenPrint ? .outOfDate : .outOfDateWithEdits, read)
    }

    static func fingerprint(of number: AnimatedValue<ComponentValue>) -> UInt64 {
        var fingerprint = KeyframingPrint()
        fingerprint.add(number) { $0.values }
        return fingerprint.value
    }

    /// Makes the keyframes of every Keyframing effect that is out of date
    /// again, leaving those with hand edits for the person to decide.
    /// Returns whether anything changed. For when anything may have
    /// changed under them: a project opening, undo, analysis arriving.
    @discardableResult
    mutating func refreshKeyframing() -> Bool {
        let tracks = DetectedBeats.shared.tracks
        var changed = false
        for timelineID in timelines.map(\.id) {
            changed = refreshKeyframing(in: timelineID, clips: nil, tracks: tracks) || changed
        }
        return changed
    }

    /// The same in one timeline, or for only `clips` of it. An effect reads
    /// other clips of its timeline (a layer's beats, the mix's sound), so
    /// an edit to one clip can leave another's out of date: give `clips`
    /// only when nothing else changed.
    @discardableResult
    mutating func refreshKeyframing(in timelineID: UUID, clips: Set<UUID>? = nil) -> Bool {
        refreshKeyframing(in: timelineID, clips: clips, tracks: DetectedBeats.shared.tracks)
    }

    /// The same after an edit that made this project from `old`: in the
    /// timelines it changed, or everywhere when it changed something
    /// outside them (the media, which they read). Run after each edit, so
    /// the new keyframes are part of the same undo step.
    @discardableResult
    mutating func refreshKeyframing(after old: EditingProject) -> Bool {
        guard let edited = timelinesChanged(since: old) else { return refreshKeyframing() }
        guard !edited.isEmpty else { return false }
        let tracks = DetectedBeats.shared.tracks
        var changed = false
        for timelineID in edited {
            changed = refreshKeyframing(in: timelineID, clips: nil, tracks: tracks) || changed
        }
        return changed
    }

    /// The timelines that differ from `old`'s, or nil when something
    /// outside them differs too.
    func timelinesChanged(since old: EditingProject) -> [UUID]? {
        var outside = self, oldOutside = old
        outside.timelines = []
        oldOutside.timelines = []
        guard outside == oldOutside else { return nil }
        return timelines.filter { timeline in
            guard let before = old.timeline(id: timeline.id) else { return true }
            // Equal nonzero versions are equal timelines.
            if timeline.version != 0, timeline.version == before.version { return false }
            return timeline != before
        }.map(\.id)
    }

    private mutating func refreshKeyframing(in timelineID: UUID, clips: Set<UUID>?, tracks: [UUID: BeatTrack]) -> Bool {
        // Each effect is checked against the timeline as it was before any
        // of them made their keyframes again.
        guard let timeline = timeline(id: timelineID) else { return false }
        var changed = false
        for layer in timeline.layers {
            for clip in layer.clips where clips?.contains(clip.id) ?? true {
                for effect in clip.effects where effect.kind.isKeyframing {
                    let check = keyframingCheck(of: effect, in: clip, of: timeline, tracks: tracks)
                    guard check.freshness == .outOfDate else { continue }
                    // What it reads now is what it read for the check, until
                    // another effect here has written.
                    let read = changed ? nil : check.read
                    if regenerateKeyframes(ofEffect: effect.id, onClip: clip.id, in: timelineID, tracks: tracks, readPrint: read) {
                        changed = true
                    }
                }
            }
        }
        return changed
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
    /// Returns whether anything changed. `tracks` are the detected beats,
    /// read from `DetectedBeats` when not given; `readPrint`, when given,
    /// is what it reads, worked out already.
    @discardableResult
    mutating func regenerateKeyframes(
        ofEffect effectID: UUID, onClip clipID: UUID, in timelineID: UUID,
        tracks: [UUID: BeatTrack]? = nil, readPrint: UInt64? = nil
    ) -> Bool {
        guard let (clip, _) = clipAndLayer(clipID, in: timelineID), let timeline = timeline(id: timelineID),
              let effect = clip.effects.first(id: effectID), effect.enabled,
              var setup = effect.keyframing, let target = setup.target,
              keyframingTargetIsReachable(effect, in: clip), let current = clip.number(of: target)
        else { return false }
        // Only Beat Keys, which follow a layer, read the beats.
        let tracks = tracks ?? (setup.beatLayer != nil ? DetectedBeats.shared.tracks : [:])
        let base = setup.base ?? Self.removingKeyframes(of: effectID, from: current)
        setup.base = base
        setup.readPrint = readPrint ?? keyframingReadPrint(of: effect, in: clip, of: timeline, tracks: tracks)
        var heard: [[Double]]?
        if effect.kind == .audioKeys {
            let range = Self.writtenRange(setup, of: clip)
            let times = KeyframeSampling(clip: clip, range: range, frame: timeline.frameDuration).timelineTimes
            heard = setup.audioSource.flatMap { heardBands($0, in: timeline, at: times) }
            guard heard != nil else {
                // Still reading the sound, or nothing to listen to: keep
                // what is there, and take it as what was written, so the
                // sound arriving makes the keyframes rather than asking.
                setup.writtenPrint = Self.fingerprint(of: current)
                guard setup != effect.keyframing else { return false }
                editClip(clipID, in: timelineID) { clip in
                    if let index = clip.effects.index(of: effectID) { clip.effects[index].keyframing = setup }
                }
                return true
            }
        }
        let written = Self.generated(
            effect, setup: setup, base: base, target: target, clip: clip, timeline: timeline,
            beats: setup.beatLayer.flatMap { timeline.layer(id: $0) }.map { beatMarkers(in: $0, tracks: tracks) } ?? [],
            heard: heard
        )
        setup.writtenPrint = Self.fingerprint(of: written)
        // Making the same again leaves the document and the undo stack alone.
        guard written != current || setup != effect.keyframing else { return false }
        editClip(clipID, in: timelineID) { clip in
            clip.setNumber(written, of: target)
            if let index = clip.effects.index(of: effectID) { clip.effects[index].keyframing = setup }
        }
        return true
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

    /// The span a Keyframing effect writes to: its range within the clip,
    /// or the whole clip.
    static func writtenRange(_ setup: KeyframingSetup, of clip: TimelineClip) -> CMTimeRange {
        let whole = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
        return setup.range.map { $0.intersection(whole) } ?? whole
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
        clip: TimelineClip, timeline: Timeline, beats: [BeatMarker], heard: [[Double]]?
    ) -> AnimatedValue<ComponentValue> {
        let whole = CMTimeRange(start: clip.trimStart, end: clip.trimEnd)
        let range = writtenRange(setup, of: clip)
        guard range.duration > .zero else { return base }
        let sampling = KeyframeSampling(clip: clip, range: range, frame: timeline.frameDuration)
        let (baseSamples, width) = base.flatValues(at: sampling.sources)
        guard width > 0 else { return base }
        let count = sampling.sources.count
        let components = setup.component.map { $0 < width ? [$0] : [] } ?? Array(0..<width)
        let signal = KeyframeSignal(
            effect: effect, sampling: sampling, base: base, baseSamples: baseSamples, width: width, beats: beats, heard: heard
        )

        // Each sample's components one after another.
        var samples = baseSamples
        if effect.kind.reshapesTarget {
            let shaped = signal.reshaped()
            for k in 0..<count { for c in components { samples[k * width + c] = shaped[k * width + c] } }
        } else {
            for k in 0..<count {
                for c in components {
                    let made = signal.value(at: k, component: c)
                    switch setup.combine {
                    case .replace: samples[k * width + c] = made
                    case .add: samples[k * width + c] += made
                    case .multiply: samples[k * width + c] *= 1 + made / 100
                    }
                }
            }
        }
        let clamp = clip.clamp(for: target)
        for k in 0..<count { for c in components { samples[k * width + c] = clamp(samples[k * width + c], c) } }
        func value(at k: Int) -> ComponentValue { ComponentValue(values: Array(samples[(k * width)..<((k + 1) * width)])) }

        // A wave or a train of pulses over a target that holds still gets a
        // keyframe at each peak, beat or turn, eased as an animator would
        // key it; a Time Step that holds every component one at each side
        // of each jump; anything else is every frame, thinned to the
        // tolerance.
        var keyframes: [Keyframe<ComponentValue>]
        if !base.isAnimated, let events = signal.events() {
            keyframes = events.map {
                Keyframe(
                    time: sampling.sources[$0.index], value: value(at: $0.index),
                    easeIn: $0.easeIn, easeOut: $0.easeOut, generatedBy: effect.id
                )
            }
        } else {
            let kept: [Int]
            if effect.kind == .timeStep, components.count == width {
                kept = KeyframeGenerators.steps(samples, components: width)
            } else {
                // A Time Step on one component holds it to within next to
                // nothing, while the others follow their own curve.
                let tolerance = effect.kind == .timeStep
                    ? Array(repeating: 1e-9, count: width)
                    : KeyframeGenerators.tolerances(samples, components: width, percent: signal.tolerance)
                kept = KeyframeGenerators.reduced(times: sampling.sourceSeconds, samples: samples, tolerance: tolerance)
            }
            keyframes = kept.map { Keyframe(time: sampling.sources[$0], value: value(at: $0), generatedBy: effect.id) }
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
        guard let number = number(of: target), number.keyframes.contains(where: { $0.generatedBy == effectID }) else { return }
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
    /// The same in seconds.
    var sourceSeconds: [Double]
    /// The timeline time of each sample.
    var timelineTimes: [CMTime]
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
        var times: [CMTime] = []
        let frames = CMTimeSubtract(end, start).seconds / frame.seconds
        if frames.isFinite, frames >= 0, frames < Double(Int32.max) { times.reserveCapacity(Int(frames) + 2) }
        var k: Int32 = 0
        while true {
            let time = CMTimeAdd(start, CMTimeMultiply(frame, multiplier: k))
            guard time <= end else { break }
            times.append(time)
            k += 1
        }
        // The end itself, when the range doesn't end on a frame.
        if let last = times.last, CMTimeSubtract(end, last).seconds > 1e-6 { times.append(end) }
        let start = start
        timelineTimes = times
        let sources = times.map { Self.clamp(clip.sourceTime(atTimelineTime: $0), to: range) }
        self.sources = sources
        sourceSeconds = sources.map(\.seconds)
        let elapsed = times.map { CMTimeSubtract($0, start).seconds }
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

extension AnimatedValue where Value == ComponentValue {
    /// Component `c` of what `reading` gives, as `value(of:)` makes it,
    /// without making the rest; nil past its components.
    @inline(__always)
    func component(_ c: Int, of reading: Reading) -> Double? {
        switch reading {
        case .value:
            return c < value.values.count ? value.values[c] : nil
        case .keyframe(let index):
            let values = keyframes[index].value.values
            return c < values.count ? values[c] : nil
        case .blend(let next, let progress):
            let from = keyframes[next - 1].value.values, to = keyframes[next].value.values
            guard c < from.count, c < to.count else { return nil }
            return Double.interpolate(from[c], to[c], fraction: progress)
        }
    }

    /// The values at each of `times`, as `value(at:)` gives them, held flat:
    /// each one's components one after another, as many as the first's
    /// (`width`).
    func flatValues(at times: [CMTime]) -> (samples: [Double], width: Int) {
        let readings = readings(at: times)
        guard let first = readings.first else { return ([], 0) }
        let width = value(of: first).values.count
        var samples: [Double] = []
        samples.reserveCapacity(readings.count * width)
        for reading in readings {
            for c in 0..<width { samples.append(component(c, of: reading) ?? 0) }
        }
        return (samples, width)
    }
}

/// A number setting of a Keyframing effect, read once for every sample:
/// its first component, at each sample when it is keyframed. Where the
/// effect lacks it, or it is off, the caller's fallback stands.
private struct NumberSetting {
    private let isOn: Bool
    private let fixed: Double?
    /// Empty unless it is keyframed.
    private let sampled: [Double?]
    private let count: Int

    init(_ control: EffectControl?, sampling: KeyframeSampling) {
        count = sampling.sources.count
        guard let control, control.enabled else {
            (isOn, fixed, sampled) = (false, nil, [])
            return
        }
        isOn = true
        if control.isAnimated {
            let number = control.number
            fixed = nil
            sampled = number.readings(at: sampling.sources).map { number.component(0, of: $0) }
        } else {
            fixed = control.number.value.values.first
            sampled = []
        }
    }

    /// Its value at sample `k`.
    @inline(__always)
    func at(_ k: Int, default fallback: Double) -> Double {
        guard isOn, k >= 0, k < count else { return fallback }
        return (sampled.isEmpty ? fixed : sampled[k]) ?? fallback
    }
}

/// A setting of two numbers (a range), read once for every sample: at
/// each sample when it is keyframed. The control's defaults where the
/// effect lacks it or it is off.
private struct PairSetting {
    private let fixed: (Double, Double)
    /// Empty unless it is keyframed.
    private let sampled: [(Double, Double)]

    init(_ kind: ControlKind, of effect: Effect, sampling: KeyframeSampling) {
        let defaults = (kind.defaultValues[0], kind.defaultValues[1])
        guard let control = effect.control(kind), control.enabled else {
            (fixed, sampled) = (defaults, [])
            return
        }
        if control.isAnimated {
            let number = control.number
            fixed = defaults
            sampled = number.readings(at: sampling.sources).map { reading in
                guard let low = number.component(0, of: reading), let high = number.component(1, of: reading) else { return defaults }
                return (low, high)
            }
        } else {
            let values = control.number.value.values
            fixed = values.count >= 2 ? (values[0], values[1]) : defaults
            sampled = []
        }
    }

    /// Its values at sample `k`.
    @inline(__always)
    func at(_ k: Int) -> (Double, Double) { sampled.isEmpty ? fixed : sampled[k] }
}

/// What one Keyframing effect makes at each sample. Its settings are read
/// once, when it is made, for every sample.
private struct KeyframeSignal {
    /// A Wiggler's settings.
    private struct Wiggle {
        let magnitude: NumberSetting
        /// Phase in cycles at each sample.
        let cycles: [Double]
        let octaves: Int
        /// The noise each component follows.
        let streams: [UInt64]
        let smooth: Bool
    }

    /// A reshaping kind's settings.
    private enum Reshaping {
        case smooth(window: Int)
        case step(hold: Int)
        case loop(LoopMode, LoopSide)
        case overshoot(stiffness: Double, damping: Double, mass: Double)
    }

    let kind: EffectKind
    let sampling: KeyframeSampling
    let base: AnimatedValue<ComponentValue>
    /// The target at each sample, each sample's `width` components one
    /// after another.
    let baseSamples: [Double]
    let width: Int
    /// How closely, in percent of each component's range, the keyframes
    /// kept follow what it makes.
    let tolerance: Double
    /// An Oscillator's, Beat Keys' or Audio Keys' output at each sample,
    /// before Combine; the same for every component.
    private let made: [Double]
    private let wiggle: Wiggle?
    /// An Oscillator's wave, and where in its cycle each sample is.
    private let wave: OscillatorWave
    private let positions: [Double]
    /// Beat Keys' chosen beats, what it does on each, and its decay at
    /// each sample, in seconds.
    private let pulses: [KeyframeGenerators.Pulse]
    private let beatShape: BeatShape
    private let decays: [Double]
    private let reshaping: Reshaping?

    init(
        effect: Effect, sampling: KeyframeSampling, base: AnimatedValue<ComponentValue>, baseSamples: [Double], width: Int,
        beats: [BeatMarker], heard: [[Double]]?
    ) {
        kind = effect.kind
        self.sampling = sampling
        self.base = base
        self.baseSamples = baseSamples
        self.width = width
        func number(_ kind: ControlKind) -> NumberSetting { NumberSetting(effect.control(kind), sampling: sampling) }
        tolerance = number(.tolerance).at(0, default: 0.5)
        wave = effect.choice(.wave, as: OscillatorWave.self) ?? .sine
        beatShape = effect.choice(.beatShape, as: BeatShape.self) ?? .pulse
        var made: [Double] = [], wiggle: Wiggle?, positions: [Double] = []
        var pulses: [KeyframeGenerators.Pulse] = [], decays: [Double] = [], reshaping: Reshaping?
        switch effect.kind {
        case .wiggler:
            let together = effect.choice(.wiggleDimensions, as: WiggleDimensions.self) == .together
            let seed = UInt64(max(number(.seed).at(0, default: 1), 0))
            wiggle = Wiggle(
                magnitude: number(.magnitude),
                cycles: Self.integratedPhase(number(.wiggleFrequency), default: 2, sampling: sampling),
                octaves: Int(number(.octaves).at(0, default: 1)),
                streams: (0..<width).map { KeyframeGenerators.hash(seed &* 31 &+ UInt64(together ? 0 : $0)) },
                smooth: effect.choice(.wiggleType, as: WiggleType.self) != .jagged
            )
        case .oscillator:
            let cycles = Self.integratedPhase(number(.oscillatorFrequency), default: 1, sampling: sampling)
            let phase = number(.phase), amplitude = number(.amplitude), fade = number(.fade)
            positions = cycles.indices.map { cycles[$0] + phase.at($0, default: 0) / 360 }
            let wave = wave
            made = positions.indices.map { k in
                let envelope = KeyframeGenerators.fadeEnvelope(
                    elapsed: sampling.elapsed[k], total: sampling.duration, fade: fade.at(k, default: 0)
                )
                return amplitude.at(k, default: 10) * envelope * KeyframeGenerators.wave(wave, at: positions[k])
            }
        case .beatKeys:
            let decay = number(.decay)
            decays = sampling.elapsed.indices.map { decay.at($0, default: 250) / 1000 }
            pulses = Self.chosenPulses(beats, of: effect, sampling: sampling, number: number)
            made = KeyframeGenerators.beatSignals(at: sampling.elapsed, pulses: pulses, shape: beatShape, decays: decays)
        case .audioKeys:
            made = heard.map { Self.listen($0, effect: effect, sampling: sampling, number: number) } ?? []
        case .smoother:
            reshaping = .smooth(window: Int(number(.smoothing).at(0, default: 5)))
        case .timeStep:
            reshaping = .step(hold: max(Int(number(.hold).at(0, default: 2)), 1))
        case .looper:
            reshaping = .loop(
                effect.choice(.loopMode, as: LoopMode.self) ?? .cycle, effect.choice(.loopSide, as: LoopSide.self) ?? .after
            )
        case .overshoot:
            reshaping = .overshoot(
                stiffness: number(.stiffness).at(0, default: 200), damping: number(.damping).at(0, default: 8),
                mass: number(.mass).at(0, default: 1)
            )
        default:
            break
        }
        (self.made, self.wiggle, self.positions, self.pulses, self.decays, self.reshaping)
            = (made, wiggle, positions, pulses, decays, reshaping)
    }

    /// Audio Keys' steps: the range's level, between the box's bottom and
    /// top, followed with attack and release, along the curve, onto the
    /// output range.
    private static func listen(
        _ heard: [[Double]], effect: Effect, sampling: KeyframeSampling, number: (ControlKind) -> NumberSetting
    ) -> [Double] {
        let frequencies = PairSetting(.frequencyRange, of: effect, sampling: sampling)
        let levels = PairSetting(.levelRange, of: effect, sampling: sampling)
        let output = PairSetting(.outputRange, of: effect, sampling: sampling)
        let attack = number(.keyAttack), release = number(.keyRelease)
        let positions = sampling.sources.indices.map { k -> Double in
            guard k < heard.count else { return 0 }
            let frequencies = frequencies.at(k), levels = levels.at(k)
            let level = AudioKeysMath.level(of: heard[k], from: frequencies.0, to: frequencies.1)
            return AudioKeysMath.normalized(level, floor: levels.0, ceiling: levels.1)
        }
        let followed = AudioKeysMath.envelope(
            positions, elapsed: sampling.elapsed,
            attack: positions.indices.map { attack.at($0, default: 0) / 1000 },
            release: positions.indices.map { release.at($0, default: 200) / 1000 }
        )
        let curve = effect.choice(.keyCurve, as: KeyCurve.self) ?? .linear
        return followed.indices.map { k in
            let output = output.at(k)
            return output.0 + (output.1 - output.0) * AudioKeysMath.shaped(followed[k], curve)
        }
    }

    /// The phase at each sample of a frequency that may be keyframed: the
    /// sum of how many cycles each frame before it played.
    private static func integratedPhase(_ frequency: NumberSetting, default fallback: Double, sampling: KeyframeSampling) -> [Double] {
        var phase = 0.0
        return sampling.elapsed.indices.map { k in
            if k > 0 {
                phase += frequency.at(k - 1, default: fallback) * (sampling.elapsed[k] - sampling.elapsed[k - 1])
            }
            return phase
        }
    }

    /// The beats Beat Keys follows from the start of the range, up to the
    /// first past its end, which a ramp or alternation heads for.
    private static func chosenPulses(
        _ beats: [BeatMarker], of effect: Effect, sampling: KeyframeSampling, number: (ControlKind) -> NumberSetting
    ) -> [KeyframeGenerators.Pulse] {
        let start = sampling.start
        let downbeatsOnly = effect.choice(.beatSelection, as: BeatSelection.self) == .downbeats
        let every = max(Int(number(.everyBeats).at(0, default: 1)), 1)
        let offset = max(Int(number(.beatOffset).at(0, default: 0)), 0)
        let accent = number(.accent).at(0, default: 50) / 100
        let peak = number(.peak)
        var pulses: [KeyframeGenerators.Pulse] = []
        var index = 0
        for beat in beats where beat.time >= start && (!downbeatsOnly || beat.isDownbeat) {
            defer { index += 1 }
            guard index >= offset, (index - offset) % every == 0 else { continue }
            let elapsed = CMTimeSubtract(beat.time, start).seconds
            let k = min(sampling.elapsed.lowerBound(of: elapsed) { $0 }, sampling.elapsed.count - 1)
            let height = peak.at(max(k, 0), default: 10)
            pulses.append(KeyframeGenerators.Pulse(time: elapsed, height: beat.isDownbeat && !downbeatsOnly ? height * (1 + accent) : height))
            if elapsed > sampling.duration { break }
        }
        return pulses
    }

    /// A signal kind's value at sample `k` for component `c`.
    @inline(__always)
    func value(at k: Int, component c: Int) -> Double {
        if let wiggle {
            return wiggle.magnitude.at(k, default: 10)
                * KeyframeGenerators.fractalNoise(wiggle.cycles[k], octaves: wiggle.octaves, stream: wiggle.streams[c], smooth: wiggle.smooth)
        }
        return k < made.count ? made[k] : 0
    }

    /// A keyframe at one of a signal's events: which sample, and how the
    /// curve arrives and leaves.
    struct Event {
        var index: Int
        var easeIn: KeyframeEase?
        var easeOut: KeyframeEase?
    }

    /// Where an animator would key this signal, for the kinds with a
    /// natural rate: an Oscillator's peaks and troughs (eased, for a sine),
    /// or its jumps; Beat Keys' beats, the frame before each and where its
    /// decay ends. Always the first and last sample. Nil for the others.
    func events() -> [Event]? {
        let count = sampling.sources.count
        guard count > 1 else { return nil }
        var events = [Event?](repeating: nil, count: count)
        func add(_ index: Int, in easeIn: KeyframeEase? = nil, out easeOut: KeyframeEase? = nil) {
            guard index >= 0, index < count else { return }
            events[index] = Event(index: index, easeIn: easeIn, easeOut: easeOut)
        }
        switch kind {
        case .oscillator:
            // Where in its cycle each sample is; a peak or trough falls at
            // a quarter or three quarters, a jump at a half or a whole.
            for k in 1..<count {
                switch wave {
                case .sine, .triangle:
                    // The frame nearest each peak or trough.
                    let before = floor((positions[k - 1] - 0.25) * 2), after = floor((positions[k] - 0.25) * 2)
                    guard after != before else { continue }
                    let crossing = (after / 2 + 0.25)
                    let nearer = abs(positions[k] - crossing) < abs(positions[k - 1] - crossing) ? k : k - 1
                    let ease: KeyframeEase? = wave == .sine ? .easy : nil
                    add(nearer, in: ease, out: ease)
                case .square, .sawtooth:
                    // Held to the frame before a jump, then the new value: a
                    // square jumps every half cycle, a sawtooth wraps once a
                    // cycle, half way through.
                    let jumps = wave == .square
                        ? floor(positions[k - 1] * 2) != floor(positions[k] * 2)
                        : floor(positions[k - 1] + 0.5) != floor(positions[k] + 0.5)
                    if jumps {
                        add(k - 1)
                        add(k)
                    }
                }
            }
        case .beatKeys:
            // The sample at or after each beat.
            let starts = pulses.map { pulse in sampling.elapsed.lowerBound(of: pulse.time) { $0 } }
            for (n, pulse) in pulses.enumerated() {
                let at = starts[n]
                guard at < count else { continue }
                let next = n + 1 < pulses.count ? starts[n + 1] : count
                add(at - 1)
                switch beatShape {
                case .ramp:
                    add(at)
                    add(next - 1)
                case .pulse, .step, .alternate:
                    add(at, out: .easy)
                    let settled = sampling.elapsed.lowerBound(of: pulse.time + decays[at]) { $0 }
                    if settled < next - 1 { add(settled, in: .easy) }
                }
            }
        default:
            return nil
        }
        add(0, out: events[0]?.easeOut)
        add(count - 1, in: events[count - 1]?.easeIn)
        return events.compactMap { $0 }
    }

    /// For the kinds that reshape the target: its new value at every
    /// sample, held as `baseSamples` is.
    func reshaped() -> [Double] {
        switch reshaping {
        case .smooth(let window):
            return KeyframeGenerators.smoothed(baseSamples, components: width, width: window)
        case .step(let hold):
            var samples = baseSamples
            for k in 0..<(baseSamples.count / width) {
                let held = k / hold * hold
                for c in 0..<width { samples[k * width + c] = baseSamples[held * width + c] }
            }
            return samples
        case .loop(let mode, let side):
            return looped(mode: mode, side: side)
        case .overshoot(let stiffness, let damping, let mass):
            return bounced(stiffness: stiffness, damping: damping, mass: mass)
        case nil:
            return baseSamples
        }
    }

    private func looped(mode: LoopMode, side: LoopSide) -> [Double] {
        guard let span = base.animatedRange, span.lowerBound < span.upperBound else { return baseSamples }
        let start = span.lowerBound.seconds, end = span.upperBound.seconds
        let first = base.value(atSeconds: start).values, last = base.value(atSeconds: end).values
        // Continue: on in a straight line, at the speed of its last (or
        // first) frame.
        var slopeAfter: [Double] = [], slopeBefore: [Double] = []
        if mode == .continue {
            let step = sampling.frameSeconds
            let insideAfter = base.value(atSeconds: end - step).values, insideBefore = base.value(atSeconds: start + step).values
            slopeAfter = last.indices.map { c in (last[c] - insideAfter[c]) / step }
            slopeBefore = first.indices.map { c in (first[c] - insideBefore[c]) / step }
        }
        var samples = baseSamples
        for k in 0..<(baseSamples.count / width) {
            let time = sampling.sourceSeconds[k]
            let isAfter = time > end, isBefore = time < start
            guard (isAfter && side != .before) || (isBefore && side != .after) else { continue }
            if mode == .continue {
                let edge = isAfter ? end : start
                let at = isAfter ? last : first, slope = isAfter ? slopeAfter : slopeBefore
                for c in 0..<width { samples[k * width + c] = at[c] + slope[c] * abs(time - edge) }
                continue
            }
            let read = KeyframeGenerators.loopRead(time, start: start, end: end, mode: mode)
            let value = base.value(atSeconds: read.time).values
            for c in 0..<width {
                samples[k * width + c] = mode == .offset ? value[c] + read.cycles * (last[c] - first[c]) : value[c]
            }
        }
        return samples
    }

    private func bounced(stiffness: Double, damping: Double, mass: Double) -> [Double] {
        guard let firstSource = sampling.sources.first, let lastSource = sampling.sources.last else { return baseSamples }
        // Each keyframe in the range sets off a bounce at the speed the
        // curve arrived at it, in the timeline's time, in the order they
        // start.
        let kicks: [(elapsed: Double, velocity: [Double])] = base.keyframes.compactMap { keyframe in
            guard keyframe.time > firstSource, keyframe.time <= lastSource else { return nil }
            let k = sampling.sources.lowerBound(of: keyframe.time) { $0 }
            guard k > 0, k < sampling.sources.count else { return nil }
            let dt = sampling.elapsed[k] - sampling.elapsed[k - 1]
            guard dt > 0 else { return nil }
            let arriving = keyframe.value.values
            let velocity = arriving.indices.map { c in
                (arriving[c] - (c < width ? baseSamples[(k - 1) * width + c] : arriving[c])) / dt
            }
            let fraction = sampling.sources[k] == sampling.sources[k - 1] ? 0
                : (keyframe.time.seconds - sampling.sourceSeconds[k - 1]) / (sampling.sourceSeconds[k] - sampling.sourceSeconds[k - 1])
            return (sampling.elapsed[k - 1] + dt * fraction, velocity)
        }.sorted { $0.elapsed < $1.elapsed }
        let lasts = KeyframeGenerators.bounceLength(damping: damping, mass: mass)
        var samples = baseSamples
        // Kicks before this one have settled.
        var settled = 0
        for k in 0..<(baseSamples.count / width) {
            let elapsed = sampling.elapsed[k]
            while settled < kicks.count, elapsed - kicks[settled].elapsed > lasts { settled += 1 }
            for kick in kicks[settled...] {
                guard kick.elapsed < elapsed else { break }
                for c in 0..<min(width, kick.velocity.count) {
                    samples[k * width + c] += KeyframeGenerators.bounce(
                        elapsed: elapsed - kick.elapsed, velocity: kick.velocity[c],
                        stiffness: stiffness, damping: damping, mass: mass
                    )
                }
            }
        }
        return samples
    }
}
