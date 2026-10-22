import CoreMedia
import SwiftUI

/// A point on a retimed clip's bar where its speed is read out.
struct RetimeMark: Equatable {
    /// Timeline seconds from the start of the clip.
    var seconds: Double
    /// The speed there, as a percentage.
    var speed: Double

    /// The readout's marks for `clip`: the speed where it starts, then
    /// every speed keyframe inside it. Empty if it plays at its source's
    /// own speed.
    static func marks(of clip: TimelineClip) -> [RetimeMark] {
        guard clip.isRetimed else { return [] }
        // Backwards, the clip starts at the end of its trim.
        var marks = [RetimeMark(seconds: 0, speed: clip.speed(atSource: clip.isReversed ? clip.trimEnd : clip.trimStart))]
        for keyframe in clip.time.speed.keyframes where keyframe.time > clip.trimStart && keyframe.time < clip.trimEnd {
            marks.append(RetimeMark(
                seconds: CMTimeSubtract(clip.timelineTime(forSourceTime: keyframe.time), clip.startOffset).seconds,
                speed: clip.speed(atSource: keyframe.time)
            ))
        }
        return marks.sorted { $0.seconds < $1.seconds }
    }

    /// Whether the speed changes gradually from this mark to `next`.
    func ramps(to next: RetimeMark) -> Bool { abs(speed - next.speed) > 0.05 }
}

/// A retimed clip's speed along its bar: a bar, a space and the speed at
/// each point it is set, with a stretched arrow to the next point where
/// the speed ramps to a different value. Each reading sits on a faint dark
/// shade, so it stays legible over the clip's thumbnails.
struct RetimeStrip: View {
    let marks: [RetimeMark]
    let pixelsPerSecond: CGFloat
    /// How far the drawn part of the bar starts after the clip's start.
    let inset: CGFloat
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                let x = CGFloat(mark.seconds) * pixelsPerSecond - inset
                let next = index + 1 < marks.count ? marks[index + 1] : nil
                let end = next.map { CGFloat($0.seconds) * pixelsPerSecond - inset } ?? width
                HStack(spacing: 3) {
                    Text("| \(NumericExpression.format(mark.speed, maxFractionDigits: 1))%")
                        .font(Design.Typeface.numericMicro)
                        .lineLimit(1)
                        .fixedSize()
                    if let next, mark.ramps(to: next) {
                        StretchedArrow()
                            .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                            .frame(minWidth: 6, maxWidth: .infinity)
                            .frame(height: 8)
                            .padding(.trailing, 3)
                    }
                }
                .padding(.horizontal, 2)
                .background(Design.bevelShade, in: RoundedRectangle(cornerRadius: 2))
                .padding(.trailing, 1)
                .frame(width: max(0, end - x), alignment: .leading)
                .clipped()
                .offset(x: x)
            }
        }
        .foregroundStyle(Design.textOnColor.opacity(0.85))
        .frame(width: width, alignment: .leading)
        .allowsHitTesting(false)
    }
}

/// A line the length of its frame with an arrowhead at its right end.
private struct StretchedArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.move(to: CGPoint(x: rect.maxX - 4, y: rect.midY - 3))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.midY + 3))
        return path
    }
}
