import CoreMedia
import Observation
import SwiftUI

/// The graphs one graph editor panel shows: a parameter's, or several
/// linked into the panel (see docs/layer-transforms.md, "Linking graph
/// editors"). Linked graphs show one stretch of the timeline across, kept
/// here in timeline seconds, so a zoom or a scroll in any of them moves
/// them all, and the same moment lines up down the panel.
@MainActor @Observable
final class KeyframeGraphLink: Identifiable {
    let id = UUID()
    /// The parameters, top to bottom, all of one timeline.
    var keys: [ParameterKey]
    /// The shared stretch, in timeline seconds; only its time is used, and
    /// nil fits every graph's keyframes.
    var viewport = KeyframeGraphViewport()
    /// Time's edges, shared as the time is.
    var timeBand = RubberBandZoom()
    var timeScrollBand = RubberBandScroll()
    /// Each linked graph's selected keyframe, kept here so the panel's one
    /// row of ease presets can act on it.
    var selected: [ParameterKey: CMTime] = [:]
    /// The graph last clicked, which the presets act on; the top one until
    /// another is.
    var active: ParameterKey?
    /// Counts the shared Fit button's presses, which each graph answers by
    /// fitting its values.
    var fits = 0

    init(_ keys: [ParameterKey]) {
        self.keys = keys
    }

    /// Whether the panel holds more than one graph, which then share time.
    var isLinked: Bool { keys.count > 1 }

    /// The graph the presets act on.
    var activeKey: ParameterKey? {
        active.flatMap { keys.contains($0) ? $0 : nil } ?? keys.first
    }

    /// Fits the shared time to every graph's keyframes, and each graph's
    /// values to its own.
    func fit() {
        viewport.times = nil
        fits += 1
    }

    /// Whether `other`'s graphs can join these: graphs of one timeline
    /// only, since a shared time must mean the same moment in each.
    func canLink(_ other: KeyframeGraphLink) -> Bool {
        other !== self && Set((keys + other.keys).map(\.timelineID)).count == 1
    }

    /// Where the graphs' time may go, and where their keyframes are, in
    /// timeline seconds: the spans of all of them, and their fits.
    func bounds(in project: EditingProject) -> (fit: ClosedRange<Double>, span: ClosedRange<Double>, frame: Double)? {
        var fit: ClosedRange<Double>?, span: ClosedRange<Double>?, frame = 1.0 / 24
        func onTimeline(_ range: ClosedRange<Double>, _ axis: ParameterTimeAxis) -> ClosedRange<Double> {
            let a = axis.timelineTime(atKey: CMTime(seconds: range.lowerBound, preferredTimescale: 240_000)).seconds
            let b = axis.timelineTime(atKey: CMTime(seconds: range.upperBound, preferredTimescale: 240_000)).seconds
            return min(a, b)...max(a, b)
        }
        func union(_ a: ClosedRange<Double>?, _ b: ClosedRange<Double>) -> ClosedRange<Double> {
            a.map { min($0.lowerBound, b.lowerBound)...max($0.upperBound, b.upperBound) } ?? b
        }
        for key in keys {
            guard let axis = project.timeAxis(of: key), let value = project.components(of: key) else { continue }
            frame = axis.frameDuration.seconds
            let padded = KeyframeGraphLayout.padded(axis.span)
            span = union(span, onTimeline(padded, axis))
            fit = union(fit, onTimeline(KeyframeGraphLayout.fitTimes(value, span: padded, frame: frame), axis))
        }
        guard let fit, let span else { return nil }
        return (fit, span, frame)
    }

    /// The timeline seconds shown across.
    func shownTimes(in project: EditingProject) -> ClosedRange<Double>? {
        bounds(in: project).map { viewport.shownTimes(fit: $0.fit, span: $0.span) }
    }

    /// The shown stretch in a graph's own time, which it lays out across.
    /// For a clip that ramps its speed, its ends line up with the other
    /// graphs' and the moments between only nearly do.
    func keyTimes(for axis: ParameterTimeAxis, in project: EditingProject) -> ClosedRange<Double>? {
        guard let shown = shownTimes(in: project) else { return nil }
        let a = axis.keyTime(atTimeline: CMTime(seconds: shown.lowerBound, preferredTimescale: 240_000)).seconds
        let b = axis.keyTime(atTimeline: CMTime(seconds: shown.upperBound, preferredTimescale: 240_000)).seconds
        return a < b ? a...b : (a - 1e-3)...(a + 1e-3)
    }

    /// Zooms the shared time by `factor` (above 1 shows less) about the
    /// timeline moment `anchor`, and returns how far it zoomed.
    func zoomTimes(by factor: Double, around anchor: Double, in project: EditingProject) -> Double {
        guard let bounds = bounds(in: project) else { return 1 }
        let before = viewport.shownTimes(fit: bounds.fit, span: bounds.span)
        viewport.zoomTimes(by: factor, around: anchor, fit: bounds.fit, span: bounds.span, frame: bounds.frame)
        let after = viewport.shownTimes(fit: bounds.fit, span: bounds.span)
        let length = after.upperBound - after.lowerBound
        return length > 0 ? (before.upperBound - before.lowerBound) / length : 1
    }

    /// Scrolls the shared time by `points` of a plot `width` points wide,
    /// and returns how many points it moved.
    func panTimes(byPoints points: CGFloat, across width: CGFloat, in project: EditingProject) -> CGFloat {
        guard let bounds = bounds(in: project), width > 0 else { return 0 }
        let before = viewport.shownTimes(fit: bounds.fit, span: bounds.span)
        let perPoint = (before.upperBound - before.lowerBound) / Double(width)
        guard perPoint > 0 else { return 0 }
        viewport.panTimes(by: Double(points) * perPoint, fit: bounds.fit, span: bounds.span)
        return CGFloat((viewport.shownTimes(fit: bounds.fit, span: bounds.span).lowerBound - before.lowerBound) / perPoint)
    }
}
