import CoreMedia
import SwiftUI

/// Where a clip is tied to the music, and the line through it that shows
/// the moment.
extension ClipBlockView {
    // MARK: Music point

    /// Where the clip is tied to the music, in timeline time: the frame
    /// that plays on the song's moment (see `MusicAttachment`). Nil while
    /// it isn't attached, and for songs.
    func musicPointTime(of clip: TimelineClip) -> CMTime? {
        guard handlers.onSetMusicPoint != nil, let music = clip.music else { return nil }
        return clip.timelineTime(forSourceTime: clip.musicFrame(music.frame))
    }

    /// A time held to the clip's frames: from its first to its last.
    func clampedMusicPoint(_ time: CMTime) -> CMTime {
        let last = CMTimeSubtract(model.clip.endOffset, Timeline.frameDuration(for: model.frameRate))
        return CMTimeMaximum(model.clip.startOffset, CMTimeMinimum(handlers.snap(time), CMTimeMaximum(model.clip.startOffset, last)))
    }

    /// The music point, as a line through the clip at the frame tied to
    /// the music with a point at its foot, toward the Music area below; the
    /// selected clip's point is a knob that drags it to another frame,
    /// snapping to beats and edges as the blade does. On a song, the
    /// selected clips' points are marked where they hold on, with the
    /// point at the top, toward the footage.
    @ViewBuilder
    func musicLinkMarks(of shown: TimelineClip) -> some View {
        if let time = musicPointDraft ?? musicPointTime(of: shown) {
            let x = time.seconds * model.pixelsPerSecond
            if x >= model.visibleX.lowerBound - 8, x <= model.visibleX.upperBound + 8 {
                MusicLinkMark(height: model.height, pointAtTop: false, emphasized: model.isSelected)
                    .offset(x: x - MusicLinkMark.width / 2)
                if model.isSelected, !model.isInGroup, model.tool == .arrow {
                    Color.clear
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                        .offset(x: x - 7, y: model.height - 14)
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                                .onChanged { value in
                                    let time = CMTime(seconds: Double(max(0, value.location.x) / model.pixelsPerSecond), preferredTimescale: EditingProject.audioPlacementTimescale)
                                    let draft = clampedMusicPoint(handlers.snapTime(time) ?? time)
                                    musicPointDraft = draft
                                    if let origin = musicPointTime(of: model.clip) { readout?.show(draft, from: origin) }
                                }
                                .onEnded { _ in
                                    readout?.hide()
                                    guard let draft = musicPointDraft else { return }
                                    if draft == musicPointTime(of: model.clip) {
                                        musicPointDraft = nil
                                    } else {
                                        handlers.onSetMusicPoint?(draft)
                                    }
                                }
                        )
                        .help("Music point: drag to tie another frame to the music")
                }
            }
        }
        ForEach(Array(model.musicMarks.enumerated()), id: \.offset) { _, time in
            MusicLinkMark(height: model.height, pointAtTop: true, emphasized: true)
                .offset(x: time.seconds * model.pixelsPerSecond - MusicLinkMark.width / 2)
        }
    }
}

/// A line through a clip where it is tied to the music, with a point at
/// one end: drawn only, the knob that drags it is the block's.
struct MusicLinkMark: View {
    static let width: CGFloat = 9
    let height: CGFloat
    /// At the top on a song, toward the footage tied to it; at the foot on
    /// footage, toward its song.
    let pointAtTop: Bool
    /// Brighter and with a larger point on the selected clip.
    let emphasized: Bool

    var body: some View {
        let point: CGFloat = emphasized ? 9 : 6
        ZStack(alignment: pointAtTop ? .top : .bottom) {
            Rectangle()
                .fill(Design.musicLink.opacity(emphasized ? 1 : 0.75))
                .frame(width: emphasized ? 1.5 : 1, height: height)
            Circle()
                .fill(Design.musicLink)
                .overlay { Circle().strokeBorder(.black.opacity(0.55), lineWidth: 1) }
                .frame(width: point, height: point)
                .padding(pointAtTop ? .top : .bottom, 1)
        }
        .frame(width: Self.width, height: height)
        .shadow(color: .black.opacity(0.5), radius: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
