import SwiftUI

/// A zoom control drawn as the Tape Scrubber's ridged dial: drag along it
/// to turn it, rightward or upward to zoom in. Each point turned changes
/// the zoom by the same ratio (`factor(forTurn:)`), so it feels the same
/// zoomed far out as far in. Double-click it to go back to the fitted view.
struct ZoomDial: View {
    let axis: Axis
    /// What VoiceOver calls it: "Time zoom".
    let label: String
    /// How much the shown span shrinks for a turn (above 1 zooms in), and
    /// whether a drag is holding the dial, so a zoom past a limit can
    /// stretch until it lets go.
    let onZoom: (_ factor: Double, _ held: Bool) -> Void
    let onReset: () -> Void
    /// A drag let go of the dial.
    var onRelease: () -> Void = {}

    /// How far the rim has turned, for drawing.
    @State private var turn: CGFloat = 0
    @State private var lastTranslation: CGFloat?

    static let thickness: CGFloat = 22
    /// How long it is at most, shorter than the Tape Scrubber's so it never
    /// outgrows it, and the same in any window, so a turn feels the same.
    static let length: CGFloat = 200

    /// The zoom ratio for `points` of turn: e (about 2.7 times) every 150.
    static func factor(forTurn points: CGFloat) -> Double {
        exp(Double(points) / 150)
    }

    var body: some View {
        RidgedDial(turn: turn, axis: axis)
            .frame(width: axis == .vertical ? Self.thickness : nil, height: axis == .horizontal ? Self.thickness : nil)
            .contentShape(Rectangle())
            .gesture(drag)
            .onTapGesture(count: 2, perform: onReset)
            .pointerStyle(lastTranslation == nil ? .grabIdle : .grabActive)
            .help("Drag along the dial to zoom \(axis == .horizontal ? "time" : "values"); double-click to fit")
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityHint("Adjust to zoom in or out")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onZoom(1.25, false)
                case .decrement: onZoom(1 / 1.25, false)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Fit") { onReset() }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Toward the zoom-in end is right, or up.
                let along = axis == .horizontal ? value.translation.width : -value.translation.height
                let step = along - (lastTranslation ?? 0)
                lastTranslation = along
                // The ridges follow the pointer.
                turn += axis == .horizontal ? step : -step
                if step != 0 { onZoom(Self.factor(forTurn: step), true) }
            }
            .onEnded { _ in
                lastTranslation = nil
                onRelease()
            }
    }
}
