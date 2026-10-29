import AppKit
import CoreMedia
import Observation
import SwiftUI

/// The timecode shown in a box over the pointer while something on a
/// timeline is dragged (a clip, a trimmed edge, a keyframe, a section): the
/// exact time it will land at, and how far that is from where it started.
/// A transition's length shows its whole length instead of a time, and a
/// slip only how far the footage moved. A drag writes it on every move;
/// only the box reads it, so writing it redraws nothing else.
@MainActor
@Observable
final class DragTimecodeReadout {
    /// What the box shows before the change.
    enum Value: Equatable {
        /// Where the dragged thing (or the edge being dragged) will land,
        /// in the timeline's time.
        case time(CMTime)
        /// How long a transition being resized will be.
        case length(CMTime)
    }

    struct Reading: Equatable {
        /// Nil for a slip, which shows only the change.
        var value: Value?
        /// From where it was picked up to `value`, or how far a slip moved
        /// the footage.
        var moved: CMTime
        /// The pointer, in window coordinates (SwiftUI's `.global`).
        var pointer: CGPoint
    }

    private(set) var reading: Reading?

    /// Shows `time`, moved from `origin`, over `pointer`. Without one, it
    /// is read from the mouse event being handled, for drags measured in
    /// a space of their own; failing that the box stays where it was.
    func show(_ time: CMTime, from origin: CMTime, pointer: CGPoint? = nil) {
        show(.time(time), moved: CMTimeSubtract(time, origin), pointer: pointer)
    }

    /// Shows a transition's whole `length`, changed from `original`.
    func showLength(_ length: CMTime, from original: CMTime, pointer: CGPoint? = nil) {
        show(.length(length), moved: CMTimeSubtract(length, original), pointer: pointer)
    }

    /// Shows only how far a slip has moved the footage.
    func showSlip(_ moved: CMTime, pointer: CGPoint? = nil) {
        show(nil, moved: moved, pointer: pointer)
    }

    private func show(_ value: Value?, moved: CMTime, pointer: CGPoint?) {
        guard let pointer = pointer ?? Self.eventPointer() ?? reading?.pointer else { return }
        let next = Reading(value: value, moved: moved, pointer: pointer)
        if next != reading { reading = next }
    }

    /// The drag ended or was cancelled.
    func hide() {
        if reading != nil { reading = nil }
    }

    /// The pointer of the mouse event being handled, in window coordinates.
    private static func eventPointer() -> CGPoint? {
        guard let event = NSApp.currentEvent,
              [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type),
              let height = event.window?.contentView?.bounds.height
        else {
            return nil
        }
        return CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
    }
}

extension View {
    /// Shows a `DragTimecodeReadout` over this view while one of the drags
    /// inside it writes to it, with timecodes at `frameRate`.
    func dragTimecodeReadout(frameRate: Double) -> some View {
        modifier(DragTimecodeReadoutHost(frameRate: frameRate))
    }
}

private struct DragTimecodeReadoutHost: ViewModifier {
    let frameRate: Double
    @State private var readout = DragTimecodeReadout()

    func body(content: Content) -> some View {
        content
            .environment(readout)
            .overlay { DragTimecodeBox(readout: readout, frameRate: frameRate) }
    }
}

/// The readout's box, centered above the pointer and kept inside the view
/// it is shown over.
private struct DragTimecodeBox: View {
    let readout: DragTimecodeReadout
    let frameRate: Double
    @State private var size: CGSize = .zero

    /// How far above the pointer the box's bottom sits, clear of the
    /// pointer itself.
    private static let lift: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            if let reading = readout.reading {
                let frame = proxy.frame(in: .global)
                let half = size.width / 2
                let x = min(max(reading.pointer.x - frame.minX, half), max(half, frame.width - half))
                DragTimecodeLabel(value: reading.value, moved: reading.moved, frameRate: frameRate)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .position(x: x, y: reading.pointer.y - frame.minY - Self.lift - size.height / 2)
            }
        }
        .allowsHitTesting(false)
        // What it says is spoken through the dragged thing's own value;
        // VoiceOver moves things with actions, not drags.
        .accessibilityHidden(true)
    }
}

/// The timecode a drag lands at, or a transition's length, and beside it
/// how far it changed; a slip's change alone.
struct DragTimecodeLabel: View {
    let value: DragTimecodeReadout.Value?
    let moved: CMTime
    let frameRate: Double

    var body: some View {
        HStack(spacing: Design.Space.close) {
            switch value {
            case .time(let time):
                Text(CMTimeMaximum(time, .zero).timecode(frameRate: frameRate))
                    .foregroundStyle(Design.textPrimary)
            case .length(let length):
                // A length reads as one, not as a place on the timeline.
                Text(length.compactTimecode(frameRate: frameRate))
                    .foregroundStyle(Design.textPrimary)
            case nil:
                EmptyView()
            }
            Text(moved.signedCompactTimecode(frameRate: frameRate))
                .foregroundStyle(value == nil ? Design.textPrimary : Design.textSecondary)
        }
        .font(Design.Typeface.numericSmall)
        .padding(.horizontal, Design.Space.close)
        .padding(.vertical, 3)
        .fixedSize()
        .beveledChip(fill: Design.Surface.overlay.color, radius: Design.Radius.control, strong: true)
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
    }
}
