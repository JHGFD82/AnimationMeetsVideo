import Foundation
import os

/// How loud every audio track of the playing composition is together, for
/// the timeline's meter. Each track's tap (`AudioLevelTap`) records the
/// level of what it lets through, after the layers' volumes, in short
/// windows of composition time; the meter reads the windows at the
/// playhead, so it shows what is heard rather than what was decoded ahead.
///
/// Tracks are measured apart and combined by power: the mix's level is
/// estimated as the square root of the sum of the tracks' mean squares
/// (and peaks the same way), which is exact for unrelated sounds and reads
/// low for identical ones played together. Taps may see different sample
/// rates, so their samples can't simply be added.
final class MixLevelMeter: @unchecked Sendable {
    static let windowsPerSecond = 50.0
    /// About twenty seconds of windows: far more than a player decodes ahead.
    private static let ringSize = 1024
    /// Tracks past this many aren't measured.
    static let maximumTracks = 32

    /// Left and right, linear (1 is full scale).
    struct Reading: Equatable {
        var rms = SIMD2<Float>.zero
        var peak = SIMD2<Float>.zero

        static let silent = Reading()
    }

    /// One track's sound in one window.
    private struct Entry {
        var window = Int.min
        var squares = SIMD2<Float>.zero
        var count = 0
        var peak = SIMD2<Float>.zero
    }

    private let entries = OSAllocatedUnfairLock(
        initialState: [Entry](repeating: Entry(), count: ringSize * maximumTracks)
    )

    /// Forgets everything, for a new composition.
    func reset() {
        entries.withLock { entries in
            for index in entries.indices { entries[index] = Entry() }
        }
    }

    private static func window(at seconds: Double) -> Int {
        Int((seconds * windowsPerSecond).rounded(.down))
    }

    private static func slot(window: Int, track: Int) -> Int {
        (((window % ringSize) + ringSize) % ringSize) * maximumTracks + track
    }

    /// Records `frames` samples of a track starting at composition time
    /// `start`, each channel given as its first sample and the distance
    /// between samples. A window played again is averaged with itself, so
    /// replaying doesn't make it louder.
    func record(
        left: (UnsafeMutablePointer<Float>, Int), right: (UnsafeMutablePointer<Float>, Int),
        frames: Int, sampleRate: Double, start: Double, track: Int
    ) {
        guard track < Self.maximumTracks, frames > 0, sampleRate > 0 else { return }
        var frame = 0
        while frame < frames {
            let window = Self.window(at: start + Double(frame) / sampleRate)
            let windowEnd = (Double(window + 1) / Self.windowsPerSecond - start) * sampleRate
            let end = min(frames, max(frame + 1, Int(windowEnd.rounded(.up))))
            var squares = SIMD2<Float>.zero
            var peak = SIMD2<Float>.zero
            for index in frame..<end {
                let l = left.0[index * left.1], r = right.0[index * right.1]
                squares += SIMD2(l * l, r * r)
                peak = pointwiseMax(peak, SIMD2(abs(l), abs(r)))
            }
            let count = end - frame
            let measured = (squares: squares, peak: peak)
            entries.withLock { entries in
                let slot = Self.slot(window: window, track: track)
                if entries[slot].window == window {
                    entries[slot].squares += measured.squares
                    entries[slot].count += count
                    entries[slot].peak = pointwiseMax(entries[slot].peak, measured.peak)
                } else {
                    entries[slot] = Entry(window: window, squares: measured.squares, count: count, peak: measured.peak)
                }
            }
            frame = end
        }
    }

    /// The loudest of the `span` windows ending at `seconds`.
    func reading(at seconds: Double, span: Int = 2) -> Reading {
        let last = Self.window(at: seconds)
        return entries.withLock { entries in
            var reading = Reading()
            for window in (last - span + 1)...last {
                var power = SIMD2<Float>.zero
                var peaks = SIMD2<Float>.zero
                for track in 0..<Self.maximumTracks {
                    let entry = entries[Self.slot(window: window, track: track)]
                    guard entry.window == window, entry.count > 0 else { continue }
                    power += entry.squares / Float(entry.count)
                    peaks += entry.peak * entry.peak
                }
                reading.rms = pointwiseMax(reading.rms, power.squareRoot())
                reading.peak = pointwiseMax(reading.peak, peaks.squareRoot())
            }
            return reading
        }
    }
}

/// How a level meter moves, in dBFS: it jumps up to a louder reading at
/// once and falls back at a steady rate, a held mark sits at the recent
/// peak for a moment before falling too, and a clip lamp latches once a
/// channel reaches full scale until it is reset.
struct MeterBallistics: Equatable {
    /// The bottom of the scale; quieter reads as this.
    static let floor = -60.0
    /// How fast the bar falls, in decibels a second.
    static let fallRate = 24.0
    /// How long the peak mark holds before it falls.
    static let holdSeconds = 1.5

    /// Left and right, in dBFS.
    private(set) var level = SIMD2<Double>(repeating: floor)
    private(set) var held = SIMD2<Double>(repeating: floor)
    private(set) var clipped = [false, false]
    private var heldAt = SIMD2<Double>(repeating: -.infinity)
    private var lastUpdate: Double?

    static func decibels(_ linear: Float) -> Double {
        linear > 0 ? max(floor, 20 * log10(Double(linear))) : floor
    }

    /// Moves to `now` (seconds) with a reading of the peaks, linear, or
    /// with silence when nil.
    mutating func update(peak: SIMD2<Float>?, at now: Double) {
        let elapsed = lastUpdate.map { max(0, now - $0) } ?? 0
        lastUpdate = now
        let fall = Self.fallRate * elapsed
        for channel in 0..<2 {
            let linear = peak?[channel] ?? 0
            let reading = Self.decibels(linear)
            if linear >= 0.999 { clipped[channel] = true }
            level[channel] = max(reading, level[channel] - fall)
            if reading >= held[channel] {
                held[channel] = reading
                heldAt[channel] = now
            } else if now - heldAt[channel] > Self.holdSeconds {
                held[channel] = max(level[channel], held[channel] - fall)
            }
        }
    }

    mutating func resetClips() {
        clipped = [false, false]
    }
}
