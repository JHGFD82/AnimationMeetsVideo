import CoreGraphics
import CoreMedia
import SwiftUI

/// What a graph editor shows: how far it is zoomed and scrolled each way,
/// which components are drawn, and whether they share one value scale.
/// Kept by the graph while its panel is open.
struct KeyframeGraphViewport: Equatable {
    /// The seconds shown across, in the parameter's time; nil fits the
    /// keyframes.
    var times: ClosedRange<Double>?
    /// How many times closer than fitted the values are drawn.
    var valueZoom = 1.0
    /// How far the values are scrolled, in fitted heights: 0.5 is half the
    /// fitted range up.
    var valuePan = 0.0
    /// Components not drawn (Position's y, say).
    var hidden: Set<Int> = []
    /// Whether each component is drawn on a scale of its own, so a small
    /// move of one isn't flattened by a large one of another.
    var separateScales = false

    static let valueZooms = 0.25...1000.0
    /// The fewest frames across when zoomed all the way in.
    static let fewestFrames = 4.0

    /// The time shown across: `times`, or `fit`, kept inside `span`.
    func shownTimes(fit: ClosedRange<Double>, span: ClosedRange<Double>) -> ClosedRange<Double> {
        Self.clamped(times ?? fit, to: span)
    }

    /// Zooms time in by `factor` (above 1 shows less), keeping `anchor`
    /// where it is on screen, no closer than `fewestFrames` and no further
    /// out than `span`.
    mutating func zoomTimes(by factor: Double, around anchor: Double, fit: ClosedRange<Double>, span: ClosedRange<Double>, frame: Double) {
        let shown = shownTimes(fit: fit, span: span)
        let length = shown.upperBound - shown.lowerBound
        let shortest = min(Self.fewestFrames * frame, span.upperBound - span.lowerBound)
        let newLength = min(max(length / factor, shortest), span.upperBound - span.lowerBound)
        let fraction = length > 0 ? (anchor - shown.lowerBound) / length : 0.5
        let start = anchor - fraction * newLength
        times = Self.clamped(start...(start + newLength), to: span)
    }

    /// Scrolls time by `seconds`, inside `span`.
    mutating func panTimes(by seconds: Double, fit: ClosedRange<Double>, span: ClosedRange<Double>) {
        let shown = shownTimes(fit: fit, span: span)
        times = Self.clamped((shown.lowerBound + seconds)...(shown.upperBound + seconds), to: span)
    }

    /// Zooms values in by `factor`, keeping the value `fraction` up the
    /// plot (0 the bottom, 1 the top) where it is.
    mutating func zoomValues(by factor: Double, around fraction: Double) {
        let zoom = min(max(valueZoom * factor, Self.valueZooms.lowerBound), Self.valueZooms.upperBound)
        valuePan += (fraction - 0.5) * (1 / valueZoom - 1 / zoom)
        valueZoom = zoom
    }

    /// The values shown for a component fitted to `fit`.
    func shownValues(fit: ClosedRange<Double>) -> ClosedRange<Double> {
        let length = fit.upperBound - fit.lowerBound
        let center = (fit.lowerBound + fit.upperBound) / 2 + valuePan * length
        let half = length / valueZoom / 2
        return (center - half)...(center + half)
    }

    /// `range` moved, and shortened only if it must be, to lie inside
    /// `span`.
    static func clamped(_ range: ClosedRange<Double>, to span: ClosedRange<Double>) -> ClosedRange<Double> {
        let length = min(range.upperBound - range.lowerBound, span.upperBound - span.lowerBound)
        let start = min(max(range.lowerBound, span.lowerBound), span.upperBound - length)
        return start...(start + length)
    }
}

/// Where a parameter's graph draws things: the parameter's time across, each
/// component's shown value up.
struct KeyframeGraphLayout: Equatable {
    var times: ClosedRange<Double>
    /// One range of shown values per component; all the same unless the
    /// viewport separates them.
    var values: [ClosedRange<Double>]
    var plot: CGRect

    static let insets = EdgeInsets(top: 12, leading: 52, bottom: 20, trailing: 14)

    init(times: ClosedRange<Double>, values: [ClosedRange<Double>], plot: CGRect) {
        self.times = times
        self.values = values
        self.plot = plot
    }

