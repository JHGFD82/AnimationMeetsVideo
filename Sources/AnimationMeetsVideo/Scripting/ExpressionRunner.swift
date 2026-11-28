import CoreMedia
import Foundation
import Observation
import os

/// Why expression runs fail, in the system log: `log show --predicate
/// 'subsystem == "com.jhgfd.animationmeetsvideo"'`.
let expressionLog = Logger(subsystem: "com.jhgfd.animationmeetsvideo", category: "Expressions")

/// Runs the expressions waiting for a run (see docs/python-scripting.md,
/// "A run" and "Arriving"): one at a time, on the confined helper, each
/// against the project as it was when it was asked for. A newer request
/// for the same effect replaces one still waiting. Each run's samples, or
/// its error, go into `ExpressionResults`, and the editor writes the
/// keyframes of those that fit, as it does when analysis arrives.
@MainActor
@Observable
final class ExpressionRunner {
    static let shared = ExpressionRunner(helper: PythonHelpers.expressions)

    /// How long a run may take before it is stopped.
    static let timeLimit: Duration = .seconds(5)

    struct Job: Equatable {
        var timelineID: UUID
        var clipID: UUID
        var effectID: UUID
    }

    /// The effects being run or waiting, for the designer to show.
    private(set) var running: Set<UUID> = []
    @ObservationIgnored private let helper: any ScriptHelper
    @ObservationIgnored private var queue: [(job: Job, project: EditingProject)] = []
    @ObservationIgnored private var isDraining = false

    init(helper: any ScriptHelper) {
        self.helper = helper
    }

    /// Asks for a run of every expression in `project` that waits for one.
    func runWaiting(in project: EditingProject) {
        // Most projects have none, and finding them costs a look at each.
        guard project.timelines.contains(where: { timeline in
            timeline.layers.contains { $0.clips.contains { $0.hasKeyframingEffect && $0.effects.contains { $0.kind == .expression } } }
        }) else { return }
        for waiting in project.waitingExpressions() {
            enqueue(Job(timelineID: waiting.timelineID, clipID: waiting.clipID, effectID: waiting.effectID), in: project)
        }
    }

