import CoreMedia
import Foundation
import Observation

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
                failure = ExpressionFailure(summary: error.summary, time: error.time)
                // A mistake in the helper, not the code: the note has one
                // line, so the whole traceback goes to the log to report.
                if error.line == nil, !error.wasStopped { NSLog("Expression run failed in the helper:\n\(error.traceback)") }
            case .finished: failure = ExpressionFailure(summary: "The expression gave no samples.", time: nil)
            }
        } catch {
            failure = ExpressionFailure(summary: error.localizedDescription, time: nil)
        }
        let reads = await bridge.reads
        let expected = request.times.count * request.width
        if failure == nil, values.count != expected {
            failure = ExpressionFailure(summary: "The expression gave \(values.count) numbers, not \(expected).", time: nil)
        }
        let print = project.expressionPrint(of: request.effect, in: request.clip, of: request.timeline, base: request.base, reads: reads)
        return ExpressionResult(
            times: failure == nil ? request.times : [], values: failure == nil ? values : [], width: request.width,
            reads: reads, failure: failure, print: print
        )
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
        let sampling = KeyframeSampling(clip: clip, range: range, frame: timeline.frameDuration)
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
        var request = HelperRequest(kind: .expression, code: effect.expression ?? "")
        request.timeLimit = timeLimit
        request.payload = PythonHelper.payload(tables.flatMap { $0.2 })
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
        let ownTarget: KeyframingRead = switch target {
        case .volume: KeyframingRead(timeline: timeline.id, kind: .volume(clip: clip.id))
        case .control(let effectID, let controlID):
            KeyframingRead(timeline: timeline.id, kind: .control(clip: clip.id, effect: effectID, control: controlID))
        }
        return Prepared(
            request: request, times: sampling.sources, timelineTimes: sampling.timelineTimes, width: width, effect: effect, clip: clip, timeline: timeline,
            base: base, ownTarget: ownTarget
        )
    }
}
