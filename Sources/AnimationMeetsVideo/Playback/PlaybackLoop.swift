import AVFoundation
import CoreMedia
import Observation

/// The loop region of the timeline a player shows, and the jump back at
/// its end. Owned by `PlaybackModel` (`playback.loop`), so every view that
/// plays through that player (the main timeline, the Motion Designer, the
/// graph editors) shows and loops the same region. See
/// docs/loop-region.md, "Playback".
///
/// Players in other windows on the same timeline (a timeline window, the
/// external display's own editor) show the same region: each player's
/// loop joins the project's `LoopRegions`, and a change made through one
/// is applied to the others (`apply(_:publishing:)`).
///
/// The end is watched with a boundary observer on the player, only while
/// it plays and a region is active, so no time observer runs the rest of
/// the time (as `BeatMatchSession.refreshLoop` does). The observer
/// belongs to the player, not its item, so an item swapped in while
/// playing keeps looping.
@MainActor
@Observable
final class PlaybackLoop {
    private(set) var region: LoopRegion?
    /// The whole of the timeline shown.
    private(set) var timelineRange: CMTimeRange = .zero
    /// What a designer narrows playing to, or nil for the whole timeline.
    private(set) var window: CMTimeRange?
    private(set) var frameDuration = CMTime(value: 1, timescale: 24)
    /// A take is recording over the playing timeline: it plays straight
    /// on, so the take lines up with it.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { refresh() } }
    }

    /// Turns the player back to a time while it plays and plays on.
    /// `PlaybackModel` sets it to its `jump(to:)`.
    @ObservationIgnored var jump: (CMTime) -> Void = { _ in }
    /// Where the player is now. Tests stand in for the player with it.
    @ObservationIgnored var playerTime: () -> CMTime

    /// Whether the player plays, as `playingChanged` was last told.
    @ObservationIgnored private(set) var isPlaying = false
    /// The stretch whose end is watched, while one is; set only by
    /// `refresh`, read by tests.
    @ObservationIgnored private(set) var watchedRange: CMTimeRange?
    @ObservationIgnored private var observer: Any?
    private let player: AVPlayer
    /// The timeline shown, as `show` was last told; nil before, or in a
    /// test that gives none.
    @ObservationIgnored private(set) var timelineID: UUID?
    /// The regions shared by the project's players, which this one keeps
    /// in step with; nil for a player on its own.
    @ObservationIgnored var shared: LoopRegions? {
        didSet {
            guard shared !== oldValue else { return }
            oldValue?.leave(self)
            shared?.join(self)
        }
    }

    /// How far short of the item's end a range running to it is watched:
    /// at the end itself the player pauses, and that pause would take the
    /// watch down before it could jump.
    static let endMargin = CMTime(value: 20, timescale: 1000)

    init(player: AVPlayer) {
        self.player = player
        playerTime = { [weak player] in player?.currentTime() ?? .invalid }
    }

    isolated deinit {
        if let observer { player.removeTimeObserver(observer) }
    }

    /// What may play here: the whole timeline, cut to a designer's window
    /// while one narrows it.
    var limits: CMTimeRange {
        guard let window else { return timelineRange }
        return CMTimeRangeGetIntersection(timelineRange, otherRange: window)
    }

    /// Whether the region is there and on, whatever the limits leave of
    /// it. What the loop button and the menu show.
    var isOn: Bool { region?.isOn ?? false }

    /// The stretch that repeats now: the region cut to `limits`, when it
    /// is on, not suspended, and still at least the minimum long.
    var activeRange: CMTimeRange? {
        guard let region, region.isOn, !isSuspended else { return nil }
        let limits = limits
        guard limits.start.isNumeric, limits.end.isNumeric else { return nil }
        let start = CMTimeMaximum(region.start, limits.start)
        let end = CMTimeMinimum(region.end, limits.end)
        guard CMTimeSubtract(end, start) >= LoopRegion.minimumDuration(frameDuration: frameDuration) else { return nil }
        return CMTimeRange(start: start, end: end)
    }

    // MARK: What is shown

    /// Another timeline is shown, from 0 to its `duration`: its region,
    /// with no jump. With `shared` and the timeline's ID, that is the
    /// region the project's players have for it, if any has shown it;
    /// `region` (where this window left it) only seeds it the first time.
    /// A region whose end isn't after its start is dropped. A designer's
    /// window is kept: the designer gives it back itself.
    func show(_ region: LoopRegion?, duration: CMTime, frameDuration: CMTime, timelineID: UUID? = nil) {
        self.timelineID = timelineID
        let saved = region.flatMap(Self.valid)
        if let shared, let timelineID {
            self.region = shared.region(of: timelineID, seeding: saved)
        } else {
            self.region = saved
        }
        timelineRange = CMTimeRange(start: .zero, end: duration)
        self.frameDuration = frameDuration
        refresh()
    }

    /// The timeline's length or frame rate changed. The region stays where
    /// it is: `activeRange` cuts it to the new length.
    func update(duration: CMTime, frameDuration: CMTime) {
        let range = CMTimeRange(start: .zero, end: duration)
        guard range != timelineRange || frameDuration != self.frameDuration else { return }
        timelineRange = range
        self.frameDuration = frameDuration
        refresh()
    }

    /// A designer plays only `window` of the timeline; nil gives the
    /// whole timeline back.
    func narrow(to window: CMTimeRange?) {
        guard window != self.window else { return }
        self.window = window
        refresh()
    }

    // MARK: Changing the region

    /// A change to the region, made here or in another window's player on
    /// the same timeline.
    enum Change: Equatable {
        case draw(LoopRegion)
        case adjust(LoopRegion)
        case setOn(Bool)
        case remove
    }

    /// A region drawn, in place of any there was. It is on, and while
    /// playing the player goes to its start.
    func draw(_ region: LoopRegion) { apply(.draw(region)) }

    /// The region resized, moved or recolored. While playing, the player
    /// goes to its start only when it is outside the new range; a change
    /// that leaves the range alone never moves it.
    func adjust(to region: LoopRegion) { apply(.adjust(region)) }

    func remove() { apply(.remove) }

    /// Turns the region on or off. Turning it on while playing takes the
    /// player to its start; turning it off lets playing run on.
    func toggle() {
        guard let region else { return }
        apply(.setOn(!region.isOn))
    }

    /// Turns the region on or off, when there is one and it isn't
    /// already, as `toggle` does. Asking twice does nothing the second
    /// time, so two views keeping the same rule can both ask.
    func setOn(_ on: Bool) { apply(.setOn(on)) }

    /// Makes `change`, with what it does to a playing player, and unless
    /// it came from another player (`publishing` false), hands it to the
    /// others on this timeline. A change that does nothing goes nowhere.
    func apply(_ change: Change, publishing: Bool = true) {
        let before = activeRange
        switch change {
        case .draw(let region):
            guard var drawn = Self.valid(region) else { return }
            drawn.isOn = true
            self.region = drawn
            refresh()
            if isPlaying, let active = activeRange { jump(active.start) }
        case .adjust(let region):
            guard let adjusted = Self.valid(region), adjusted != self.region else { return }
            self.region = adjusted
            refresh()
            if isPlaying, let after = activeRange, after != before {
                let now = playerTime()
                if !now.isNumeric || now < after.start || now >= after.end { jump(after.start) }
            }
        case .setOn(let on):
            guard var toggled = region, toggled.isOn != on else { return }
            toggled.isOn = on
            region = toggled
            refresh()
            if on, isPlaying, let active = activeRange { jump(active.start) }
        case .remove:
            guard region != nil else { return }
            region = nil
            refresh()
        }
        if publishing, let shared, let timelineID {
            shared.changed(change, to: region, in: timelineID, by: self)
        }
    }

    // MARK: Playing

    /// The player started or stopped. Not private, so tests can drive the
    /// loop without playing sound.
    func playingChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        refresh()
    }

    /// Where play should start from `time` for the loop: the region's
    /// start when `time` is before it or within a frame of its end, `time`
    /// itself inside it, nil with no active region.
    func playStart(from time: CMTime) -> CMTime? {
        guard let active = activeRange else { return nil }
        let lastStart = CMTimeSubtract(active.end, frameDuration)
        if !time.isNumeric || time < active.start || time > lastStart { return active.start }
        return time
    }

    /// Watches the end of the active range while playing, and nothing
    /// otherwise. Works the range out when what it depends on changes,
    /// rather than as the timeline plays.
    private func refresh() {
        var watched = isPlaying ? activeRange : nil
        if let range = watched {
            let end = CMTimeMinimum(range.end, CMTimeSubtract(itemEnd, Self.endMargin))
            watched = end > range.start ? CMTimeRange(start: range.start, end: end) : nil
        }
        guard watched != watchedRange else { return }
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        watchedRange = watched
        guard let watched else { return }
        observer = player.addBoundaryTimeObserver(forTimes: [NSValue(time: watched.end)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let range = self.watchedRange else { return }
                self.jump(range.start)
            }
        }
    }

    /// Where the player's item ends: the timeline's end, or the item's if
    /// it is shorter.
    private var itemEnd: CMTime {
        let end = timelineRange.end
        guard let duration = player.currentItem?.duration, duration.isNumeric else { return end }
        return CMTimeMinimum(end, duration)
    }

    private static func valid(_ region: LoopRegion) -> LoopRegion? {
        region.start.isNumeric && region.end.isNumeric && region.end > region.start ? region : nil
    }
}
