import CoreMedia
import SwiftUI

/// Pictures of a video clip's footage along it on the timeline: one
/// thumbnail per tile of the clip, each the frame played where the tile
/// starts (so a retimed or reversed clip shows what it plays there). Only
/// the drawn part of the clip is tiled, since a clip zoomed far in can be
/// far wider than the window. Tiles are counted from where the footage's
/// first frame would play, so scrolling doesn't change which frames they
/// show and trimming either end cuts into them rather than moving them;
/// a retimed or reversed clip counts from its start instead.
struct ClipThumbnails: View {
    /// The clip as drawn (a drag's preview included).
    let clip: TimelineClip
    let media: MediaClip
    let pixelsPerSecond: CGFloat
    /// Where the clip starts, and the stretch of it that is drawn, in the
    /// row's points.
    let liveX: CGFloat
    let drawnX: CGFloat
    let width: CGFloat
    let height: CGFloat
    /// Off, the pictures are drawn grey, as the clip plays as a gap.
    var enabled = true
    /// Off while the clip is dragged: no picture is read until it is let
    /// go, and the tiles keep what they show (see `FilmstripThumbnail`).
    var loads = true

    /// The shortest band of pictures worth drawing.
    static let minimumHeight: CGFloat = 22

    /// Frames are asked for on a tenth-of-a-second grid, so small zoom
    /// changes reuse the pictures already made.
    private static let grid = 10.0

    var body: some View {
        let tile = (height * 16 / 9).rounded()
        let into = drawnX - originX
        let first = Int((into / tile).rounded(.down))
        let last = Int(((into + width) / tile).rounded(.up))
        ZStack(alignment: .topLeading) {
            if let url = media.url, last > first {
                ForEach(first..<last, id: \.self) { index in
                    FilmstripThumbnail(url: url, time: time(atTile: index, width: tile), height: height, keepsPictureWhileLoading: true, loads: loads)
                        .frame(width: tile, height: height)
                        .clipped()
                        .offset(x: CGFloat(index) * tile - into)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        // Grey through a wash only there while turned off, rather than a
        // filter on every clip's pictures, or a modifier that would make
        // the tiles anew (and load their pictures again) on each toggle.
        .overlay {
            if !enabled {
                Rectangle().fill(.gray).blendMode(.saturation)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where tile 0 starts, in the row's points.
    private var originX: CGFloat {
        guard !clip.isRetimed, !clip.isReversed else { return liveX }
        return clip.timelineTime(forSourceTime: .zero).seconds * pixelsPerSecond
    }

    /// The file time played where tile `index` starts.
    private func time(atTile index: Int, width tile: CGFloat) -> CMTime {
        let x = originX + CGFloat(index) * tile
        let along = CMTime(seconds: Double((x - liveX) / pixelsPerSecond), preferredTimescale: 600)
        let source = clip.sourceTime(atTimelineTime: CMTimeAdd(clip.startOffset, along))
        let seconds = (media.fileTime(forSourceTime: source).seconds * Self.grid).rounded() / Self.grid
        return CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }
}
