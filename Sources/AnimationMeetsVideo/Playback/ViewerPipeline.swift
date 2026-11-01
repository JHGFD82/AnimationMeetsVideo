import AVFoundation
import CoreMedia
import Observation

/// What the viewer is asked to show: the project as it draws it (`project`,
/// which Show Up to Here may cut short), the real one renders are planned
/// from, and the timeline.
struct ViewerSource {
    var project: EditingProject
    var renderProject: EditingProject
    var timelineID: UUID
    /// Show Up to Here is on: the picture isn't the finished timeline, so
    /// nothing plays from renders or is planned for them.
    var isPartial = false
    /// Assets whose file is missing; their clips play as gaps.
    var offlineMedia: Set<UUID> = []
    /// A step of a value drag held to one side of the project, which the
    /// viewer shows but the renderer's plan doesn't follow.
    var isHeld = false

    var timeline: Timeline? { project.timeline(id: timelineID) }
    /// Whether the viewer plays stretches from their renders. Not with a
    /// preview background: renders are drawn over black, for export, and
    /// would hide it. They are still planned and made for export.
    var playsRenders: Bool { !isPartial && timeline?.previewBackground == nil }
    var hasContent: Bool { timeline?.layers.contains { !$0.clips.isEmpty } ?? false }
}

/// The player the pipeline drives; `PlaybackModel` in the app.
@MainActor
protocol ViewerPlayer: AnyObject {
    var isPlaying: Bool { get }
    /// Where a paused swap resumes: the player's time, or the playhead's
    /// when the player has none (no item yet, or one let go). Always a
    /// number.
    var resumeTime: CMTime { get }
    /// Draws the project's values with the item as it is (see
    /// `PlaybackModel.showValues`).
    func showValues(_ clips: [UUID: TimelineClip])
    /// Keeps the project's values for the frames drawn from now on, without
    /// drawing one: the item is about to be replaced.
    func storeValues(_ clips: [UUID: TimelineClip])
    @discardableResult func playWithoutRenders() -> Bool
    /// Puts an item of `composed` in the player at `time` (paused) or where
    /// playing has reached, returning once its frame shows.
    @discardableResult
    func swap(to composed: ComposedTimeline, key: StructureKey, frameRate: Double, at time: CMTime) async -> Bool
    func clearItem()
}

/// The background renderer, as the pipeline tells it what the viewer built
/// and when to wait; `RenderScheduler` in the app.
@MainActor
protocol ViewerRenderer: AnyObject {
    var cache: RenderCache? { get }
    func update(project: EditingProject, timelineID: UUID, segments: [RenderSegment])
    func setInteracting(_ interacting: Bool)
    func setPlaying(_ playing: Bool)
    func noteActivity()
}

extension RenderScheduler: ViewerRenderer {}

/// Turns what the editor shows into the viewer's player items, outside any
/// view, so it can be tested on its own.
///
/// Everything arrives as an `Event`, consumed in order by one loop. Edits
/// of values alone (`StructureKey` unchanged) are drawn with the item as it
/// is and never build. A change of structure asks for a build of the
/// latest project: there is one request, which a newer edit overwrites
/// (it is never queued behind), and one build at a time. A build is never
/// cancelled because a newer edit arrived, so something always finishes; a
/// result whose key is no longer the latest is dropped and the latest is
/// built, so a burst of edits builds at most twice, the first and the last.
/// A short pause (`coalescing`) lets a burst land before the first build
/// starts; it only saves work, nothing depends on it.
///
/// A build is swapped in only while no value gesture is under way, and a
/// rebuild for renders alone only while paused; the player keeps its
/// picture until the new item's frame is there (`ViewerPlayer.swap`).
/// The renderer is told of each build applied, and waits from a gesture's
/// start until what follows its end is done.
@MainActor
@Observable
final class ViewerPipeline {
    enum Event {
        case structureChanged(StructureKey?, ViewerSource)
        case valuesChanged(ViewerSource)
        case gestureBegan, gestureEnded
        case renderFinished, packageURLChanged, drawingOptionsChanged, offlineMediaChanged
        case playbackStateChanged(isPlaying: Bool)
        /// Another timeline is shown, from `at`, or the viewer first appears.
        case timelineChanged(ViewerSource, at: CMTime)
        case appeared(ViewerSource, at: CMTime)
    }

