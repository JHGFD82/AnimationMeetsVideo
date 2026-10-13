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
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
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
