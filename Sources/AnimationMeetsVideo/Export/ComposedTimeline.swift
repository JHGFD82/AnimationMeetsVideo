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
    var audioTracks: [ComposedAudioTrack] = []
    /// When `cachedKeys` isn't empty, the video composition drawing every
    /// stretch from its clips instead of its render.
    var unrenderedVideoComposition: AVMutableVideoComposition?

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

    /// The same timeline with every stretch keeping the frame `capture` is
    /// armed for (see `SourceCapture`), for the viewer to draw it again
    /// with new values. Both video compositions are copied; this one is
    /// left as it is.
    func capturing(into capture: SourceCapture) -> ComposedTimeline {
        func copy(_ videoComposition: AVMutableVideoComposition?) -> AVMutableVideoComposition? {
            guard let copy = videoComposition?.mutableCopy() as? AVMutableVideoComposition else { return videoComposition }
            copy.instructions = copy.instructions.map { instruction in
                (instruction as? LayeredInstruction).map { $0.drawing($0.clips, capture: capture) } ?? instruction
            }
            return copy
        }
        var result = self
        result.videoComposition = copy(videoComposition)
        result.unrenderedVideoComposition = copy(unrenderedVideoComposition)
        return result
    }

    /// The pixel format the viewer's compositor draws this timeline in:
    /// 8-bit for SDR timelines (`SDRLayeredCompositor`), half floats
    /// otherwise. The viewer's video output asks for the same, so the
    /// frames it hands over are the compositor's own, unconverted, and the
    /// same as a frame drawn again from them (`FrameRedrawer`).
    var viewerPixelFormat: OSType {
        (videoComposition?.customVideoCompositorClass as? LayeredCompositor.Type)?.pixelFormat ?? kCVPixelFormatType_32BGRA
    }

    /// The video composition drawn at `scale` of the timeline's frame size,
    /// for the viewer. Only one built for preview can be drawn smaller: its
    /// instructions keep the frame size and scale into whatever size the
    /// player asks for.
    func videoComposition(scaledBy scale: Double, withoutRenders: Bool = false) -> AVVideoComposition? {
        guard hasPictures else { return nil }
        let videoComposition = withoutRenders ? unrenderedVideoComposition ?? videoComposition : videoComposition
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

/// One audio track of a composition and how it is mixed.
struct ComposedAudioTrack {
    var track: AVAssetTrack
    /// The volumes, pans, fades and sound effects it plays through,
    /// innermost first.
    var stages: [MixStage]
    /// How retimed sound is played, if it is.
    var pitch: AVAudioTimePitchAlgorithm?
    /// How much earlier than it is heard its sound is placed, in seconds:
    /// the delay of the sound effects it plays through, which put it back.
    var latency: Double = 0
}
