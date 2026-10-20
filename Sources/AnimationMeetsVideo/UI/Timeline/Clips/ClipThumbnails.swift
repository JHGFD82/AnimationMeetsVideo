import CoreMedia
import SwiftUI

/// Pictures of a video clip's footage along it on the timeline: one
/// thumbnail per tile of the clip, each the frame played where the tile
/// starts (so a retimed or reversed clip shows what it plays there). Only
/// the drawn part of the clip is tiled, since a clip zoomed far in can be
/// far wider than the window. Tiles are counted from the clip's start, so
/// scrolling doesn't change which frames they show.
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

    /// The shortest band of pictures worth drawing.
    static let minimumHeight: CGFloat = 22

    /// Frames are asked for on a tenth-of-a-second grid, so small zoom
    /// changes reuse the pictures already made.
    private static let grid = 10.0

    var body: some View {
        let tile = (height * 16 / 9).rounded()
        let into = drawnX - liveX
        let first = max(0, Int((into / tile).rounded(.down)))
        let last = Int(((into + width) / tile).rounded(.up))
        ZStack(alignment: .topLeading) {
            if let url = media.url, last > first {
                ForEach(first..<last, id: \.self) { index in
                    FilmstripThumbnail(url: url, time: time(atTile: index, width: tile), height: height, keepsPictureWhileLoading: true)
                        .frame(width: tile, height: height)
                        .clipped()
                        .offset(x: CGFloat(index) * tile - into)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The file time played where tile `index` starts.
    private func time(atTile index: Int, width tile: CGFloat) -> CMTime {
        let along = CMTime(seconds: Double(CGFloat(index) * tile / pixelsPerSecond), preferredTimescale: 600)
        let source = clip.sourceTime(atTimelineTime: CMTimeAdd(clip.startOffset, along))
        let seconds = (media.fileTime(forSourceTime: source).seconds * Self.grid).rounded() / Self.grid
        return CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }
}
