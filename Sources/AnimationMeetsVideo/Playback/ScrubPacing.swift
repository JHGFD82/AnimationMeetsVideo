import Foundation

/// The clock scrubbing is paced by and rests on: when each move was asked
/// for, in seconds that only go forward, and the waits for the moves to
/// rest. The app's is the continuous clock; a test's moves only when the
/// test moves it, so its pace doesn't depend on how busy the Mac is.
struct PaceClock: Sendable {
    let now: @Sendable () -> Double
    let sleep: @Sendable (Duration) async throws -> Void

    init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let start = clock.now
        now = {
            let since = start.duration(to: clock.now).components
            return Double(since.seconds) + Double(since.attoseconds) * 1e-18
        }
        sleep = { try await clock.sleep(for: $0) }
    }
}

/// How the paused seek queue seeks (see docs/rendering.md, "Rough, then
/// exact"): exactly while the playhead or the skimmer moves no faster than
/// a little over normal speed, and roughly while it moves faster, within
/// a tolerance the player can use to land on a keyframe of long-GOP
/// footage instead of decoding a whole group of pictures for every step.
/// Once the moves stop, the queue lands exactly where they stopped
/// (`rest` later).
///
/// Times are seconds: the moves' targets on the timeline, and when each
/// was asked for on a clock that only goes forward.
struct ScrubPacing {
    /// How much faster than normal speed the moves must go to seek
    /// roughly. Holding an arrow key steps about at normal speed, and
    /// dragging slowly to find a frame is slower, so both stay exact.
    static let fastSpeed = 2.0
    /// How long the moves are looked back over, and how long they must
    /// stop for before the queue lands exactly.
    static let rest: Duration = .milliseconds(100)
    static let restSeconds = 0.1
    /// A rough seek may land as far off as the moves go in this long, so
    /// the picture is no further behind than the pointer was a moment ago.
    static let lead = 0.1
    /// The most a rough seek may land off, however fast the moves.
    static let farthest = 2.0

    /// The moves asked for within the last `restSeconds`, oldest first.
    private var recent: [(target: Double, at: Double)] = []

    /// Notes a move to `target`, asked for at `now`, and gives how far off
    /// its seek may land, either way: 0 for exactly.
    ///
    /// A move after a rest seeks exactly: a click in the ruler or a step
    /// is one seek, which may as well be the right one. Moves in a row are
    /// as fast as the distance they covered over the time they took,
    /// counting each back and forth.
    mutating func tolerance(forMoveTo target: Double, at now: Double) -> Double {
        recent.removeAll { now - $0.at > Self.restSeconds }
        recent.append((target, now))
        guard recent.count > 1, let first = recent.first else { return 0 }
        var covered = 0.0
        for i in 1..<recent.count { covered += abs(recent[i].target - recent[i - 1].target) }
        // Moves a moment apart are taken as a screen refresh apart.
        let took = max(now - first.at, 1.0 / 120)
        let speed = covered / took
        guard speed > Self.fastSpeed else { return 0 }
        return min(speed * Self.lead, Self.farthest)
    }

    /// Forgets the moves, for when the player is sent somewhere else
    /// (another timeline, another item) and the next move starts afresh.
    mutating func reset() {
        recent.removeAll()
    }
}