    enum Phase: Equatable { case idle, building(Int), ready }

    typealias Builder = @MainActor (ViewerSource, RenderCache?) async throws -> ComposedTimeline

    /// Why the timeline couldn't be built, for the viewer to say.
    private(set) var buildError: String?
    @ObservationIgnored private(set) var phase: Phase = .idle
    /// How many builds were started and swapped in, for tests.
    @ObservationIgnored private(set) var buildsStarted = 0
    @ObservationIgnored private(set) var swapsApplied = 0
    /// How many events were sent and how many handled, for tests to wait
    /// until every event sent has been.
    @ObservationIgnored private(set) var eventsSent = 0
    @ObservationIgnored private(set) var eventsHandled = 0

    private struct Request {
        var generation: Int
        /// Nil for a timeline with nothing to play.
        var key: StructureKey?
        var source: ViewerSource
        /// Off, it only makes the renderer's plan again, for values edited
        /// since; the item draws them as it is.
        var swapsItem = true
        /// Swapped in only while paused: a rebuild for renders alone, which
        /// isn't worth holding the picture for while playing.
        var waitsForPause = false
        /// Where a paused swap resumes, for a timeline shown afresh; the
        /// player's time otherwise.
        var resumeAt: CMTime?
    }

    private struct Built {
        var request: Request
        var composed: ComposedTimeline
    }

    @ObservationIgnored private let player: ViewerPlayer
    @ObservationIgnored private let renderer: ViewerRenderer?
    @ObservationIgnored private let build: Builder
    @ObservationIgnored private let coalescing: Duration
    @ObservationIgnored private let planDelay: Duration
    /// What `coalescing` and `planDelay` are waited on: a test's clock
    /// moves only when the test says.
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let continuation: AsyncStream<Event>.Continuation
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// The structure last shown (`show`), to tell an edit of values from one
    /// of structure as it is sent; `.some(nil)` for an empty timeline.
    @ObservationIgnored private var shownKey: StructureKey??
    /// What was last shown, to skip an edit the picture doesn't show (a
    /// rename, a volume) and notice files gone or back.
    @ObservationIgnored private var shownComposition: CompositionKey?
    @ObservationIgnored private var shownOffline: Set<UUID> = []
    /// What the editor's pipeline follows of its player, its renderer and
    /// the app, so the editor needn't (`follow`).
    @ObservationIgnored private var followers: [AnyObject] = []
    @ObservationIgnored private var notificationTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var latest: Request?
    @ObservationIgnored private var generation = 0
    /// The newest generation whose build was started.
    @ObservationIgnored private var startedGeneration = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    /// Built and current, waiting to be applied.
    @ObservationIgnored private var ready: Built?
    @ObservationIgnored private var isSwapping = false
    @ObservationIgnored private var isGesturing = false
    @ObservationIgnored private var isPlaying = false
    /// A render finished while playing; its rebuild waits for a pause.
    @ObservationIgnored private var rebuildsWhenPaused = false
    /// Values were edited since the renderer's plan was made.
    @ObservationIgnored private var planStale = false
    @ObservationIgnored private var rendererHeld = false

