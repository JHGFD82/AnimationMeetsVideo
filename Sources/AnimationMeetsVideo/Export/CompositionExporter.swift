import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

enum ProResPreset: String, CaseIterable, Identifiable {
    case proRes422 = "ProRes 422"
    case proRes4444 = "ProRes 4444"

    var id: Self { self }

    /// Whether exports in this format may use the render cache, whose
    /// renders are ProRes 422.
    var reusesRenders: Bool { self == .proRes422 }

    var avPresetName: String {
        switch self {
        case .proRes422: AVAssetExportPresetAppleProRes422LPCM
        case .proRes4444: AVAssetExportPresetAppleProRes4444LPCM
        }
    }
}

enum CompositionError: LocalizedError {
    case emptyTimeline
    case cyclicTimeline
    case incompatiblePreset
    case noExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: "The timeline has no clips to export."
        case .cyclicTimeline: "This timeline embeds itself, directly or indirectly."
        case .incompatiblePreset: "The selected ProRes preset can't export this timeline."
        case .noExportSession: "Could not create an export session."
        case .exportFailed(let reason): reason
        }
    }
}

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
    var audioTracks: [(track: AVAssetTrack, stages: [VolumeStage])] = []

    /// A mix that plays each audio track at its layers' volumes, read from
    /// `curves` as it plays, and measures the result into `meter`.
    func audioMix(curves: VolumeCurves, meter: MixLevelMeter? = nil) -> AVAudioMix? {
        audioTracks.isEmpty ? nil : AudioLevelTap.audioMix(for: audioTracks, curves: curves, meter: meter)
    }

    /// The video composition drawn at `scale` of the timeline's frame size,
    /// for the viewer. Only one built for preview can be drawn smaller: its
    /// instructions keep the frame size and scale into whatever size the
    /// player asks for.
    func videoComposition(scaledBy scale: Double) -> AVVideoComposition? {
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

/// Track metadata for one media file, loaded once and reused across the many
/// rebuilds an editing session triggers.
private struct MediaTrackInfo: @unchecked Sendable {
    let asset: AVURLAsset
    let video: AVAssetTrack?
    let audio: AVAssetTrack?
    let videoRange: CMTimeRange
    let audioRange: CMTimeRange
    /// The track's preferredTransform shifted so the rotated frame's origin
    /// is (0, 0), and the size of the frame after rotation.
    let orientedTransform: CGAffineTransform
    let orientedSize: CGSize
}

private actor MediaTrackCache {
    static let shared = MediaTrackCache()
    private var entries: [URL: MediaTrackInfo] = [:]

    func forget(_ url: URL) {
        entries[url] = nil
    }

    func info(for url: URL) async throws -> MediaTrackInfo {
        if let cached = entries[url] { return cached }

        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first

        var videoRange = CMTimeRange.invalid
        var audioRange = CMTimeRange.invalid
        var transform = CGAffineTransform.identity
        var size = CGSize.zero
        if let video {
            videoRange = try await video.load(.timeRange)
            let natural = try await video.load(.naturalSize)
            let preferred = try await video.load(.preferredTransform)
            let rect = CGRect(origin: .zero, size: natural).applying(preferred)
            transform = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            size = rect.size
        }
        if let audio {
            audioRange = try await audio.load(.timeRange)
        }

        let info = MediaTrackInfo(
            asset: asset,
            video: video,
            audio: audio,
            videoRange: videoRange,
            audioRange: audioRange,
            orientedTransform: transform,
            orientedSize: size
        )
        entries[url] = info
        return info
    }
}

/// A clip's stack as seen from the root timeline: one nesting level of a
/// placement's animation.
struct TransformStage {
    var effects: [Effect]
    var anchorPoint: AnimatedValue<Vector2>
    /// Center of the frame of the timeline the clip is in.
    var center: CGPoint
    /// Root time minus that timeline's time.
    var shift: CMTime
    /// The clip's start in its timeline minus its trim start: its source
    /// time is its timeline's time minus this, and its keyframes count in
    /// source time.
    var sourceShift: CMTime
    /// Fits that timeline's frame into the frame of the next stage out
    /// (identity at the root).
    var toOuter: CGAffineTransform
    /// The clip's transitions, in that timeline's time, applied after its
    /// stack.
    var edges: EdgeTransitions? = nil

    init(clip: TimelineClip, center: CGPoint, shift: CMTime, toOuter: CGAffineTransform, edges: EdgeTransitions? = nil) {
        self.init(
            effects: clip.effects, anchorPoint: clip.anchorPoint, center: center, shift: shift,
            sourceShift: CMTimeSubtract(clip.startOffset, clip.trimStart), toOuter: toOuter, edges: edges
        )
    }

    init(effects: [Effect], anchorPoint: AnimatedValue<Vector2>, center: CGPoint, shift: CMTime, sourceShift: CMTime, toOuter: CGAffineTransform, edges: EdgeTransitions? = nil) {
        self.effects = effects
        self.anchorPoint = anchorPoint
        self.center = center
        self.shift = shift
        self.sourceShift = sourceShift
        self.toOuter = toOuter
        self.edges = edges
    }

    /// `inner` carried out through this stage: the clip's stack, its
    /// transitions, then into the next stage's frame.
    func outward(_ inner: CGAffineTransform, at time: CMTime) -> CGAffineTransform {
        placed(inner, at: CMTimeSubtract(time, shift)).concatenating(toOuter)
    }

    /// The stack's placement and opacity at its timeline's time `local`.
    func folded(at local: CMTime) -> FoldedPlacement {
        StackFolding.fold(effects: effects, anchorPoint: anchorPoint, at: CMTimeSubtract(local, sourceShift), center: center)
    }

    /// `inner` in this stage's own frame at its own time `local`.
    fileprivate func placed(_ inner: CGAffineTransform, at local: CMTime) -> CGAffineTransform {
        let layered = inner.concatenating(folded(at: local).matrix)
        guard let edges else { return layered }
        return layered.concatenating(edges.effect(at: local).transform)
    }

    /// The times in this stage's timeline when the stack is between keyframes.
    var animatedRanges: [ClosedRange<CMTime>] {
        (effects.flatMap(\.animatedRanges) + [anchorPoint.animatedRange].compactMap { $0 }).map {
            CMTimeAdd($0.lowerBound, sourceShift)...CMTimeAdd($0.upperBound, sourceShift)
        }
    }
}

/// Where a placement is drawn and how opaque it is at each root time: its
/// own fit, then each enclosing layer's transform from innermost out.
struct PlacementAnimation {
    /// Orients and fits the media into the frame of its own timeline.
    var base: CGAffineTransform
    var stages: [TransformStage]

    func transform(at time: CMTime) -> CGAffineTransform {
        stages.reduce(base) { result, stage in stage.outward(result, at: time) }
    }

    func opacity(at time: CMTime) -> Float {
        Float(stages.reduce(1.0) { result, stage in
            let local = CMTimeSubtract(time, stage.shift)
            let fade = stage.edges?.effect(at: local).opacity ?? 1
            return result * stage.folded(at: local).opacity * fade
        })
    }

    /// Whether a film dissolve plays, which only `LayeredCompositor` can draw.
    var hasLumaReveal: Bool {
        stages.contains { $0.edges?.hasLumaReveal == true }
    }

    /// The film dissolve playing at `time`, innermost first, if any.
    func lumaReveal(at time: CMTime) -> LumaReveal? {
        for stage in stages {
            if let reveal = stage.edges?.effect(at: CMTimeSubtract(time, stage.shift)).lumaReveal { return reveal }
        }
        return nil
    }

    /// Whether a wipe ever crops the media, so a crop must be set.
    var hasCrop: Bool {
        stages.contains { $0.edges?.hasWipe == true }
    }

    /// The part of the media's own frame (before orientation) to draw at
    /// `time`: each wipe's visible part of its timeline's frame, mapped back
    /// through everything that places the media there. Nil without wipes.
    func cropRectangle(at time: CMTime) -> CGRect? {
        var crop: CGRect?
        var inner = base
        for stage in stages {
            let local = CMTimeSubtract(time, stage.shift)
            let placed = stage.placed(inner, at: local)
            if let visible = stage.edges?.effect(at: local).visibleRect {
                // A transform scaled to nothing shows nothing anyway.
                if abs(placed.a * placed.d - placed.b * placed.c) > 1e-9 {
                    let rect = visible.applying(placed.inverted())
                    crop = crop.map { $0.intersection(rect) } ?? rect
                }
            }
            inner = placed.concatenating(stage.toOuter)
        }
        if let cropped = crop, cropped.isNull { return .zero }
        return crop
    }

    /// Root-time ranges where some stage is between keyframes, in order and
    /// not overlapping. Outside them the transform and opacity are constant.
    var animatedRanges: [CMTimeRange] {
        let ranges = stages.flatMap { stage in
            let keyframed = stage.animatedRanges.map { range in
                CMTimeRange(start: CMTimeAdd(range.lowerBound, stage.shift), end: CMTimeAdd(range.upperBound, stage.shift))
            }
            let transitions = (stage.edges?.animatedRanges ?? []).map { range in
                CMTimeRange(start: CMTimeAdd(range.start, stage.shift), duration: range.duration)
            }
            return keyframed + transitions
        }
        var merged: [CMTimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = CMTimeRange(start: last.start, end: CMTimeMaximum(last.end, range.end))
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// One piece of media placed at an absolute time in the root timeline, with
/// the animation that places it in the root's render space.
private struct Placement {
    let info: MediaTrackInfo
    let sourceRange: CMTimeRange
    let start: CMTime
    let animation: PlacementAnimation
    /// Which of the file's streams to use; detached audio and its picture
    /// each play only one.
    var includesVideo: Bool
    var includesAudio: Bool
    /// The clip in the built timeline it belongs to: the clip itself, or
    /// the nested timeline's clip it is drawn through.
    let owner: UUID
}

/// An ordered run of non-overlapping placements that share composition
/// tracks. Nested timelines are flattened into extra layers of the root.
private struct FlatLayer {
    var placements: [Placement] = []
    /// The layer it came from, then the layers that timeline is nested
    /// in, whose volumes all apply to its sound.
    var volume: [VolumeStage] = []
}

private struct VideoSegment {
    let timeRange: CMTimeRange
    let animation: PlacementAnimation
    let sourceURL: URL
    /// The file time drawn at `timeRange.start`.
    let sourceStart: CMTime
    let owner: UUID
}

/// A stretch of the timeline with the layers that show in it, top first.
private struct PlannedRange {
    var range: CMTimeRange
    var shown: [(layer: VideoLayer, segment: VideoSegment)]
    var segment: RenderSegment
}

private struct VideoLayer {
    let track: AVMutableCompositionTrack
    let segments: [VideoSegment]
}

enum CompositionExporter {
    /// Drops what was read from the file at `url`, for when it was replaced
    /// or changed on disk.
    static func forgetCachedMedia(at url: URL) async {
        await MediaTrackCache.shared.forget(url)
    }

    /// With `forPreview` every frame is drawn by `LayeredCompositor`, so the
    /// viewer can draw it at a reduced size and `meter` hears how long each
    /// frame took. Segments already rendered into `cache` play from there.
    static func buildComposedTimeline(
        for project: EditingProject,
        timelineID: UUID,
        forPreview: Bool = false,
        meter: RenderMeter? = nil,
        cache: RenderCache? = nil
    ) async throws -> ComposedTimeline {
        guard let timeline = project.timeline(id: timelineID), !timeline.layers.isEmpty else {
            throw CompositionError.emptyTimeline
        }

        let window = CMTimeRange(start: .zero, duration: timeline.duration)
        let flatLayers = try await flatten(
            project: project,
            timelineID: timelineID,
            visiting: [],
            window: window,
            offset: .zero,
            outer: [],
            outerVolume: [],
            toOuter: .identity,
            rootClipID: nil
        )

        let composition = AVMutableComposition()
        var videoLayers: [VideoLayer] = []
        var audioTracks: [(track: AVAssetTrack, stages: [VolumeStage])] = []
        /// A stretch of some source's picture, to fill time after the last clip.
        var filler: (track: AVAssetTrack, range: CMTimeRange)?

        for flat in flatLayers {
            var videoTrack: AVMutableCompositionTrack?
            var audioTrack: AVMutableCompositionTrack?
            var segments: [VideoSegment] = []

            for placement in flat.placements {
                let info = placement.info
                if let sourceVideo = info.video, placement.includesVideo {
                    let range = placement.sourceRange.intersection(info.videoRange)
                    if range.isValid, range.duration > .zero {
                        if videoTrack == nil {
                            videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        let at = CMTimeAdd(placement.start, CMTimeSubtract(range.start, placement.sourceRange.start))
                        try videoTrack?.insertTimeRange(range, of: sourceVideo, at: at)
                        if filler == nil { filler = (sourceVideo, range) }
                        segments.append(VideoSegment(
                            timeRange: CMTimeRange(start: at, duration: range.duration), animation: placement.animation,
                            sourceURL: info.asset.url, sourceStart: range.start, owner: placement.owner
                        ))
                    }
                }
                if let sourceAudio = info.audio, placement.includesAudio {
                    let range = placement.sourceRange.intersection(info.audioRange)
                    if range.isValid, range.duration > .zero {
                        if audioTrack == nil {
                            audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        let at = CMTimeAdd(placement.start, CMTimeSubtract(range.start, placement.sourceRange.start))
                        try audioTrack?.insertTimeRange(range, of: sourceAudio, at: at)
                    }
                }
            }

            if let videoTrack {
                videoLayers.append(VideoLayer(track: videoTrack, segments: segments))
            }
            if let audioTrack {
                audioTracks.append((audioTrack, flat.volume))
            }
        }

        guard composition.duration > .zero else {
            throw CompositionError.emptyTimeline
        }
        // Sections can run past the last clip. A composition ends with its
        // last media (an empty edit at the end doesn't count), so a frame of
        // some source is stretched over the rest on a track of its own. No
        // instruction shows that track, so the stretch plays as black.
        if composition.duration < timeline.duration, let filler,
           let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let gap = CMTimeRange(start: composition.duration, end: timeline.duration)
            let piece = CMTimeRange(start: filler.range.start, duration: CMTimeMinimum(filler.range.duration, frameDuration(for: timeline.frameRate)))
            try track.insertTimeRange(piece, of: filler.track, at: gap.start)
            track.scaleTimeRange(CMTimeRange(start: gap.start, duration: piece.duration), toDuration: gap.duration)
        }

        var plan = planRanges(
            layers: videoLayers, overallDuration: composition.duration,
            frameSize: timeline.frameSize, frameRate: timeline.frameRate, colorSpace: timeline.colorSpace
        )
        var cachedKeys: Set<String> = []
        if let cache {
            cachedKeys = try await substituteCachedRanges(&plan, from: cache, into: composition)
        }

        let videoComposition = Self.buildVideoComposition(
            plan: plan,
            hasLayers: !videoLayers.isEmpty,
            renderSize: timeline.frameSize,
            frameRate: timeline.frameRate,
            colorSpace: timeline.colorSpace,
            layered: forPreview,
            meter: meter
        )
        return ComposedTimeline(
            composition: composition, videoComposition: videoComposition,
            segments: plan.map(\.segment), cachedKeys: cachedKeys, audioTracks: audioTracks
        )
    }

    /// Resolves a timeline (recursively expanding nested timelines) into flat
    /// layers of media placements at absolute root-timeline times, top layer
    /// first. `window` is the visible range in this timeline's own time,
    /// `offset` maps this timeline's time to root time, `outer` holds the
    /// stacks of the clips this timeline is nested in (innermost
    /// first), `outerVolume` their volumes the same way, and `toOuter` fits this timeline's frame into the frame of
    /// the innermost of them.
    private static func flatten(
        project: EditingProject,
        timelineID: UUID,
        visiting: Set<UUID>,
        window: CMTimeRange,
        offset: CMTime,
        outer: [TransformStage],
        outerVolume: [VolumeStage],
        toOuter: CGAffineTransform,
        rootClipID: UUID?
    ) async throws -> [FlatLayer] {
        guard !visiting.contains(timelineID) else {
            throw CompositionError.cyclicTimeline
        }
        guard let timeline = project.timeline(id: timelineID) else { return [] }
        var visiting = visiting
        visiting.insert(timelineID)

        let center = CGPoint(x: timeline.frameSize.width / 2, y: timeline.frameSize.height / 2)
        var result: [FlatLayer] = []
        for layer in timeline.layers {
            // Sound and Music layers act as a fader over their clips' own
            // volumes; video layers have no volume of their own.
            let layerVolume = layer.kind.isAudio ? [VolumeStage(id: layer.id, shift: offset)] : []
            let volume = layerVolume + outerVolume
            let clips = layer.clips.sorted(by: { $0.startOffset < $1.startOffset })
            var own = FlatLayer(volume: volume)
            // The incoming clip's frames before a joined cut, on a track of
            // their own above the layer's, so they can overlap the outgoing
            // clip that is still playing there.
            var overlay = FlatLayer()
            // Frames shown under a transition at a cut, on a track of their
            // own below the layer's so the two can overlap.
            var underlay = FlatLayer()
            // The sound of clips with a volume of their own, each on a track
            // of its own to be played through that volume.
            var clipSound: [FlatLayer] = []
            var nestedLayers: [FlatLayer] = []

            for clip in clips {
                func stage(of clip: TimelineClip, edges: EdgeTransitions? = nil) -> TransformStage {
                    TransformStage(clip: clip, center: center, shift: offset, toOuter: toOuter, edges: edges)
                }
                // The clip's volume counts in its source time.
                let clipVolume = VolumeStage(id: clip.id, shift: CMTimeAdd(offset, CMTimeSubtract(clip.startOffset, clip.trimStart)))
                let hasOwnVolume = clip.volume != AnimatedValue(0.0)
                let lead = project.joinedLead(of: clip, among: clips) ?? .zero
                var clipStage = stage(of: clip)
                if project.playsVideo(clip) {
                    clipStage.edges = EdgeTransitions(clip: clip, frameSize: timeline.frameSize, lead: lead)
                }
                let stages = [clipStage] + outer
                let placed = CMTimeRange(start: CMTimeSubtract(clip.startOffset, lead), end: clip.endOffset)
                let visible = placed.intersection(window)
                guard visible.isValid, visible.duration > .zero else { continue }

                switch clip.source {
                case .media:
                    if var placement = try await mediaPlacement(
                        of: clip, from: clip.trimStart, at: clip.startOffset, for: clip.trimmedDuration,
                        project: project, frameSize: timeline.frameSize, window: window, offset: offset, stages: stages,
                        owner: rootClipID ?? clip.id, includesVideo: clip.streams != .audio, includesAudio: clip.streams != .video
                    ) {
                        if hasOwnVolume, placement.includesAudio {
                            var sound = placement
                            sound.includesVideo = false
                            clipSound.append(FlatLayer(placements: [sound], volume: [clipVolume] + volume))
                            placement.includesAudio = false
                        }
                        own.placements.append(placement)
                    }
                    // Where this clip meets its neighbor at a cut, the
                    // neighbor's frames beyond its trim play underneath the
                    // transition, so a dissolve blends the two clips rather
                    // than passing through what is below the layer. A way in
                    // that joins the clip before may also start before the
                    // cut, playing this clip's frames before its in point.
                    // Without spare frames there is nothing to show, and the
                    // transition plays over the layers below.
                    let durations = clipStage.edges == nil ? (leading: CMTime.zero, trailing: CMTime.zero) : clip.effectiveTransitionDurations(lead: lead)
                    if lead > .zero, let placement = try await mediaPlacement(
                        of: clip, from: CMTimeSubtract(clip.trimStart, lead), at: CMTimeSubtract(clip.startOffset, lead), for: lead,
                        project: project, frameSize: timeline.frameSize, window: window, offset: offset, stages: stages,
                        owner: rootClipID ?? clip.id, includesVideo: true, includesAudio: false
                    ) {
                        overlay.placements.append(placement)
                    }
                    if durations.leading > .zero, let previous = project.predecessor(joining: clip, among: clips),
                       let placement = try await mediaPlacement(
                           of: previous, from: previous.trimEnd, at: clip.startOffset, for: durations.leading,
                           project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                           stages: [stage(of: previous)] + outer, owner: rootClipID ?? clip.id, includesVideo: true, includesAudio: false
                       ) {
                        underlay.placements.append(placement)
                    }
                    if durations.trailing > .zero, let next = project.successor(joining: clip, among: clips),
                       let placement = try await mediaPlacement(
                           of: next, from: CMTimeSubtract(next.trimStart, durations.trailing),
                           at: CMTimeSubtract(clip.endOffset, durations.trailing), for: durations.trailing,
                           project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                           stages: [stage(of: next)] + outer, owner: rootClipID ?? clip.id, includesVideo: true, includesAudio: false
                       ) {
                        underlay.placements.append(placement)
                    }
                case .timeline(let nestedID):
                    guard let nested = project.timeline(id: nestedID) else { continue }
                    // Nested time = this timeline's time - clip.startOffset + clip.trimStart.
                    let shift = CMTimeSubtract(clip.startOffset, clip.trimStart)
                    let nestedWindow = CMTimeRange(start: CMTimeSubtract(visible.start, shift), duration: visible.duration)
                    nestedLayers += try await flatten(
                        project: project,
                        timelineID: nestedID,
                        visiting: visiting,
                        window: nestedWindow,
                        offset: CMTimeAdd(offset, shift),
                        outer: stages,
                        outerVolume: [clipVolume] + volume,
                        toOuter: fitTransform(from: nested.frameSize, to: timeline.frameSize),
                        rootClipID: rootClipID ?? clip.id
                    )
                }
            }

            if !overlay.placements.isEmpty { result.append(overlay) }
            if !own.placements.isEmpty { result.append(own) }
            if !underlay.placements.isEmpty { result.append(underlay) }
            result += clipSound
            result += nestedLayers
        }
        return result
    }

    /// A media clip's frames from `sourceStart` (in its asset's original
    /// time) placed at `placedStart` in the timeline for `duration`, cut to
    /// the window. Nil when it falls outside the window, the clip isn't
    /// media, or its file is missing. Frames past either end of the file
    /// are dropped when the tracks are built.
    private static func mediaPlacement(
        of clip: TimelineClip,
        from sourceStart: CMTime,
        at placedStart: CMTime,
        for duration: CMTime,
        project: EditingProject,
        frameSize: CGSize,
        window: CMTimeRange,
        offset: CMTime,
        stages: [TransformStage],
        owner: UUID,
        includesVideo: Bool,
        includesAudio: Bool
    ) async throws -> Placement? {
        guard case .media(let mediaID) = clip.source,
              let media = project.mediaClip(id: mediaID), let url = media.url
        else {
            return nil
        }
        let visible = CMTimeRange(start: placedStart, duration: duration).intersection(window)
        guard visible.isValid, visible.duration > .zero else { return nil }
        let intoClip = CMTimeSubtract(visible.start, placedStart)
        let info = try await MediaTrackCache.shared.info(for: url)
        let wanted = CMTimeRange(start: media.fileTime(forSourceTime: CMTimeAdd(sourceStart, intoClip)), duration: visible.duration)
        let base = info.orientedTransform
            .concatenating(fitTransform(from: info.orientedSize, to: frameSize))
        return Placement(
            info: info,
            sourceRange: wanted,
            start: CMTimeAdd(visible.start, offset),
            animation: PlacementAnimation(base: base, stages: stages),
            includesVideo: includesVideo,
            includesAudio: includesAudio,
            owner: owner
        )
    }

    /// Scales `source` to fit inside `target` (aspect-preserving) and centers it.
    private static func fitTransform(from source: CGSize, to target: CGSize) -> CGAffineTransform {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .identity }
        let scale = min(target.width / source.width, target.height / source.height)
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
            translationX: (target.width - source.width * scale) / 2,
            y: (target.height - source.height * scale) / 2
        ))
    }

    /// Splits the timeline where any layer's segment starts or ends, and a
    /// layer shows in a stretch only where one of its segments covers all
    /// of it (top layer first). Stretches that need rendering are cut into
    /// pieces of at most `RenderSegment.maxFrames` frames.
    private static func planRanges(
        layers: [VideoLayer],
        overallDuration: CMTime,
        frameSize: CGSize,
        frameRate: Double,
        colorSpace: ProjectColorSpace
    ) -> [PlannedRange] {
        var breakpoints: [CMTime] = [.zero]
        for layer in layers {
            for segment in layer.segments {
                breakpoints.append(segment.timeRange.start)
                breakpoints.append(segment.timeRange.end)
            }
        }
        breakpoints = breakpoints.filter { $0 > .zero && $0 < overallDuration }
        breakpoints.append(.zero)
        breakpoints.sort()
        breakpoints.append(overallDuration)

        let frame = frameDuration(for: frameRate)
        let piece = CMTimeMultiply(frame, multiplier: Int32(RenderSegment.maxFrames))
        var plan: [PlannedRange] = []
        for index in 0..<(breakpoints.count - 1) {
            let whole = CMTimeRange(start: breakpoints[index], end: breakpoints[index + 1])
            guard whole.duration > .zero else { continue }
            let shown = layers.compactMap { layer -> (layer: VideoLayer, segment: VideoSegment)? in
                guard let segment = layer.segments.first(where: { $0.timeRange.start <= whole.start && $0.timeRange.end >= whole.end }) else {
                    return nil
                }
                return (layer, segment)
            }
            let owners = Set(shown.map(\.segment.owner))
            // One layer drawn the same way throughout plays straight from
            // its file; stacking or anything changing over time is rendered.
            let needsRender = whole.duration >= frame && (shown.count > 1 || shown.contains { item in
                item.segment.animation.animatedRanges.contains { animated in
                    let overlap = animated.intersection(whole)
                    return overlap.isValid && overlap.duration > .zero
                }
            })
            guard needsRender else {
                plan.append(PlannedRange(
                    range: whole, shown: shown,
                    segment: RenderSegment(range: whole, key: "", needsRender: false, clipIDs: owners)
                ))
                continue
            }
            var start = whole.start
            while start < whole.end {
                let range = CMTimeRange(start: start, end: CMTimeMinimum(CMTimeAdd(start, piece), whole.end))
                let key = renderKey(
                    for: range, shown: shown, frame: frame,
                    frameSize: frameSize, frameRate: frameRate, colorSpace: colorSpace
                )
                plan.append(PlannedRange(
                    range: range, shown: shown,
                    segment: RenderSegment(range: range, key: key, needsRender: true, clipIDs: owners)
                ))
                start = range.end
            }
        }
        return plan
    }

    /// A hash of everything that decides a stretch's frames: each layer's
    /// file, its version on disk and the file time it starts at, and how it
    /// is drawn on every frame. Where the stretch sits in the timeline is
    /// left out, so moving it keeps its render.
    private static func renderKey(
        for range: CMTimeRange,
        shown: [(layer: VideoLayer, segment: VideoSegment)],
        frame: CMTime,
        frameSize: CGSize,
        frameRate: Double,
        colorSpace: ProjectColorSpace
    ) -> String {
        func number(_ value: Double) -> String { String(format: "%.5f", value) }
        let frames = Int((range.duration.seconds / frame.seconds).rounded(.up))
        var text = "v\(RenderSegment.formatVersion) \(number(frameSize.width))x\(number(frameSize.height)) \(number(frameRate)) \(colorSpace.rawValue) \(frames)\n"
        for (_, segment) in shown {
            let stamp = FileStamp(url: segment.sourceURL)
            let fileStart = CMTimeAdd(segment.sourceStart, CMTimeSubtract(range.start, segment.timeRange.start))
            text += "\(segment.sourceURL.path) \(stamp?.byteCount ?? -1) \(number(stamp?.modified ?? 0)) \(number(fileStart.seconds))\n"
            let animation = segment.animation
            for index in 0..<frames {
                let time = CMTimeAdd(range.start, CMTimeMultiply(frame, multiplier: Int32(index)))
                let t = animation.transform(at: time)
                text += [t.a, t.b, t.c, t.d, t.tx, t.ty, Double(animation.opacity(at: time))].map(number).joined(separator: " ")
                if let crop = animation.cropRectangle(at: time) {
                    text += " c" + [crop.minX, crop.minY, crop.width, crop.height].map(number).joined(separator: " ")
                }
                if let reveal = animation.lumaReveal(at: time) {
                    text += " r\(number(reveal.progress)) \(reveal.keysIncoming)"
                }
                text += "\n"
            }
        }
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Puts the cached render of each stretch that has one on a track of
    /// its own, and has the stretch show only that. Returns the keys used.
    private static func substituteCachedRanges(
        _ plan: inout [PlannedRange],
        from cache: RenderCache,
        into composition: AVMutableComposition
    ) async throws -> Set<String> {
        var used: Set<String> = []
        var track: AVMutableCompositionTrack?
        for index in plan.indices where plan[index].segment.needsRender {
            let segment = plan[index].segment
            guard let file = cache.file(for: segment.key),
                  let info = try? await MediaTrackCache.shared.info(for: file),
                  let video = info.video,
                  info.videoRange.duration >= segment.range.duration
            else {
                continue
            }
            if track == nil {
                track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let track else { break }
            let source = CMTimeRange(start: info.videoRange.start, duration: segment.range.duration)
            try track.insertTimeRange(source, of: video, at: segment.range.start)
            let rendered = VideoLayer(track: track, segments: [])
            let drawn = VideoSegment(
                timeRange: segment.range, animation: PlacementAnimation(base: .identity, stages: []),
                sourceURL: file, sourceStart: source.start, owner: UUID()
            )
            plan[index].shown = [(rendered, drawn)]
            cache.markUsed(segment.key)
            used.insert(segment.key)
        }
        return used
    }

    /// The per-stretch layer stacking instructions. Gaps produce empty
    /// instructions, which render black.
    private static func buildVideoComposition(
        plan: [PlannedRange],
        hasLayers: Bool,
        renderSize: CGSize,
        frameRate: Double,
        colorSpace: ProjectColorSpace,
        layered: Bool,
        meter: RenderMeter?
    ) -> AVMutableVideoComposition? {
        guard hasLayers else { return nil }

        let frame = frameDuration(for: frameRate)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frame

        // The built-in compositor draws everything else exactly; for export
        // only a film dissolve needs ours, so it is used just for timelines
        // with one.
        if layered || plan.contains(where: { $0.shown.contains { $0.segment.animation.hasLumaReveal } }) {
            // The viewer draws SDR timelines in 8 bits, which decodes cheaper.
            videoComposition.customVideoCompositorClass = layered && colorSpace == .rec709
                ? SDRLayeredCompositor.self : LayeredCompositor.self
            videoComposition.instructions = plan.map { planned in
                LayeredInstruction(
                    timeRange: planned.range,
                    layers: planned.shown.map { LayeredInstruction.Layer(trackID: $0.layer.track.trackID, animation: $0.segment.animation) },
                    renderSize: renderSize, colorSpace: colorSpace, meter: meter
                )
            }
            return videoComposition
        }

        videoComposition.instructions = plan.map { planned in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = planned.range
            instruction.layerInstructions = planned.shown.map { shown in
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: shown.layer.track)
                applyAnimation(shown.segment.animation, to: layerInstruction, in: planned.range, frame: frame)
                return layerInstruction
            }
            return instruction
        }
        return videoComposition
    }

    private static func frameDuration(for frameRate: Double) -> CMTime {
        Timeline.frameDuration(for: frameRate)
    }

    /// Sets the transform and opacity at the start of `range`, then again on
    /// every frame where a keyframed stage is changing. The built-in
    /// compositor holds each value until the next one, so the result is
    /// exact at every rendered frame. Matrix ramps aren't used because they
    /// blend matrix entries, which shrinks a layer midway through a turn.
    static func applyAnimation(
        _ animation: PlacementAnimation,
        to instruction: AVMutableVideoCompositionLayerInstruction,
        in range: CMTimeRange,
        frame: CMTime
    ) {
        var lastTransform = animation.transform(at: range.start)
        var lastOpacity = animation.opacity(at: range.start)
        let crops = animation.hasCrop
        var lastCrop = crops ? animation.cropRectangle(at: range.start) : nil
        instruction.setTransform(lastTransform, at: range.start)
        instruction.setOpacity(lastOpacity, at: range.start)
        if let lastCrop { instruction.setCropRectangle(lastCrop, at: range.start) }
        guard frame.seconds > 0 else { return }

        var lastSet = range.start
        for animated in animation.animatedRanges {
            // One frame past the last keyframe, so the final value lands.
            let span = CMTimeRange(start: animated.start, end: CMTimeAdd(animated.end, frame)).intersection(range)
            guard span.isValid, span.duration > .zero else { continue }
            var index = Int64((span.start.seconds / frame.seconds).rounded(.up))
            while true {
                let time = CMTime(value: index * frame.value, timescale: frame.timescale)
                guard time < span.end else { break }
                index += 1
                guard time > lastSet else { continue }
                lastSet = time
                let transform = animation.transform(at: time)
                let opacity = animation.opacity(at: time)
                if transform != lastTransform {
                    instruction.setTransform(transform, at: time)
                    lastTransform = transform
                }
                if opacity != lastOpacity {
                    instruction.setOpacity(opacity, at: time)
                    lastOpacity = opacity
                }
                if crops, let crop = animation.cropRectangle(at: time), crop != lastCrop {
                    instruction.setCropRectangle(crop, at: time)
                    lastCrop = crop
                }
            }
        }
    }

    /// Cancelling the calling task cancels the export, deletes the partial
    /// file, and throws `CancellationError`. A ProRes 422 export plays the
    /// stretches already rendered into `cache` from there instead of
    /// compositing them again; renders are ProRes 422 themselves, so a 4444
    /// export always composites from the sources to keep its extra detail.
    /// Returns how many rendered segments were reused.
    @discardableResult
    static func export(
        project: EditingProject,
        timelineID: UUID,
        preset: ProResPreset,
        to url: URL,
        cache: RenderCache? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Int {
        let composed = try await buildComposedTimeline(
            for: project, timelineID: timelineID, cache: preset.reusesRenders ? cache : nil
        )

        let isCompatible = await AVAssetExportSession.compatibility(
            ofExportPreset: preset.avPresetName,
            with: composed.composition,
            outputFileType: .mov
        )
        guard isCompatible else {
            throw CompositionError.incompatiblePreset
        }

        guard let exportSession = AVAssetExportSession(asset: composed.composition, presetName: preset.avPresetName) else {
            throw CompositionError.noExportSession
        }
        exportSession.videoComposition = composed.videoComposition
        exportSession.audioMix = composed.audioMix(curves: VolumeCurves(VolumeCurves.of(project)))

        // The save panel already confirmed replacing an existing file, but
        // AVAssetExportSession refuses to write over one.
        try? FileManager.default.removeItem(at: url)

        let states = exportSession.states(updateInterval: 0.2)
        let progressTask = Task {
            for await state in states {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        do {
            try await exportSession.export(to: url, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw CompositionError.exportFailed(error.localizedDescription)
        }
        return composed.cachedKeys.count
    }
}