    private func enqueue(_ job: Job, in project: EditingProject) {
        queue.removeAll { $0.job.effectID == job.effectID }
        queue.append((job, project))
        running.insert(job.effectID)
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let (job, project) = queue.removeFirst()
            if let result = await run(job, in: project) {
                ExpressionResults.shared.store(result, for: job.effectID)
                NotificationCenter.default.post(name: .expressionResultsChanged, object: nil)
            }
            if !queue.contains(where: { $0.job.effectID == job.effectID }) { running.remove(job.effectID) }
        }
        isDraining = false
    }

    /// One run: the expression's samples, or what went wrong, made from
    /// `project` as it is.
    func run(_ job: Job, in project: EditingProject) async -> ExpressionResult? {
        guard let request = Self.request(for: job, in: project) else { return nil }
        let bridge = ProjectBridge(
            project: project,
            context: ProjectBridge.Context(
                beatTracks: DetectedBeats.shared.tracks, ownTarget: request.ownTarget, ownBase: request.base,
                sampleTimes: request.timelineTimes, audioSource: request.effect.keyframing?.audioSource,
                beatLayer: request.effect.keyframing?.beatLayer
            ),
            readsOnly: true
        )
        var failure: ExpressionFailure?
        var values: [Double] = []
        do {
            let end = try await helper.run(request.request, output: { _ in }, answer: { await bridge.answer($0) })
            switch end {
            case .samples(let samples): values = samples
            case .failed(let error):
                failure = ExpressionFailure(summary: error.summary, time: error.time, details: error.fullTraceback)
                // The note has one line; the whole traceback, the helper's
                // frames too, goes to the log to report.
                if !error.wasStopped {
                    expressionLog.error("Expression run failed: \(error.summary, privacy: .public)\n\(error.fullTraceback, privacy: .public)")
                }
            case .finished: failure = ExpressionFailure(summary: "The expression gave no samples.", time: nil)
            }
        } catch {
            let details = "\(error.localizedDescription)\n\n\(String(reflecting: error))"
            expressionLog.error("Expression run failed before it could finish: \(details, privacy: .public)")
            failure = ExpressionFailure(summary: error.localizedDescription, time: nil, details: details)
        }
        // A partial run read only what its samples needed: what the whole
        // run before it read holds too.
        var reads = request.reused?.reads ?? []
        for read in await bridge.reads where !reads.contains(read) { reads.append(read) }
        let expected = request.times.count * request.width
        if failure == nil, values.count != expected {
            failure = ExpressionFailure(summary: "The expression gave \(values.count) numbers, not \(expected).", time: nil)
        }
        // Checked here too, not only by the helper, whose checks code it ran
        // could undo: a NaN keyframe would fail every save after it
        // (code-review-notes.md, F56).
        if failure == nil, let bad = values.first(where: { !$0.isFinite }) {
            failure = ExpressionFailure(summary: "The expression gave \(bad), not a number a value can have.", time: nil)
        }
        let print = project.expressionPrint(of: request.effect, in: request.clip, of: request.timeline, base: request.base, reads: reads)
        return ExpressionResult(
            times: failure == nil ? request.times : [], values: failure == nil ? values : [], width: request.width,
            reads: reads, failure: failure, print: print, readsPrint: project.readsPrint(reads),
            input: failure == nil ? request.input : nil
        )
    }

    /// What an expression's samples depend on besides its code and its
    /// tables: what `audio()` hears and `beats` follows, which component
    /// it writes, where it is, and the frame rate.
    private static func settingsKey(of effect: Effect, setup: KeyframingSetup, timeline: Timeline, clip: TimelineClip, layer: UUID) -> UInt64 {
        var key = KeyframingPrint()
        switch setup.audioSource {
        case nil: key.add(UInt64(0))
        case .mix?: key.add(UInt64(1))
        case .layer(let id)?:
            key.add(UInt64(2))
            key.add(id)
        case .clip(let id)?:
            key.add(UInt64(3))
            key.add(id)
        }
        key.add(setup.beatLayer)
        key.add(UInt64(bitPattern: Int64(setup.component ?? -1)))
        key.add(timeline.id)
        key.add(clip.id)
        key.add(layer)
        key.add(timeline.frameRate)
        return key.value
    }

    /// What is sent for one expression, and what it is made from.
    struct Prepared {
        var request: HelperRequest
        var times: [CMTime]
        /// The same samples in the timeline's time.
        var timelineTimes: [CMTime]
        var width: Int
        var effect: Effect
        var clip: TimelineClip
        var timeline: Timeline
        var base: AnimatedValue<ComponentValue>
        /// The control it writes to, as a read.
        var ownTarget: KeyframingRead
        /// The last result, when the helper may start from it.
        var reused: ExpressionResult?
        /// What this run is sent, for the run after it.
        var input: ExpressionInput
    }

    /// The request for an expression: its code, and a table for each name
    /// that changes from sample to sample, one sample per timeline frame of
    /// its range (`KeyframeSampling`, as every method samples).
    static func request(for job: Job, in project: EditingProject) -> Prepared? {
        guard let timeline = project.timeline(id: job.timelineID),
              let found = project.clipAndLayer(job.clipID, in: job.timelineID),
              let effect = found.clip.effect(id: job.effectID), effect.kind == .expression,
              let setup = effect.keyframing, let target = setup.target, let current = found.clip.number(of: target)
        else { return nil }
        let clip = found.clip
        let base = setup.base ?? EditingProject.removingKeyframes(of: effect.id, from: current)
        let range = EditingProject.writtenRange(setup, of: clip)
        guard range.duration > .zero else { return nil }
        // With Between Frames, also the moments motion blur draws.
        let between = (effect.choice(.betweenFrames, as: BetweenFrames.self) ?? .auto)
            .offsets(shutter: clip.shutter, frame: timeline.frameDuration.seconds)
        let sampling = KeyframeSampling(clip: clip, range: range, frame: timeline.frameDuration, between: between)
        let (baseSamples, baseWidth) = base.flatValues(at: sampling.sources)
        guard baseWidth > 0 else { return nil }
        let count = sampling.sources.count
        // With one component chosen, `value` and the result are numbers.
        let component = setup.component.flatMap { $0 < baseWidth ? $0 : nil }
        let width = component == nil ? baseWidth : 1
        let value: [Double] = component.map { c in (0..<count).map { baseSamples[$0 * baseWidth + c] } } ?? baseSamples
        func input(_ kind: ControlKind) -> [Double] {
            guard let control = effect.control(kind) else { return Array(repeating: 0, count: count) }
            return sampling.sources.map { control.number.value(at: $0).values.first ?? 0 }
        }
        let frame = timeline.frameDuration.seconds
        let tables: [(String, Int, [Double])] = [
            ("time", 1, sampling.timelineTimes.map(\.seconds)),
            ("t", 1, sampling.elapsed),
            ("frame", 1, sampling.timelineTimes.map { ($0.seconds / frame).rounded() }),
            ("source_time", 1, sampling.sourceSeconds),
            ("value", width, value),
            ("a", 1, input(.inputA)), ("b", 1, input(.inputB)), ("c", 1, input(.inputC)), ("d", 1, input(.inputD)),
        ]
        let code = effect.expression ?? ""
        let key = String(settingsKey(of: effect, setup: setup, timeline: timeline, clip: clip, layer: found.layer.id), radix: 16)
        let input = ExpressionInput(
            shape: ExpressionInput.Shape(key: key, code: code, count: count, width: width, tables: tables.map(\.0), sizes: tables.map(\.1)),
            tables: tables.flatMap { $0.2 }
        )
        var request = HelperRequest(kind: .expression, code: code)
        request.timeLimit = timeLimit
        request.payload = PythonHelper.payload(input.tables)
        request.fields = [
            "count": .number(Double(count)),
            "width": .number(Double(width)),
            "tables": .array(tables.map { [.string($0.0), .number(Double($0.1))] }),
            "fps": .number(timeline.frameRate),
            "duration": .number(sampling.elapsed.last ?? 0),
            "seed": .number(effect.control(.seed)?.number.value.values.first ?? 1),
            "effect": JSONValue(effect.id),
        ]
        request.context = [
            "timeline": JSONValue(timeline.id), "clip": JSONValue(clip.id), "layer": JSONValue(found.layer.id),
        ]
        // Running only the samples that changed (see docs/python-scripting.md,
        // "Doing less work"): the helper may call the code only for the
        // samples whose rows differ from the last run, when that run worked,
        // nothing it read has changed since and it had this run's shape (the
        // same code, key, count, width and tables; the key is what else the
        // samples depend on). Each run is a helper of its own that remembers
        // nothing, so the last run's tables and samples are sent after this
        // run's (D9).
        let last = ExpressionResults.shared.results(for: effect.id).last
        let reused = last.flatMap { last -> ExpressionResult? in
            guard last.failure == nil, last.input?.shape == input.shape,
                  last.values.count == count * width,
                  last.readsPrint == project.readsPrint(last.reads) else { return nil }
            return last
        }
        if let reused, let lastInput = reused.input {
            request.payload.append(PythonHelper.payload(lastInput.tables + reused.values))
        }
        request.fields["reuse"] = .bool(reused != nil)
        request.fields["key"] = .string(key)
        let ownTarget: KeyframingRead = switch target {
        case .volume: KeyframingRead(timeline: timeline.id, kind: .volume(clip: clip.id))
        case .control(let effectID, let controlID):
            KeyframingRead(timeline: timeline.id, kind: .control(clip: clip.id, effect: effectID, control: controlID))
        }
        return Prepared(
            request: request, times: sampling.sources, timelineTimes: sampling.timelineTimes, width: width, effect: effect, clip: clip, timeline: timeline,
            base: base, ownTarget: ownTarget, reused: reused, input: input
        )
    }
}

// MARK: - Following a held drag

extension ProjectState {
    /// Writes the keyframes of the expressions whose results fit the drag
    /// held aside (`held`) into it, so the viewer, which draws from it,
    /// follows an expression while something it reads is dragged (see
    /// docs/python-scripting.md, "Arriving"). The project itself isn't
    /// touched: the drag's last step is committed when it ends, and the
    /// edit that commits it finds the result already made. Written as what
    /// follows from an edit (`writeDerived`), not as an edit by hand of the
    /// keyframes an expression makes. Returns whether anything changed.
    @discardableResult
    func applyExpressionResultsWhileHeld() -> Bool {
        guard isHolding, var held = self.held, held.applyExpressionResults() else { return false }
        writeDerived { hold { value = held } }
        return true
    }
}
