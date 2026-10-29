import CoreMedia
import SwiftUI

/// A keyframe as the lane draws it: where, which sides are eased, whether
/// it holds, and whether a Keyframing effect wrote it.
struct KeyframeMark: Hashable {
    var time: CMTime
    var easedIn: Bool
    var easedOut: Bool
    var isGenerated = false
    var holds = false
}

extension AnimatedValue {
    var marks: [KeyframeMark] {
        keyframes.map {
            KeyframeMark(
                time: $0.time, easedIn: $0.easeIn != nil, easedOut: $0.easeOut != nil, isGenerated: $0.generatedBy != nil, holds: $0.hold
            )
        }
    }
}

/// A property's keyframes as diamonds under the layer's clips, each side
/// pinched like an hourglass where it is eased. Clicking a diamond moves
/// the playhead to it; dragging retimes it, snapping to frames, and
/// Option-dragging copies it there; its menu sets its ease.
struct KeyframeLane: View {
    let marks: [KeyframeMark]
    let currentTime: CMTime
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    let snap: (CMTime) -> CMTime
    let onSeek: (CMTime) -> Void
    /// From, to, and whether Option copies it instead.
    let onMove: (CMTime, CMTime, Bool) -> Void
    let onDelete: (CMTime) -> Void
    let onEase: (CMTime, KeyframeEase.Preset) -> Void
    /// The timeline's time at a time on the lane, for the timecode shown
    /// while a keyframe is dragged; the same time when the lane spans the
    /// timeline.
    var timelineTime: (CMTime) -> CMTime = { $0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18)
                .allowsHitTesting(false)
            ForEach(marks, id: \.time) { mark in
                KeyframeDiamond(
                    mark: mark,
                    isAtPlayhead: mark.time == currentTime,
                    pixelsPerSecond: pixelsPerSecond,
                    height: height,
                    snap: snap,
                    onSeek: onSeek,
                    onMove: onMove,
                    onDelete: onDelete,
                    onEase: onEase,
                    timelineTime: timelineTime
                )
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// A keyframe's mark: a diamond, with each eased side pinched in so the
/// two together read as an hourglass, and a hold keyframe's outgoing side
/// squared off, as in After Effects.
struct KeyframeMarkShape: Shape {
    var easedIn: Bool
    var easedOut: Bool
    var holds = false

    func path(in rect: CGRect) -> Path {
        let pinch = rect.width * 0.18
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        if holds {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else if easedOut {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + pinch, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        if easedIn {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX - pinch, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        }
        path.closeSubpath()
        return path
    }
}

/// Sets a keyframe's ease from a menu.
struct KeyframeEaseMenuItems: View {
    let onEase: (KeyframeEase.Preset) -> Void

    var body: some View {
        ForEach(KeyframeEase.Preset.allCases) { preset in
            Button(preset.shortcutHint.map { "\(preset.name)  \($0)" } ?? preset.name) { onEase(preset) }
                .help(preset.detail)
        }
    }
}

private struct KeyframeDiamond: View {
    let mark: KeyframeMark
    let isAtPlayhead: Bool
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let snap: (CMTime) -> CMTime
    let onSeek: (CMTime) -> Void
    /// From, to, and whether Option copies it instead.
    let onMove: (CMTime, CMTime, Bool) -> Void
    let onDelete: (CMTime) -> Void
    let onEase: (CMTime, KeyframeEase.Preset) -> Void
    let timelineTime: (CMTime) -> CMTime

    private var time: CMTime { mark.time }

    /// The timecode over the pointer while the keyframe is dragged.
    @Environment(DragTimecodeReadout.self) private var readout: DragTimecodeReadout?

    /// Where the diamond is dragged to, on its snapped frame. After a drop
    /// it stays there until the moved keyframe comes back from the project
    /// and replaces this diamond, so the old place never shows for a frame.
    @State private var dragX: CGFloat = 0
    /// Whether Option is held during the drag, which copies the keyframe.
    @State private var isCopying = false

    private let size: CGFloat = 12

    var body: some View {
        let x = CGFloat(time.seconds) * pixelsPerSecond + dragX
        let shape = KeyframeMarkShape(easedIn: mark.easedIn, easedOut: mark.easedOut, holds: mark.holds)
        shape
            .fill(isAtPlayhead ? Design.keyframe : mark.isGenerated ? Design.generatedKeyframe : Design.textSecondary)
            .overlay { shape.stroke(Color.black.opacity(0.45), lineWidth: 0.5) }
            .frame(width: size, height: size)
            .frame(width: size + 6, height: height)
            // Option-dragged, the keyframe stays: a faint one where it is.
            .background {
                if isCopying, dragX != 0 {
                    shape.fill(Design.textTertiary.opacity(0.6))
                        .frame(width: size, height: size)
                        .offset(x: -dragX)
                }
            }
            .contentShape(Rectangle())
            .offset(x: x - (size + 6) / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard abs(value.translation.width) >= 3 else { return }
                        isCopying = CopyDragCursor.update()
                        let target = target(value.translation.width)
                        dragX = CGFloat(CMTimeSubtract(target, time).seconds) * pixelsPerSecond
                        readout?.show(timelineTime(target), from: timelineTime(time), pointer: value.location)
                    }
                    .onEnded { value in
                        readout?.hide()
                        let target = target(value.translation.width)
                        let copying = isCopying
                        isCopying = false
                        CopyDragCursor.end()
                        if abs(value.translation.width) < 3 || target == time {
                            dragX = 0
                            if abs(value.translation.width) < 3 { onSeek(time) }
                        } else if copying {
                            // The copy arrives as a diamond of its own.
                            onMove(time, target, true)
                            dragX = 0
                        } else {
                            onMove(time, target, false)
                            Task { @MainActor in
                                // In case the move was refused and this
                                // diamond stays.
                                try? await Task.sleep(for: .milliseconds(500))
                                dragX = 0
                            }
                        }
                    }
            )
            .contextMenu {
                KeyframeEaseMenuItems { onEase(time, $0) }
                Divider()
                Button("Delete Keyframe", role: .destructive) { onDelete(time) }
            }
            .help(time.formatted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(mark.isGenerated ? "Generated keyframe" : "Keyframe") at \(time.formatted)")
            .accessibilityValue(easeDescription)
            .accessibilityAddTraits(isAtPlayhead ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Moves the playhead to it")
            .accessibilityAction { onSeek(time) }
            .accessibilityActions {
                ForEach(KeyframeEase.Preset.allCases) { preset in
                    Button(preset.name) { onEase(time, preset) }
                }
                Button("Delete keyframe") { onDelete(time) }
            }
    }

    private var easeDescription: String {
        if mark.holds { return mark.easedIn ? "eased in, holds" : "holds" }
        switch (mark.easedIn, mark.easedOut) {
        case (false, false): return "linear"
        case (true, false): return "eased in"
        case (false, true): return "eased out"
        case (true, true): return "eased in and out"
        }
    }

    private func target(_ translation: CGFloat) -> CMTime {
        snap(CMTimeAdd(time, CMTime(seconds: Double(translation / pixelsPerSecond), preferredTimescale: 48_000)))
    }
}
