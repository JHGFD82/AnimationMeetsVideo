import SwiftUI

/// A zoom slider, as the timeline's header has: an arrow along the axis it
/// zooms, then a mini slider from the farthest zoom (left) to the closest.
/// Every timeline-like view zooms with one, so they read and work alike;
/// the main timeline alone also has the Tape Scrubber.
///
/// The slider is even in ratio (`ZoomScale`), so each step zooms by the
/// same factor, far out as near in.
struct ZoomSlider: View {
    /// 0 is the farthest zoom; 1 the closest.
    @Binding var fraction: Double
    /// What VoiceOver calls it: "Time zoom".
    let label: String
    var axis: Axis = .horizontal
    let help: String
    var width: CGFloat = ZoomSlider.width
    /// Whether the slider is being dragged: true as a drag starts, false
    /// as it ends.
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// The same in every view, so a drag along it feels the same.
    static let width: CGFloat = 84

    var body: some View {
        HStack(spacing: Design.Space.tight) {
            Image(systemName: axis == .horizontal ? "arrow.left.and.right" : "arrow.up.and.down")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textTertiary)
                .accessibilityHidden(true)
            Slider(value: $fraction, in: 0...1, onEditingChanged: onEditingChanged)
                .controlSize(.mini)
                .frame(width: width)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        }
        .help(help)
    }
}

/// Where a zoom sits on a `ZoomSlider`: its place between the farthest and
/// closest zooms, even in ratio. Zooms are magnifications, larger closer;
/// a view that keeps seconds per point passes their reciprocals.
enum ZoomScale {
    /// The slider's place, 0...1, for `zoom` in `range`; 0 when the range
    /// is empty, as for a song too short to zoom.
    static func fraction(of zoom: Double, in range: ClosedRange<Double>) -> Double {
        guard range.lowerBound > 0, range.upperBound > range.lowerBound else { return 0 }
        let fraction = log(zoom / range.lowerBound) / log(range.upperBound / range.lowerBound)
        return fraction.clamped(between: 0, and: 1)
    }

    /// The zoom at the slider's place `fraction`.
    static func zoom(atFraction fraction: Double, in range: ClosedRange<Double>) -> Double {
        guard range.lowerBound > 0, range.upperBound > range.lowerBound else { return range.lowerBound }
        return range.lowerBound * pow(range.upperBound / range.lowerBound, fraction.clamped(between: 0, and: 1))
    }

    /// The factor that takes `zoom` to the slider's place `fraction`
    /// (above 1 zooms in), for views that zoom by factors.
    static func factor(from zoom: Double, toFraction fraction: Double, in range: ClosedRange<Double>) -> Double {
        guard zoom > 0 else { return 1 }
        return Self.zoom(atFraction: fraction, in: range) / zoom
    }
}
