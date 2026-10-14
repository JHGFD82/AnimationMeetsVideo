import CoreMedia
import SwiftUI

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
            Color.black.opacity(0.18)
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

    /// Where the diamond is dragged to, on its snapped frame. After a drop
    /// it stays there until the moved keyframe comes back from the project
    /// and replaces this diamond, so the old place never shows for a frame.
    @State private var dragX: CGFloat = 0

    private let size: CGFloat = 9

    var body: some View {
        let x = CGFloat(time.seconds) * pixelsPerSecond + dragX
        Rectangle()
            .fill(isAtPlayhead ? Design.keyframe : Design.textSecondary)
            .overlay {
                Rectangle()
                    .strokeBorder(Color.black.opacity(0.45), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
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
                Button("Delete Keyframe", role: .destructive) { onDelete(time) }
            }
            .help(time.formatted)
    }

    private func target(_ translation: CGFloat) -> CMTime {
        snap(CMTimeAdd(time, CMTime(seconds: Double(translation / pixelsPerSecond), preferredTimescale: 48_000)))
    }
}