    init(
        player: ViewerPlayer, renderer: ViewerRenderer?, coalescing: Duration = .milliseconds(75),
        planDelay: Duration = .milliseconds(300), clock: any Clock<Duration> = ContinuousClock(),
        build: @escaping Builder
    ) {
        self.player = player
        self.renderer = renderer
        self.coalescing = coalescing
        self.planDelay = planDelay
        self.clock = clock
        self.build = build
        isPlaying = player.isPlaying
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        loop = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    /// The editor's pipeline: `playback`'s items, built for the viewer. It
    /// follows on its own what changes them besides the project: renders
    /// finishing, the package, motion blur in the viewer, play and pause,
    /// and value gestures.
    convenience init(playback: PlaybackModel, renderer: RenderScheduler?) {
        self.init(player: playback, renderer: renderer) { [weak playback] source, cache in
            try await CompositionExporter.buildComposedTimeline(
                for: source.project, timelineID: source.timelineID, forPreview: true, meter: playback?.meter,
                options: playback?.drawingOptions, cache: source.playsRenders ? cache : nil
            )
        }
        follow({ playback.isPlaying }) { $0.send(.playbackStateChanged(isPlaying: $1)) }
        follow({ playback.motionBlurInPreview }) { pipeline, _ in pipeline.send(.drawingOptionsChanged) }
        if let renderer {
            follow({ renderer.finishedCount }) { pipeline, _ in pipeline.send(.renderFinished) }
            follow({ renderer.packageURL }) { pipeline, _ in pipeline.send(.packageURLChanged) }
        }
        for (name, event) in [(Notification.Name.valueGestureDidBegin, Event.gestureBegan), (.valueGestureDidEnd, .gestureEnded)] {
            notificationTasks.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    self?.send(event)
                }
            })
        }
    }

    deinit {
        continuation.finish()
        for task in notificationTasks { task.cancel() }
    }

    /// Sends what `changed` makes of each new value of `read`.
    private func follow<Value: Equatable>(_ read: @escaping () -> Value, _ changed: @escaping (ViewerPipeline, Value) -> Void) {
        followers.append(Follower(read: read) { [weak self] value in
            guard let self else { return }
            changed(self, value)
        })
    }

    func send(_ event: Event) {
        switch event {
        case .structureChanged(let key, _): shownKey = .some(key)
        case .timelineChanged(let source, _), .appeared(let source, _):
            shownKey = .some(Self.key(of: source))
            shownComposition = source.hasContent ? CompositionKey(project: source.project) : nil
            shownOffline = source.offlineMedia
        default: break
        }
        eventsSent += 1
        continuation.yield(event)
    }

    /// Shows `source`: an edit of its values, or of its structure, as its
    /// `StructureKey` says.
    func show(_ source: ViewerSource) {
        let composition = source.hasContent ? CompositionKey(project: source.project) : nil
        let offlineChanged = source.offlineMedia != shownOffline
        shownOffline = source.offlineMedia
        defer { if offlineChanged { send(.offlineMediaChanged) } }
        // Nothing the picture shows changed.
        if !source.isHeld, let composition, composition == shownComposition, shownKey != nil { return }
        if !source.isHeld { shownComposition = composition }
        let key = composition.map(StructureKey.init(composition:))
        if let key, shownKey == .some(key) {
            send(.valuesChanged(source))
        } else if !source.isHeld {
            send(.structureChanged(key, source))
        }
    }

    /// Shows a step of a held value drag, if it changes only values: false
    /// when it changes the structure, which the drag then writes to the
    /// project instead (`ProjectState.letGo`).
    func showHeld(_ source: ViewerSource) -> Bool {
        var source = source
        source.isHeld = true
        guard let key = Self.key(of: source), shownKey == .some(key) else { return false }
        send(.valuesChanged(source))
        return true
    }

    /// A held drag ended: the picture goes back to `source`'s values, the
    /// project's, whether the drag's last value went into it or, cancelled,
    /// none did.
    func endHeld(_ source: ViewerSource) {
        var source = source
        source.isHeld = true
        guard let key = Self.key(of: source), shownKey == .some(key) else { return }
        send(.valuesChanged(source))
    }

    private static func key(of source: ViewerSource) -> StructureKey? {
        source.hasContent ? StructureKey(project: source.project) : nil
    }

    // MARK: Events

    private func handle(_ event: Event) {
        defer { eventsHandled += 1 }
        switch event {
        case .structureChanged(let key, let source):
            renderer?.noteActivity()
            player.storeValues(source.project.clipsByID)
            request(key: key, source: source)
        case .valuesChanged(let source):
            renderer?.noteActivity()
            player.showValues(source.project.clipsByID)
            guard !source.isHeld, var latest else { return }
            if latest.generation > startedGeneration {
                // Not built yet: it is built with these values.
                latest.source = source
                self.latest = latest
            } else {
                latest.source = source
                self.latest = latest
                planStale = true
                if !isGesturing { schedulePlan(after: planDelay) }
            }
        case .gestureBegan:
            isGesturing = true
            rendererHeld = true
            renderer?.setInteracting(true)
            player.playWithoutRenders()
        case .gestureEnded:
            isGesturing = false
            renderer?.noteActivity()
            if planStale, ready == nil { schedulePlan(after: .zero) }
            advance()
        case .renderFinished:
            // A viewer that doesn't play renders has nothing to take up.
            if let latest, !latest.source.playsRenders { return }
            if isPlaying {
                rebuildsWhenPaused = true
            } else {
                rebuild(waitsForPause: true)
            }
        case .packageURLChanged, .drawingOptionsChanged, .offlineMediaChanged:
            rebuild()
        case .playbackStateChanged(let playing):
            isPlaying = playing
            renderer?.setPlaying(playing)
            if !playing, rebuildsWhenPaused {
                rebuildsWhenPaused = false
                rebuild(waitsForPause: true)
            }
            advance()
        case .timelineChanged(let source, let time), .appeared(let source, let time):
            // What was being built for the timeline before is no use:
            // stopped, and dropped when it stops.
            worker?.cancel()
            worker = nil
            debounce?.cancel()
            debounce = nil
            ready = nil
            rebuildsWhenPaused = false
            planStale = false
            player.storeValues(source.project.clipsByID)
            request(key: Self.key(of: source), source: source, resumeAt: time, coalesces: false)
        }
    }

    /// Asks for `source` to be built, replacing what was asked before.
    private func request(key: StructureKey?, source: ViewerSource, resumeAt: CMTime? = nil, coalesces: Bool = true) {
        generation += 1
        latest = Request(generation: generation, key: key, source: source, resumeAt: resumeAt)
        planStale = false
        guard key != nil else {
            // Nothing to play: the item goes, and the viewer keeps its
            // picture under what says so.
            debounce?.cancel()
            debounce = nil
            ready = nil
            startedGeneration = generation
            player.clearItem()
            buildError = nil
            renderer?.update(project: source.renderProject, timelineID: source.timelineID, segments: [])
            phase = .idle
            advance()
            return
        }
        if coalesces {
            schedule(after: coalescing)
        } else {
            advance()
        }
    }

    /// Builds the latest again as it is: renders, the package or the
    /// drawing options changed what it is built from.
    private func rebuild(waitsForPause: Bool = false) {
        guard let current = latest, current.key != nil else { return }
        generation += 1
        var request = current
        request.generation = generation
        request.swapsItem = true
        request.resumeAt = nil
        // A rebuild for some other reason under way still swaps while playing.
        request.waitsForPause = waitsForPause && (current.generation <= startedGeneration || current.waitsForPause)
        latest = request
        schedule(after: coalescing)
    }

    /// Makes the renderer's plan again for values edited since, without
    /// swapping the item, once edits have paused for `delay`.
    private func schedulePlan(after delay: Duration) {
        guard let current = latest, current.key != nil else { return }
        if current.generation > startedGeneration {
            // A build is coming anyway, and plans too.
            return
        }
        generation += 1
        var request = current
        request.generation = generation
        request.swapsItem = false
        request.waitsForPause = false
        request.resumeAt = nil
        latest = request
        schedule(after: delay)
    }

    private func schedule(after delay: Duration) {
        debounce?.cancel()
        guard delay > .zero else {
            debounce = nil
            advance()
            return
        }
        debounce = Task { [weak self, clock] in
            try? await clock.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounce = nil
            self.advance()
        }
    }

    // MARK: Building and swapping

    /// Does what can be done now: applies a build that is current and may
    /// be applied, starts the latest build, or lets the renderer go.
    private func advance() {
        if let built = ready, !isSwapping {
            if built.request.key != latest?.key {
                ready = nil
            } else if mayApply(built) {
                apply(built)
            }
        }
        if worker == nil, debounce == nil, let latest, latest.key != nil, latest.generation > startedGeneration {
            start(latest)
        }
        releaseRendererIfDone()
    }

    private func mayApply(_ built: Built) -> Bool {
        guard built.request.swapsItem else { return true }
        if isGesturing { return false }
        if built.request.waitsForPause, isPlaying { return false }
        return true
    }

    private func start(_ request: Request) {
        startedGeneration = request.generation
        buildsStarted += 1
        // Every build plans the renderer's pieces from its values.
        planStale = false
        phase = .building(request.generation)
        let cache = renderer?.cache
        let build = build
        worker = Task { [weak self] in
            do {
                let composed = try await build(request.source, cache)
                guard !Task.isCancelled else { return }
                self?.finished(request, with: .success(composed))
            } catch {
                guard !Task.isCancelled else { return }
                self?.finished(request, with: .failure(error))
            }
        }
    }

    private func finished(_ request: Request, with result: Result<ComposedTimeline, Error>) {
        worker = nil
        // Applied only while it is what is asked for; otherwise the latest
        // is built next.
        if request.key == latest?.key {
            switch result {
            case .success(let composed):
                // A newer request of the same structure (values, renders)
                // still gets its own build; this one is good to show now.
                if let ready, ready.request.generation > request.generation {
                } else {
                    ready = Built(request: request, composed: composed)
                }
            case .failure(let error):
                if error is CancellationError {
                } else if let compositionError = error as? CompositionError, case .emptyTimeline = compositionError {
                    player.clearItem()
                    buildError = nil
                } else {
                    buildError = error.localizedDescription
                }
            }
        }
        advance()
    }

    private func apply(_ built: Built) {
        ready = nil
        let request = built.request
        let source = request.source
        renderer?.update(
            project: source.renderProject, timelineID: source.timelineID,
            segments: source.isPartial ? [] : built.composed.segments
        )
        guard request.swapsItem else {
            buildError = nil
            phase = .ready
            advance()
            return
        }
        isSwapping = true
        let frameRate = source.timeline?.frameRate ?? 24
        let time = request.resumeAt ?? player.resumeTime
        Task { [weak self, player] in
            await player.swap(to: built.composed, key: request.key!, frameRate: frameRate, at: time)
            guard let self else { return }
            self.isSwapping = false
            self.swapsApplied += 1
            self.buildError = nil
            self.phase = .ready
            self.advance()
        }
    }

    /// The renderer waits from a gesture's start until nothing it started
    /// is left to build or swap.
    private func releaseRendererIfDone() {
        guard rendererHeld, !isGesturing, worker == nil, debounce == nil, ready == nil, !isSwapping else { return }
        if let latest, latest.key != nil, latest.generation > startedGeneration { return }
        rendererHeld = false
        renderer?.setInteracting(false)
    }
}