    /// Lays `value` (shown with `offset` added) out in `size` as `viewport`
    /// says, time going no further than `span`, the parameter's own: a
    /// clip's trimmed range, padded a little so points at its ends show.
    /// A graph linked with others shows the `shared` times instead, which
    /// may reach past its span.
    init(_ value: AnimatedValue<ComponentValue>, offset: [Double], size: CGSize, viewport: KeyframeGraphViewport,
         span: ClosedRange<Double>, frame: Double, shared: ClosedRange<Double>? = nil) {
        let insets = Self.insets
        plot = CGRect(
            x: insets.leading, y: insets.top,
            width: max(1, size.width - insets.leading - insets.trailing),
            height: max(1, size.height - insets.top - insets.bottom)
        )
        let padded = Self.padded(span)
        times = shared ?? viewport.shownTimes(fit: Self.fitTimes(value, span: padded, frame: frame), span: padded)
        let count = value.value.values.count
        let shown = (0..<count).filter { !viewport.hidden.contains($0) }
        if viewport.separateScales {
            values = (0..<count).map { viewport.shownValues(fit: Self.fitValues(value, offset: offset, components: [$0])) }
        } else {
            let fit = Self.fitValues(value, offset: offset, components: shown.isEmpty ? Array(0..<count) : shown)
            values = Array(repeating: viewport.shownValues(fit: fit), count: count)
        }
    }

    /// The parameter's span with a little room past each end.
    static func padded(_ span: ClosedRange<Double>) -> ClosedRange<Double> {
        let pad = max((span.upperBound - span.lowerBound) * 0.04, 0.05)
        return (span.lowerBound - pad)...(span.upperBound + pad)
    }

    /// The keyframes' span with room either side, at least a second.
    static func fitTimes(_ value: AnimatedValue<ComponentValue>, span: ClosedRange<Double>, frame: Double) -> ClosedRange<Double> {
        let keyTimes = value.keyframes.map(\.time.seconds)
        var start = keyTimes.first ?? span.lowerBound, end = keyTimes.last ?? span.upperBound
        if end - start < 1 {
            let middle = (start + end) / 2
            start = middle - 0.5
            end = middle + 0.5
        }
        let pad = (end - start) * 0.08
        return KeyframeGraphViewport.clamped((start - pad)...(end + pad), to: span)
    }

    /// The range that holds `components` of the curve between its first
    /// and last keyframes, and their handles, with room above and below.
    static func fitValues(_ value: AnimatedValue<ComponentValue>, offset: [Double], components: [Int]) -> ClosedRange<Double> {
        let wanted = Set(components)
        var low = Double.infinity, high = -Double.infinity
        func include(_ shown: Double) {
            low = min(low, shown)
            high = max(high, shown)
        }
        let start = value.keyframes.first?.time.seconds ?? 0, end = value.keyframes.last?.time.seconds ?? 0
        for index in 0...120 {
            let values = value.value(atSeconds: start + (end - start) * Double(index) / 120).values
            for component in values.indices where wanted.contains(component) {
                include(values[component] + (component < offset.count ? offset[component] : 0))
            }
        }
        for segment in segments(of: value) where !segment.from.hold {
            for component in segment.from.value.values.indices where wanted.contains(component) {
                let shift = component < offset.count ? offset[component] : 0
                let a = segment.from.value.values[component] + shift
                let b = segment.to.value.values[component] + shift
                for handle in [KeyframeEase.outgoingHandle(segment.from.easeOut), KeyframeEase.incomingHandle(segment.to.easeIn)] {
                    include(a + Double(handle.y) * (b - a))
                }
            }
        }
        if !low.isFinite { low = 0; high = 1 }
        if high - low < 1e-6 {
            low -= 1
            high += 1
        }
        let pad = (high - low) * 0.1
        return (low - pad)...(high + pad)
    }

    static func segments(of value: AnimatedValue<ComponentValue>) -> [(from: Keyframe<ComponentValue>, to: Keyframe<ComponentValue>)] {
        zip(value.keyframes, value.keyframes.dropFirst()).map { ($0, $1) }
    }

    func x(_ seconds: Double) -> CGFloat {
        plot.minX + plot.width * CGFloat((seconds - times.lowerBound) / (times.upperBound - times.lowerBound))
    }

    func seconds(atX x: CGFloat) -> Double {
        times.lowerBound + Double((x - plot.minX) / plot.width) * (times.upperBound - times.lowerBound)
    }

    private func range(_ component: Int) -> ClosedRange<Double> {
        values.indices.contains(component) ? values[component] : (values.first ?? 0...1)
    }

    func y(_ shown: Double, component: Int) -> CGFloat {
        let range = range(component)
        return plot.maxY - plot.height * CGFloat((shown - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    func value(atY y: CGFloat, component: Int) -> Double {
        let range = range(component)
        return range.lowerBound + Double((plot.maxY - y) / plot.height) * (range.upperBound - range.lowerBound)
    }

    /// Seconds of time per point across.
    var secondsPerPoint: Double { (times.upperBound - times.lowerBound) / Double(plot.width) }
}
