import CoreMedia
import SwiftUI

/// The sound of a layer's video clips, shown under the clips when the layer's
/// waveform button is on. Each block sits under the clip it belongs to and
/// moves with it; detaching makes it a clip of its own.
struct LinkedAudioLane: View {
    let layer: TimelineLayer
    let project: EditingProject
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// Draws each block's channels apart.
    let showsChannels: Bool
    let visibleX: ClosedRange<CGFloat>
    let onSelectClip: (TimelineClip) -> Void
    let onDetachAudio: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layer.clips.filter { project.hasLinkedAudio($0) }) { clip in
                let x = clip.startOffset.seconds * pixelsPerSecond
                let clipWidth = max(2, clip.placedDuration.seconds * pixelsPerSecond)
                let drawnMinX = max(x, visibleX.lowerBound - 4)
                let drawnMaxX = min(x + clipWidth, visibleX.upperBound + 4)
                if drawnMaxX > drawnMinX {
                    let tone = Design.ClipTone.audio.color
                    HStack(spacing: Design.Space.tight) {
                        Image(systemName: "waveform")
                        Text("Linked audio")
                            .lineLimit(1)
                    }
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textOnColor.opacity(0.9))
                    .padding(.leading, Design.Space.close)
                    .frame(width: drawnMaxX - drawnMinX, height: height, alignment: .leading)
                    .background { waveform(of: clip, drawnMinX: drawnMinX, clipX: x, width: drawnMaxX - drawnMinX) }
                    .background(Design.clipFill(tone, selected: false))
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                            .strokeBorder(Design.bevelEdge, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectClip(clip) }
                    .contextMenu {
                        Button("Detach Audio") { onDetachAudio(clip.id) }
                    }
                    .offset(x: drawnMinX)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    /// The drawn part of a block's sound, as on a clip of sound alone.
    @ViewBuilder
    private func waveform(of clip: TimelineClip, drawnMinX: CGFloat, clipX: CGFloat, width: CGFloat) -> some View {
        if showsChannels || ClipWaveform.strength(atHeight: height) > 0,
           case .media(let media) = project.resolvedInfo(for: clip.source), let url = media.url {
            let sourceStart = clip.sourceTime(atTimelineTime: CMTimeAdd(clip.startOffset, CMTime(seconds: Double((drawnMinX - clipX) / pixelsPerSecond), preferredTimescale: 600)))
            ClipWaveform(
                url: url,
                fileStart: media.fileTime(forSourceTime: sourceStart).seconds,
                secondsPerPoint: clip.speed(atSource: clip.trimStart) / 100 / Double(pixelsPerSecond),
                width: width,
                height: height,
                splitsChannels: showsChannels
            )
        }
    }
}
