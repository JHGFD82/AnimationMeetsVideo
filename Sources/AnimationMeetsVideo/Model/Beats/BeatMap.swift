import CoreMedia
import Foundation

/// The beats of a song as the person confirmed them in the beat match
/// panel, with each beat's place in its measure. It belongs to the asset,
/// like scene edits, so every clip of the song shares it. Times are in the
/// asset's original time, like trims, so an aligned replacement keeps its
/// beats. See docs/beat-matching.md.
///
/// Unlike detected beats this is the person's work: it is saved in the
/// project file, and changing it is an undoable edit.
struct BeatMap: Equatable, Sendable {
    /// In time order, never overlapping. A song of one tempo has one
    /// section covering all of it.
    var sections: [BeatSection] = []
    /// Whether the person chose to mark sections, rather than one tempo for
    /// the whole song. It only changes what the panel offers.
    var usesSections = false

    var isEmpty: Bool { sections.isEmpty }

    /// Whether any section has been filled, which is when the timeline shows
    /// these beats instead of the detected ones.
    var hasConfirmedBeats: Bool {
        sections.contains { $0.isConfirmed && !$0.beats.isEmpty }
    }

    /// Every confirmed beat, in time order.
    var confirmedBeats: [MappedBeat] {
        sections.filter(\.isConfirmed).flatMap(\.beats)
    }

    func section(id: UUID) -> BeatSection? {
        sections.first { $0.id == id }
    }

    /// Numbers the beats of every section. A section with a pinned beat
    /// counts out from it; one without carries on from the section before,
    /// in its own beats per measure.
    mutating func recountPositions() {
        var next = 1
        for index in sections.indices where sections[index].kind != .none {
            sections[index].recountPositions(firstPosition: next)
            if let last = sections[index].beats.last {
                next = last.position + 1
            }
        }
    }

    /// Changes one section in place; does nothing if it is gone.
    mutating func updateSection(_ id: UUID, _ change: (inout BeatSection) -> Void) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        change(&sections[index])
        sections[index].normalize()
    }
}

/// A stretch of the song with one way of finding its beats.
struct BeatSection: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        /// One tempo throughout.
        case consistent
        /// The tempo moves from the section before's to the section after's.
        case ramp
        /// Not analyzed, the same as leaving it unmarked; there so the
        /// person can say so.
        case none

        var id: Self { self }

        var name: String {
            switch self {
            case .consistent: "Consistent"
            case .ramp: "Ramp"
            case .none: "None"
            }
        }
    }

    /// How a consistent section keeps its tempo, which decides whether
    /// detection may move its beats off the grid.
    enum Steadiness: String, CaseIterable, Identifiable, Sendable {
        /// Produced to a click track: the beats are an exact grid.
        case click
        /// Meant to be steady but played live, so it drifts: the grid is
        /// refined with detection.
        case intent

        var id: Self { self }
    }

    var id = UUID()
    var kind: Kind
    var start: CMTime
    var end: CMTime
    /// Only the count of beats in a measure: 4/4 and 4/8 are both 4.
    var beatsPerMeasure = 4
    /// Whether the person set `beatsPerMeasure`, rather than it being the
    /// default; only then is it shown on the section.
    var isMeasureSet = false
    var steadiness = Steadiness.click
    /// True once the section has been filled, so its beats are the
    /// result rather than only the anchors the person placed.
    var isConfirmed = false
    /// In time order. Before the section is filled these are the anchors.
    var beats: [MappedBeat] = []

    static let beatsPerMeasureRange = 1...32

    var range: CMTimeRange { CMTimeRange(start: start, end: end) }
    var pinnedBeats: [MappedBeat] { beats.filter(\.isPinned) }

    func contains(_ time: CMTime) -> Bool {
        CMTimeCompare(time, start) >= 0 && CMTimeCompare(time, end) < 0
    }

    /// Keeps the beats in time order with no two at the same time, and the
    /// beat count and positions in range.
    mutating func normalize() {
        beatsPerMeasure = beatsPerMeasure.clamped(between: Self.beatsPerMeasureRange.lowerBound, and: Self.beatsPerMeasureRange.upperBound)
        beats.sort { CMTimeCompare($0.time, $1.time) < 0 }
        var kept: [MappedBeat] = []
        for beat in beats {
            if let last = kept.last, CMTimeCompare(last.time, beat.time) == 0 {
                // A pinned beat wins over one that was only placed.
                if beat.isPinned && !last.isPinned { kept[kept.count - 1] = beat }
                continue
            }
            kept.append(beat)
        }
        beats = kept
        for index in beats.indices {
            beats[index].position = (beats[index].position - 1).modulo(beatsPerMeasure) + 1
        }
    }

    /// Numbers every beat's place in its measure, counting out from the
    /// pinned beats: each pinned beat keeps its position, and the beats
    /// after it count on from it until the next pinned beat. Beats before
    /// the first pinned beat count back from it. With no pinned beat, the
    /// count starts at `firstPosition`.
    mutating func recountPositions(firstPosition: Int = 1) {
        guard !beats.isEmpty else { return }
        let measure = beatsPerMeasure
        let seed: Int
        if let firstPinned = beats.firstIndex(where: \.isPinned) {
            seed = firstPinned
            var position = beats[seed].position
            for index in stride(from: seed - 1, through: 0, by: -1) {
                position = (position - 2).modulo(measure) + 1
                beats[index].position = position
            }
        } else {
            seed = 0
            beats[0].position = (firstPosition - 1).modulo(measure) + 1
        }
        var position = beats[seed].position
        for index in beats.indices.dropFirst(seed + 1) {
            if beats[index].isPinned {
                position = beats[index].position
            } else {
                position = position.modulo(measure) + 1
                beats[index].position = position
            }
        }
    }
}

/// One beat of a beat map.
struct MappedBeat: Equatable, Sendable {
    var time: CMTime
    /// Place in the measure, from 1 (the downbeat) to the section's beats
    /// per measure.
    var position = 1
    /// Placed or moved by the person. Analysis never moves a pinned beat,
    /// and positions are counted out from them.
    var isPinned = false

    var isDownbeat: Bool { position == 1 }
}

/// A beat as the timeline shows it.
struct BeatMarker: Equatable {
    var time: CMTime
    /// Place in its measure, 1 for a downbeat; nil for a detected beat,
    /// which has no measures and hasn't been confirmed.
    var position: Int?

    var isConfirmed: Bool { position != nil }
    var isDownbeat: Bool { position == 1 }
}

extension Int {
    /// The remainder that is never negative, for counting around a measure.
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }
}
