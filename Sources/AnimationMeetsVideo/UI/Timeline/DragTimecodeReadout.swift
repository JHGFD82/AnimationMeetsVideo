import AppKit
import CoreMedia
import Observation
import SwiftUI

/// The timecode shown in a box over the pointer while something on a
/// timeline is dragged (a clip, a trimmed edge, a keyframe, a section): the
/// exact time it will land at, and how far that is from where it started.
/// A drag writes it on every move; only the box reads it, so writing it
/// redraws nothing else.
@MainActor
@Observable
final class DragTimecodeReadout {
    struct Reading: Equatable {
        /// Where the dragged thing (or the edge being dragged) will land,
        /// in the timeline's time.
        var time: CMTime
        /// From where it was picked up to `time`.
        var moved: CMTime
        /// The pointer, in window coordinates (SwiftUI's `.global`).
        var pointer: CGPoint
    }

    private(set) var reading: Reading?

    /// Shows `time`, moved from `origin`, over `pointer`. Without one, it
    /// is read from the mouse event being handled, for drags measured in
    /// a space of their own; failing that the box stays where it was.
    func show(_ time: CMTime, from origin: CMTime, pointer: CGPoint? = nil) {
        guard let pointer = pointer ?? Self.eventPointer() ?? reading?.pointer else { return }
        let next = Reading(time: time, moved: CMTimeSubtract(time, origin), pointer: pointer)
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
                DragTimecodeLabel(time: reading.time, moved: reading.moved, frameRate: frameRate)
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

/// The timecode a drag lands at and, beside it, how far it moved.
struct DragTimecodeLabel: View {
    let time: CMTime
    let moved: CMTime
    let frameRate: Double

    var body: some View {
        HStack(spacing: Design.Space.close) {
            Text(CMTimeMaximum(time, .zero).timecode(frameRate: frameRate))
                .foregroundStyle(Design.textPrimary)
            Text(moved.signedCompactTimecode(frameRate: frameRate))
                .foregroundStyle(Design.textSecondary)
        }
        .font(Design.Typeface.numericSmall)
        .padding(.horizontal, Design.Space.close)
        .padding(.vertical, 3)
        .fixedSize()
        .beveledChip(fill: Design.Surface.overlay.color, radius: Design.Radius.control, strong: true)
        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
    }
}