extension PlaybackModel: ViewerPlayer {
    /// Without an item the player's time is invalid (its seconds NaN), and
    /// an item swapped in at it was seeked nowhere and never drew; the
    /// playhead is where it should be then.
    var resumeTime: CMTime {
        let time = player.currentTime()
        guard player.currentItem != nil, time.isNumeric else { return currentTime }
        return time
    }

    func storeValues(_ clips: [UUID: TimelineClip]) {
        liveValues.clips = clips
    }

    func swap(to composed: ComposedTimeline, key: StructureKey, frameRate: Double, at time: CMTime) async -> Bool {
        let item = AVPlayerItem(asset: composed.composition)
        prepare(item, with: composed, key: key, frameRate: frameRate)
        return await swap(to: item, at: time, playing: isPlaying)
    }
}

/// Calls `changed` with each new value of `read`, an observable value, on
/// the main actor.
@MainActor
private final class Follower<Value: Equatable> {
    private let read: () -> Value
    private let changed: (Value) -> Void
    private var last: Value

    init(read: @escaping () -> Value, changed: @escaping (Value) -> Void) {
        self.read = read
        self.changed = changed
        last = read()
        track()
    }

    private func track() {
        withObservationTracking { _ = read() } onChange: { [weak self] in
            Task { @MainActor in self?.fire() }
        }
    }

    private func fire() {
        let now = read()
        track()
        guard now != last else { return }
        last = now
        changed(now)
    }
}
