import Foundation
import Synchronization

/// When a project, or a timeline in it, last changed: a number from one
/// count shared by every project in the app, so a number is never given
/// out twice. Two values with the same nonzero stamp are the same edit, and
/// so are equal, which views compare instead of the values themselves.
///
/// A plain counter per project wouldn't do: undo brings back an older
/// project, with its older count, and the next edit would give a
/// different project the count the undone one had.
///
/// Zero is a value never stamped (made in code, not edited), which says
/// nothing about what it equals.
///
/// Not part of what the value is: equal whatever their stamps, so values
/// compare, save and test as before.
struct EditStamp: Equatable {
    private(set) var count: UInt64 = 0

    private static let counter = Atomic<UInt64>(0)

    /// A number no stamp has had.
    static func next() -> UInt64 {
        counter.add(1, ordering: .relaxed).newValue
    }

    init() {}

    init(count: UInt64) {
        self.count = count
    }

    static func == (_: EditStamp, _: EditStamp) -> Bool { true }
}

extension EditingProject {
    /// Stamps the project as a new edit, and each of its timelines that
    /// isn't as it was in `previous` (all of them without one). See
    /// `editCount` and `Timeline.version`.
    mutating func stampEdit(since previous: EditingProject?) {
        let count = EditStamp.next()
        editCount = count
        var before: [UUID: Timeline] = [:]
        for timeline in previous?.timelines ?? [] where before[timeline.id] == nil {
            before[timeline.id] = timeline
        }
        for t in timelines.indices where before[timelines[t].id] != timelines[t] {
            timelines[t].version = count
        }
    }
}
