import CoreMedia
import SwiftUI

/// A keyframe as the lane draws it: where, and which sides are eased.
struct KeyframeMark: Hashable {
    var time: CMTime
    var easedIn: Bool
    var easedOut: Bool
}

extension AnimatedValue {
    var marks: [KeyframeMark] {
        keyframes.map { KeyframeMark(time: $0.time, easedIn: $0.easeIn != nil, easedOut: $0.easeOut != nil) }
    }
}

/// A property's keyframes as diamonds under the layer's clips, each side
/// pinched like an hourglass where it is eased. Clicking a diamond moves
/// the playhead to it; dragging retimes it, snapping to frames; its menu
/// sets its ease.
struct KeyframeLane: View {
    let marks: [KeyframeMark]
    let currentTime: CMTime
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    let snap: (CMTime) -> CMTime
    let onSeek: (CMTime) -> Void
    let onMove: (CMTime, CMTime) -> Void
    let onDelete: (CMTime) -> Void
    let onEase: (CMTime, KeyframeEase.Preset) -> Void

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
                    onEase: onEase
                )
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// A keyframe's mark: a diamond, with each eased side pinched in so the
/// two together read as an hourglass, as in After Effects.
struct KeyframeMarkShape: Shape {
    var easedIn: Bool
    var easedOut: Bool

    func path(in rect: CGRect) -> Path {
        let pinch = rect.width * 0.18
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        if easedOut {
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
    let onMove: (CMTime, CMTime) -> Void
    let onDelete: (CMTime) -> Void
    let onEase: (CMTime, KeyframeEase.Preset) -> Void

    private var time: CMTime { mark.time }

    /// Where the diamond is dragged to, on its snapped frame. After a drop
    /// it stays there until the moved keyframe comes back from the project
    /// and replaces this diamond, so the old place never shows for a frame.
    @State private var dragX: CGFloat = 0

    private let size: CGFloat = 12

    var body: some View {
        let x = CGFloat(time.seconds) * pixelsPerSecond + dragX
        let shape = KeyframeMarkShape(easedIn: mark.easedIn, easedOut: mark.easedOut)
        shape
            .fill(isAtPlayhead ? Design.keyframe : Design.textSecondary)
            .overlay { shape.stroke(Color.black.opacity(0.45), lineWidth: 0.5) }
            .frame(width: size, height: size)
            .frame(width: size + 6, height: height)
            .contentShape(Rectangle())
            .offset(x: x - (size + 6) / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard abs(value.translation.width) >= 3 else { return }
                        dragX = CGFloat(CMTimeSubtract(target(value.translation.width), time).seconds) * pixelsPerSecond
                    }
                    .onEnded { value in
                        let target = target(value.translation.width)
                        if abs(value.translation.width) < 3 || target == time {
                            dragX = 0
                            if abs(value.translation.width) < 3 { onSeek(time) }
                        } else {
                            onMove(time, target)
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
            .accessibilityLabel("Keyframe at \(time.formatted)")
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
        switch (mark.easedIn, mark.easedOut) {
        case (false, false): "linear"
        case (true, false): "eased in"
        case (false, true): "eased out"
        case (true, true): "eased in and out"
        }
    }

    private func target(_ translation: CGFloat) -> CMTime {
        snap(CMTimeAdd(time, CMTime(seconds: Double(translation / pixelsPerSecond), preferredTimescale: 48_000)))
    }
}
