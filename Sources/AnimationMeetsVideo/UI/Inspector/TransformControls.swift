import AppKit
import CoreMedia
import SwiftUI

// MARK: - Property rows

/// One transform property's controls: the stopwatch that turns keyframing
/// on and off, its name, its values at the playhead, and, once animated,
/// buttons to go to the previous or next keyframe and to add or remove one
/// at the playhead. Used in the timeline and the inspector.
struct TransformPropertyRow: View {
    let property: TransformProperty
    let transform: LayerTransform
    /// The playhead, snapped to a frame.
    let time: CMTime
    let frameSize: CGSize
    let onEdit: ((inout LayerTransform) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    private var isAnimated: Bool { transform.isAnimated(property) }
    private var keyframeTimes: [CMTime] { transform.keyframeTimes(property) }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                onEdit { $0.setAnimated(property, !isAnimated, at: time) }
            } label: {
                Image(systemName: isAnimated ? "stopwatch.fill" : "stopwatch")
                    .foregroundStyle(isAnimated ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isAnimated ? "Stop animating \(property.rawValue.lowercased()) (keeps the current value)" : "Animate \(property.rawValue.lowercased())")

            Text(property.rawValue)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            if property == .scale {
                Button {
                    onEdit { $0.scaleLinked.toggle() }
                } label: {
                    Image(systemName: "link")
                        .foregroundStyle(transform.scaleLinked ? Color.primary : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help(transform.scaleLinked ? "Width and height scale together" : "Width and height scale separately")
            }

            let components = transform.components(property, at: time, frameSize: frameSize)
            ForEach(components.indices, id: \.self) { index in
                if index > 0 { Text(",").foregroundStyle(.secondary) }
                NumericField(value: components[index], unit: property.unit) { newValue in
                    onEdit { $0.setComponent(index, of: property, to: newValue, at: time, frameSize: frameSize) }
                }
            }

            Spacer(minLength: 4)

            if isAnimated {
                keyframeNavigation
            }
        }
        .font(.caption)
    }

    private var keyframeNavigation: some View {
        let previous = keyframeTimes.last { $0 < time }
        let next = keyframeTimes.first { $0 > time }
        let hasKeyframe = keyframeTimes.contains(time)
        return HStack(spacing: 2) {
            Button {
                if let previous { onSeek(previous) }
            } label: {
                Image(systemName: "arrowtriangle.left.fill")
            }
            .disabled(previous == nil)
            .help("Previous keyframe")
            Button {
                onEdit { $0.toggleKeyframe(property, at: time) }
            } label: {
                Image(systemName: hasKeyframe ? "diamond.fill" : "diamond")
                    .foregroundStyle(hasKeyframe ? Color.yellow : Color.secondary)
            }
            .help(hasKeyframe ? "Remove the keyframe at the playhead" : "Add a keyframe at the playhead")
            Button {
                if let next { onSeek(next) }
            } label: {
                Image(systemName: "arrowtriangle.right.fill")
            }
            .disabled(next == nil)
            .help("Next keyframe")
        }
        .buttonStyle(.plain)
        .font(.system(size: 8))
    }
}

/// The four property rows of a layer, for the inspector.
struct TransformInspectorSection: View {
    let transform: LayerTransform
    let time: CMTime
    let frameSize: CGSize
    let onEdit: ((inout LayerTransform) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    var body: some View {
        ForEach(TransformProperty.allCases) { property in
            TransformPropertyRow(
                property: property, transform: transform, time: time,
                frameSize: frameSize, onEdit: onEdit, onSeek: onSeek
            )
        }
        Button("Reset Transform") {
            onEdit { $0 = .identity }
        }
        .disabled(transform == .identity)
    }
}

// MARK: - Keyframe lanes

/// A property's keyframes as diamonds under the layer's clips. Clicking a
/// diamond moves the playhead to it; dragging retimes it, snapping to frames.
struct KeyframeLane: View {
    let times: [CMTime]
    let currentTime: CMTime
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    let snap: (CMTime) -> CMTime
    let onSeek: (CMTime) -> Void
    let onMove: (CMTime, CMTime) -> Void
    let onDelete: (CMTime) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.primary.opacity(0.03)
                .allowsHitTesting(false)
            ForEach(times, id: \.self) { time in
                KeyframeDiamond(
                    time: time,
                    isAtPlayhead: time == currentTime,
                    pixelsPerSecond: pixelsPerSecond,
                    height: height,
                    snap: snap,
                    onSeek: onSeek,
                    onMove: onMove,
                    onDelete: onDelete
                )
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

private struct KeyframeDiamond: View {
    let time: CMTime
    let isAtPlayhead: Bool
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let snap: (CMTime) -> CMTime
    let onSeek: (CMTime) -> Void
    let onMove: (CMTime, CMTime) -> Void
    let onDelete: (CMTime) -> Void

    @GestureState private var dragX: CGFloat = 0

    private let size: CGFloat = 9

    var body: some View {
        let x = CGFloat(time.seconds) * pixelsPerSecond + dragX
        Rectangle()
            .fill(isAtPlayhead ? Color.yellow : Color.primary.opacity(0.75))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
            .frame(width: size + 6, height: height)
            .contentShape(Rectangle())
            .offset(x: x - (size + 6) / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragX) { value, state, _ in state = value.translation.width }
                    .onEnded { value in
                        if abs(value.translation.width) < 3 {
                            onSeek(time)
                        } else {
                            let delta = CMTime(seconds: Double(value.translation.width / pixelsPerSecond), preferredTimescale: 600)
                            onMove(time, snap(CMTimeAdd(time, delta)))
                        }
                    }
            )
            .contextMenu {
                Button("Delete Keyframe", role: .destructive) { onDelete(time) }
            }
            .help(time.formatted)
    }
}

// MARK: - Keys

/// Calls `handler` for key presses in this view's window while no text is
/// being edited there, so single-letter shortcuts don't swallow typing. The
/// handler returns true when it used the key.
struct KeyPressMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handler = handler
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        /// Only listens for keys; clicks go to the views around it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window,
                          !(window.firstResponder is NSText)
                    else {
                        return false
                    }
                    return self.handler?(event) == true
                }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
