import AVFoundation
import CoreMedia

/// A composition plus the video-compositing instructions needed to stack
/// its layers — shared by both the live preview player and file export, so
/// what you see while editing is exactly what gets rendered out.
/// Not mutated once built, so it can be handed to a background render.
struct ComposedTimeline: @unchecked Sendable {
    var composition: AVMutableComposition
    var videoComposition: AVMutableVideoComposition?
    /// The timeline split where what is drawn changes, in order.
    var segments: [RenderSegment] = []
    /// Keys of the segments drawn from the render cache.
    var cachedKeys: Set<String> = []
    /// Each audio track, with the layers whose volumes it plays through.
    var audioTracks: [(track: AVAssetTrack, stages: [MixStage], pitch: AVAudioTimePitchAlgorithm?)] = []

    /// A mix that plays each audio track at its layers' volumes, read from
    /// `curves` as it plays, and measures the result into `meter`.
    func audioMix(curves: MixCurves, meter: MixLevelMeter? = nil) -> AVAudioMix? {
        audioTracks.isEmpty ? nil : AudioLevelTap.audioMix(for: audioTracks, curves: curves, meter: meter)
    }

    /// Whether the composition has a video track to draw. A timeline of
    /// sound alone has none, and asking `AVAssetImageGenerator` for a frame
    /// of it raises an Objective-C exception that ends the app, so every
    /// frame request checks this first.
    var hasPictures: Bool { !composition.tracks(withMediaType: .video).isEmpty }

    /// The video composition drawn at `scale` of the timeline's frame size,
    /// for the viewer. Only one built for preview can be drawn smaller: its
    /// instructions keep the frame size and scale into whatever size the
    /// player asks for.
    func videoComposition(scaledBy scale: Double) -> AVVideoComposition? {
        guard hasPictures else { return nil }
        guard let videoComposition, scale != 1,
              let scaled = videoComposition.mutableCopy() as? AVMutableVideoComposition
        else {
            return videoComposition
        }
        // Even sizes, which every pixel format accepts.
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        scaled.renderSize = CGSize(width: even(videoComposition.renderSize.width), height: even(videoComposition.renderSize.height))
        return scaled
    }
}
