import CoreMedia
import SwiftUI

/// The clips media dragged from the browser would make on a layer, drawn
/// where they would land while the drag is over the layer. A view of its
/// own, so following the pointer redraws only it, not the layer's clips.
struct LayerDropPreview: View {
    let project: EditingProject
    let timelineID: UUID
    let layerID: UUID
    let pixelsPerSecond: CGFloat
    let height: CGFloat

    var body: some View {
        let session = MediaDragSession.shared
        if let target = session.target, target.layerID == layerID,
           let clips = project.landing(of: session.pieces, onLayer: layerID, in: timelineID, at: target.time) {
            ZStack(alignment: .topLeading) {
                ForEach(clips) { clip in
                    block(clip)
                        .frame(width: max(2, CGFloat(CMTimeSubtract(clip.endOffset, clip.startOffset).seconds) * pixelsPerSecond), height: height)
                        .offset(x: CGFloat(clip.startOffset.seconds) * pixelsPerSecond)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func block(_ clip: TimelineClip) -> some View {
        let media = project.resolvedInfo(for: clip.source)
        let tone = media.map { Design.ClipTone.of($0, streams: .videoAndAudio).color } ?? Design.accent
        return RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
            .fill(tone.opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Design.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .overlay(alignment: .topLeading) {
                Text(media?.name ?? "")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textOnColor)
                    .lineLimit(1)
                    .padding(4)
            }
    }
}
