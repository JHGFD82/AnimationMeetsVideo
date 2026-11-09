import SwiftUI

/// A slider for a value of the project whose drag is held to one side of
/// it (`ProjectState.hold`), as a dragged number is: the viewer and the
/// sound follow, the rest of the editor doesn't redraw on every step, and
/// the project takes the last value when the slider is let go, as one undo
/// step however long the drag paused. A click on the track or a key moves
/// the value at once.
///
/// Escape can't cancel it: AppKit's slider tracks the mouse in a loop of
/// its own, which no key reaches until the button comes up.
struct HeldSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    /// What a step of the drag sets: the value under the pointer, rounded
    /// as the control wants.
    var rounded: (Double) -> Double = { $0 }
    /// The value the drag has reached, or nil once it ends, for a readout
    /// beside the slider to follow while the project lags behind.
    var onDrag: ((Double?) -> Void)?
    let onChange: (Double) -> Void

    @Environment(\.projectHistory) private var history
    @Environment(ProjectState.self) private var projectState: ProjectState?
    @State private var isDragging = false
    /// The value the drag has reached, which the project lags behind.
    @State private var dragged: Double?

    var body: some View {
        Slider(value: Binding(get: { dragged ?? value }, set: change), in: range) { editing in
            if editing { beginDrag() } else { endDrag() }
        }
        // Gone mid-drag: the drag ends here, or the project stays held.
        .onDisappear(perform: endDrag)
    }

    private func change(_ newValue: Double) {
        let newValue = rounded(newValue)
        guard isDragging else { return onChange(newValue) }
        dragged = newValue
        onDrag?(newValue)
        if let projectState {
            projectState.hold { onChange(newValue) }
        } else {
            onChange(newValue)
        }
    }

    private func beginDrag() {
        guard !isDragging else { return }
        isDragging = true
        history?.beginGesture()
        projectState?.beginHold()
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        let last = dragged
        projectState?.endHold()
        dragged = nil
        onDrag?(nil)
        // The last value goes to the project once; a drag let go (see
        // `ProjectState.letGo`) has written it already.
        if let last { onChange(last) }
        // After the last edit has reached the project.
        Task { @MainActor in history?.endGesture() }
    }
}
