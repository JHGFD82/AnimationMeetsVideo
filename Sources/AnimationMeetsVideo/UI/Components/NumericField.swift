import AppKit
import SwiftUI

extension NumericExpression {
    /// A number as it is written back into a field: no grouping, "." for
    /// the decimal point (what `evaluate` reads), and no trailing zeros.
    static func format(_ value: Double, maxFractionDigits: Int = 3) -> String {
        value.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never)
                .precision(.fractionLength(0...maxFractionDigits))
        )
    }
}

/// A number shown as text that turns into a field when clicked, After
/// Effects-style. Return or clicking away enters what was typed, which may
/// be arithmetic ("100+25"); Escape cancels. Text that isn't a number beeps
/// and leaves the value alone.
///
/// With a `dragStep` the number can also be dragged: press on it and drag
/// left or right to lower or raise it by that much per point (ten times
/// with Shift, a tenth with Option). `onCommit` then gets every value along
/// the way, so the picture follows the drag, and the whole drag is one undo
/// step. Escape puts the value back.
struct NumericField: View {
    let value: Double
    var unit = ""
    var fractionDigits = 1
    /// How the value reads while not being edited, in place of the number
    /// and unit.
    var label: ((Double) -> String)?
    /// One point of drag moves the value this far; nil for a field that
    /// can't be dragged.
    var dragStep: Double?
    /// What dragging keeps the value within.
    var dragRange: ClosedRange<Double>?
    /// What the value is, for VoiceOver: "Position X", "Volume". Without
    /// one, VoiceOver reads only the value.
    var accessibilityName: String?
    let onCommit: (Double) -> Void

    @Environment(\.projectHistory) private var history
    @State private var isEditing = false
    @State private var draft = ""
    @State private var drag: ValueDragSession?
    @State private var dragStart = 0.0
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(Design.Typeface.numericSmall)
                .padding(.horizontal, 2)
                .background(Design.Surface.well.color, in: RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(Design.accent, lineWidth: 1)
                }
                .frame(minWidth: 44, maxWidth: 70)
                .focused($isFocused)
                .background(OutsideClickMonitor(onOutsideClick: commit))
                .accessibilityLabel(accessibilityName ?? "Value")
                .onAppear { isFocused = true }
                .onSubmit { commit() }
                .onExitCommand { isEditing = false }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
        } else {
            let shown = label?(value) ?? NumericExpression.format(value, maxFractionDigits: fractionDigits) + unit
            Text(shown)
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(Design.accent)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
                .onTapGesture(perform: beginEditing)
                .simultaneousGesture(dragStep.map { step in
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { _ in beginDrag(step: step) }
                        .onEnded { _ in drag?.finish(cancelled: false) }
                })
                .help(dragStep == nil
                    ? "Click to type a value. Arithmetic such as 100+25 works."
                    : "Click to type a value (arithmetic such as 100+25 works), or drag to change it. Shift for ten times as fast, Option for a tenth.")
                // A tap gesture alone isn't something VoiceOver can press.
                .accessibilityLabel(accessibilityName ?? shown)
                .accessibilityValue(accessibilityName == nil ? "" : shown)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Type a value")
                .accessibilityAction { beginEditing() }
        }
    }

    private func beginEditing() {
        draft = NumericExpression.format(value, maxFractionDigits: 3)
        isEditing = true
    }

    private func beginDrag(step: Double) {
        guard drag == nil else { return }
        let start = value
        dragStart = start
        history?.beginGesture()
        drag = ValueDragSession(
            onMove: { distance, flags in
                onCommit(ValueDrag.value(from: start, distance: distance, step: step, flags: flags, range: dragRange))
            },
            onFinish: { cancelled in
                if cancelled { onCommit(start) }
                drag = nil
                // After the last edit has reached the project.
                Task { @MainActor in history?.endGesture() }
            }
        )
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        guard let result = NumericExpression.evaluate(draft) else {
            if !draft.trimmingCharacters(in: .whitespaces).isEmpty { NSSound.beep() }
            return
        }
        onCommit(result)
    }
}

/// Lets a text field that holds a number take arithmetic: on Return or when
/// focus leaves, "100+25" is replaced by "125". Text that isn't arithmetic
/// is left as typed, for the form's own validation to flag.
private struct ArithmeticFieldModifier: ViewModifier {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onSubmit(evaluate)
            .onChange(of: isFocused) { _, focused in
                if !focused { evaluate() }
            }
    }

    private func evaluate() {
        if let value = NumericExpression.evaluate(text) {
            text = NumericExpression.format(value)
        }
    }
}

extension View {
    /// See `ArithmeticFieldModifier`. Read the value with
    /// `NumericExpression.evaluate` too, so a field that still holds
    /// unevaluated text (the form was submitted without leaving it) counts.
    func evaluatesArithmetic(_ text: Binding<String>) -> some View {
        modifier(ArithmeticFieldModifier(text: text))
    }
}

/// Calls `onOutsideClick` when the mouse goes down anywhere in this view's
/// window except on it, so a field being edited takes what was typed when
/// the person clicks or starts dragging something else. The click still
/// goes through to what was clicked.
private struct OutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window else { return }
                    let inside = self.convert(self.bounds, to: nil).contains(event.locationInWindow)
                    if !inside { self.onOutsideClick?() }
                }
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
