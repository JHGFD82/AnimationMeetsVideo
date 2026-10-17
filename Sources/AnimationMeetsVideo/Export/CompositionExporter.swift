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
    /// A clip's file isn't there; carries the asset's name.
    case missingMedia(String)
    case incompatiblePreset
    case noExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: "The timeline has no clips to export."
        case .cyclicTimeline: "This timeline embeds itself, directly or indirectly."
        case .missingMedia(let name): "\u{201C}\(name)\u{201D} is missing, so the timeline can't be exported. Put the file back, or replace it from the library."
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
    var audioTracks: [(track: AVAssetTrack, stages: [VolumeStage], pitch: AVAudioTimePitchAlgorithm?)] = []

    /// A mix that plays each audio track at its layers' volumes, read from
    /// `curves` as it plays, and measures the result into `meter`.
    func audioMix(curves: VolumeCurves, meter: MixLevelMeter? = nil) -> AVAudioMix? {
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

/// One piece of media placed at an absolute time in the root timeline.
private final class Placement {
    /// A stretch of the file played over a stretch of root time. They are
    /// the same length unless the clip is retimed, when the file is played
    /// faster or slower.
    struct Piece {
        var file: CMTimeRange
        var at: CMTime
        var duration: CMTime
    }

    let info: MediaTrackInfo
    /// In order, one after the other.
    let pieces: [Piece]
    /// Which of the file's streams to use; detached audio and its picture
    /// each play only one.
    var includesVideo: Bool
    var includesAudio: Bool

    /// Where the picture ended up in the composition, set when its track is
    /// built; nil if the file has none there.
    var trackID = kCMPersistentTrackID_Invalid
    var drawRange: CMTimeRange?
    /// The file time drawn at the start of `drawRange`.
    var drawSourceStart = CMTime.zero

    init(info: MediaTrackInfo, pieces: [Piece], includesVideo: Bool, includesAudio: Bool) {
        self.info = info
        self.pieces = pieces
        self.includesVideo = includesVideo
        self.includesAudio = includesAudio
    }

    /// Footage played unchanged: `file` starting at `at`.
    convenience init(info: MediaTrackInfo, file: CMTimeRange, at: CMTime, includesVideo: Bool, includesAudio: Bool) {
        self.init(info: info, pieces: [Piece(file: file, at: at, duration: file.duration)], includesVideo: includesVideo, includesAudio: includesAudio)
    }

    func copy() -> Placement {
        Placement(info: info, pieces: pieces, includesVideo: includesVideo, includesAudio: includesAudio)
    }

    /// The same footage later in root time by `delay`, and later in the file
    /// by `fileShift`.
    func shifted(by delay: CMTime = .zero, inFileBy fileShift: CMTime = .zero) -> Placement {
        Placement(
            info: info,
            pieces: pieces.map { Piece(file: CMTimeRange(start: CMTimeAdd($0.file.start, fileShift), duration: $0.file.duration), at: CMTimeAdd($0.at, delay), duration: $0.duration) },
            includesVideo: includesVideo, includesAudio: includesAudio
        )
    }

    /// The first moment of root time the placement plays from.
    var start: CMTime { pieces.first?.at ?? .zero }
}

/// What else is built from a clip's footage besides the clip itself: the
/// frame after, for Blend, and the footage earlier, for Echo and Trails.
private struct PlacementExtras {
    var next: Placement?
    var opticalFlow = false
    var echoes: [(placement: Placement, strength: Double)] = []
    var trails: [(placement: Placement, strength: Double)] = []
    var frameDuration = CMTime.zero
    var alignmentOffset = CMTime.zero
}

/// An ordered run of non-overlapping placements that share composition
/// tracks.
private final class TrackHost {
    var placements: [Placement] = []
    /// The volumes the track plays through: the clip's own if it has one,
    /// the layer's if it has one, then those of the clips and layers of the
    /// timelines it is nested in.
    var volume: [VolumeStage] = []
    /// How the sound is retimed, when it is; nil to leave it to AVFoundation.
    var pitch: AVAudioTimePitchAlgorithm?

    init(placements: [Placement] = [], volume: [VolumeStage] = [], pitch: AVAudioTimePitchAlgorithm? = nil) {
        self.placements = placements
        self.volume = volume
        self.pitch = pitch
    }
}

/// A picture an effect takes, on its way to being an `InputDraw`.
private enum BuildInput {
    case track(Placement, base: CGAffineTransform)
    case group(frameSize: CGSize, toOuter: CGAffineTransform, children: [BuildNode])
}

/// A clip on its way to being a `DrawClip`, once the composition's tracks
/// exist.
private final class BuildNode {
    enum Content {
        case media(Placement, base: CGAffineTransform, extras: PlacementExtras)
        case group(frameSize: CGSize, toOuter: CGAffineTransform, passThrough: Bool, children: [BuildNode])
        case adjustment(reachedLayerIDs: Set<UUID>, reachesAll: Bool)
    }

    let content: Content
    let stack: ClipStack
    /// Where the clip is drawn in root time, for a group or an adjustment.
    /// A picture's is where its track puts it.
    let range: CMTimeRange
    let owner: UUID
    /// The layer of its timeline the clip is on.
    let layerID: UUID
    /// The pictures its effects take, by the ID of the effect.
    let inputs: [UUID: BuildInput]

    init(content: Content, stack: ClipStack, range: CMTimeRange, owner: UUID, layerID: UUID, inputs: [UUID: BuildInput] = [:]) {
        self.content = content
        self.stack = stack
        self.range = range
        self.owner = owner
        self.layerID = layerID
        self.inputs = inputs
    }

    /// The inputs, drawn from tracks that now exist; one the file has no
    /// frames for is left out.
    func frozenInputs() -> [UUID: InputDraw] {
        inputs.compactMapValues { input -> InputDraw? in
            switch input {
            case .track(let placement, let base):
                guard let range = placement.drawRange else { return nil }
                return InputDraw.track(TrackCopy(trackID: placement.trackID, range: range, strength: 1), base: base)
            case .group(let frameSize, let toOuter, let children):
                let drawn = children.compactMap { $0.frozen() }
                guard !drawn.isEmpty else { return nil }
                return InputDraw.group(GroupDraw(frameSize: frameSize, toOuter: toOuter, passThrough: false, children: drawn))
            }
        }
    }

    /// Nil for a picture the file has no frames for.
    func frozen() -> DrawClip? {
        switch content {
        case .media(let placement, let base, let extras):
            guard let range = placement.drawRange else { return nil }
            let url = placement.info.asset.url
            func copy(_ extra: Placement, _ strength: Double) -> TrackCopy? {
                extra.drawRange.map {
                    TrackCopy(trackID: extra.trackID, range: $0, strength: strength, delay: CMTimeSubtract($0.start, range.start))
                }
            }
            return DrawClip(
                content: .media(MediaDraw(
                    trackID: placement.trackID, base: base, url: url,
                    sourceStart: placement.drawSourceStart, segmentStart: range.start,
                    frameDuration: extras.frameDuration, alignmentOffset: extras.alignmentOffset,
                    nextFrame: extras.next.flatMap { copy($0, 1) },
                    opticalFlow: extras.opticalFlow,
                    echoes: extras.echoes.compactMap { copy($0.placement, $0.strength) },
                    trails: extras.trails.compactMap { copy($0.placement, $0.strength) }
                )),
                stack: stack, range: range, owner: owner, layerID: layerID, inputs: frozenInputs()
            )
        case .adjustment(let reachedLayerIDs, let reachesAll):
            return DrawClip(
                content: .adjustment(AdjustmentDraw(reachedLayerIDs: reachedLayerIDs, reachesAll: reachesAll)),
                stack: stack, range: range, owner: owner, layerID: layerID, inputs: frozenInputs()
            )
        case .group(let frameSize, let toOuter, let passThrough, let children):
            let drawn = children.compactMap { $0.frozen() }
            guard !drawn.isEmpty else { return nil }
            return DrawClip(
                content: .group(GroupDraw(
                    frameSize: frameSize, toOuter: toOuter, passThrough: passThrough, children: drawn,
                    pushesTransforms: !drawn.contains { $0.everyClip.contains { $0.stack.dependsOnPixelSize } }
                )),
                stack: stack, range: range, owner: owner, layerID: layerID, inputs: frozenInputs()
            )
        }
    }
}

/// A stretch of the timeline with the clips drawn in it, top first.
private struct PlannedRange {
    var range: CMTimeRange
    var clips: [DrawClip]
    var segment: RenderSegment
    /// The track whose frames are the stretch's as they are, when that is
    /// all it is.
    var passthrough: CMPersistentTrackID?
}

enum CompositionExporter {
    /// Set while building for the viewer: a clip whose file is missing is
    /// left out, as a gap, so the rest of the timeline can still be
    /// watched. Export and background renders stop on it instead
    /// (`CompositionError.missingMedia`), so a gap is never written out.
    @TaskLocal private static var skipsMissingMedia = false

    /// Drops what was read from the file at `url`, for when it was replaced
    /// or changed on disk.
    static func forgetCachedMedia(at url: URL) async {
        await MediaTrackCache.shared.forget(url)
    }

    /// With `forPreview` the viewer may draw at a reduced size, so every
    /// stretch is drawn by the compositor, which has `meter` hear how long
    /// each frame took. Segments already rendered into `cache` play from
    /// there.
    static func buildComposedTimeline(
        for project: EditingProject,
        timelineID: UUID,
        forPreview: Bool = false,
        meter: RenderMeter? = nil,
        options: DrawingOptions? = nil,
        cache: RenderCache? = nil
    ) async throws -> ComposedTimeline {
        // Slivers of gap between clips (a retimed clip's end can't be found
        // closer than a few microseconds) would draw black frames.
        var project = project
        for index in project.timelines.indices { project.timelines[index] = project.timelines[index].closingSlivers() }
        guard let timeline = project.timeline(id: timelineID), !timeline.layers.isEmpty else {
            throw CompositionError.emptyTimeline
        }

        // Matte wipes' maps are read before drawing starts.
        await MatteMaps.shared.load(for: project)
        let window = CMTimeRange(start: .zero, duration: timeline.duration)
        var hosts: [TrackHost] = []
        let nodes = try await $skipsMissingMedia.withValue(forPreview) {
            try await flatten(
                project: project,
                timelineID: timelineID,
                visiting: [],
                window: window,
                offset: .zero,
                outerVolume: [],
                rootClipID: nil,
                hosts: &hosts
            )
        }

        let composition = AVMutableComposition()
        var audioTracks: [(track: AVAssetTrack, stages: [VolumeStage], pitch: AVAudioTimePitchAlgorithm?)] = []
        /// A stretch of some source's picture, to fill time after the last clip.
        var filler: (track: AVAssetTrack, range: CMTimeRange)?

        for host in hosts {
            var videoTrack: AVMutableCompositionTrack?
            var audioTrack: AVMutableCompositionTrack?

            for placement in host.placements {
                let info = placement.info
                if let sourceVideo = info.video, placement.includesVideo {
                    var playing: CMTimeRange?
                    for piece in placement.pieces {
                        guard let (file, at, length) = piece.within(info.videoRange) else { continue }
                        if videoTrack == nil {
                            videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        try videoTrack?.insertTimeRange(file, of: sourceVideo, at: at)
                        // Retimed footage plays faster or slower than it was
                        // shot.
                        if length != file.duration {
                            videoTrack?.scaleTimeRange(CMTimeRange(start: at, duration: file.duration), toDuration: length)
                        }
                        if filler == nil { filler = (sourceVideo, file) }
                        if playing == nil { placement.drawSourceStart = file.start }
                        let played = CMTimeRange(start: at, duration: length)
                        playing = playing.map { $0.union(played) } ?? played
                    }
                    if let playing {
                        placement.trackID = videoTrack?.trackID ?? kCMPersistentTrackID_Invalid
                        placement.drawRange = playing
                    }
                }
                if let sourceAudio = info.audio, placement.includesAudio {
                    for piece in placement.pieces {
                        guard let (file, at, length) = piece.within(info.audioRange) else { continue }
                        if audioTrack == nil {
                            audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        }
                        try audioTrack?.insertTimeRange(file, of: sourceAudio, at: at)
                        if length != file.duration {
                            audioTrack?.scaleTimeRange(CMTimeRange(start: at, duration: file.duration), toDuration: length)
                        }
                    }
                }
            }

            if let audioTrack {
                audioTracks.append((audioTrack, host.volume, host.pitch))
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

        let tree = nodes.compactMap { $0.frozen() }
        var plan = planRanges(
            tree: tree, overallDuration: composition.duration, allowsPassthrough: !forPreview,
            frameSize: timeline.frameSize, frameRate: timeline.frameRate, colorSpace: timeline.colorSpace,
            canvasMargin: project.canvasMargin
        )
        let canvasMargin = project.canvasMargin
        var cachedKeys: Set<String> = []
        if let cache {
            cachedKeys = try await substituteCachedRanges(
                &plan, from: cache, into: composition, frame: frameDuration(for: timeline.frameRate)
            )
        }

        let videoComposition = Self.buildVideoComposition(
            plan: plan,
            hasPictures: !tree.isEmpty,
            renderSize: timeline.frameSize,
            frameRate: timeline.frameRate,
            colorSpace: timeline.colorSpace,
            forPreview: forPreview,
            canvasMargin: canvasMargin,
            meter: meter,
            options: options
        )
        return ComposedTimeline(
            composition: composition, videoComposition: videoComposition,
            segments: plan.map(\.segment), cachedKeys: cachedKeys, audioTracks: audioTracks
        )
    }

    /// Resolves a timeline into the clips drawn in it, top layer first,
    /// with a nested timeline's clips inside its own, and collects the
    /// media that makes up the composition's tracks in `hosts`. `window` is
    /// the visible range in this timeline's own time, `offset` maps this
    /// timeline's time to root time, and `outerVolume` holds the volumes of
    /// the clips and layers this timeline is nested in (innermost first).
    private static func flatten(
        project: EditingProject,
        timelineID: UUID,
        visiting: Set<UUID>,
        window: CMTimeRange,
        offset: CMTime,
        outerVolume: [VolumeStage],
        rootClipID: UUID?,
        silent: Bool = false,
        hosts: inout [TrackHost]
    ) async throws -> [BuildNode] {
        guard !visiting.contains(timelineID) else {
            throw CompositionError.cyclicTimeline
        }
        guard let timeline = project.timeline(id: timelineID) else { return [] }
        var visiting = visiting
        visiting.insert(timelineID)

        let center = CGPoint(x: timeline.frameSize.width / 2, y: timeline.frameSize.height / 2)
        var result: [BuildNode] = []
        /// The layers below an adjustment layer that its effect reaches.
        func reach(of layer: TimelineLayer) -> (layers: Set<UUID>, all: Bool) {
            guard let index = timeline.layers.firstIndex(where: { $0.id == layer.id }) else { return ([], false) }
            let below = timeline.layers[(index + 1)...]
            guard let bottom = layer.reach, let bottomIndex = timeline.layers.firstIndex(where: { $0.id == bottom }) else {
                return (Set(below.map(\.id)), true)
            }
            // Reaching down to a layer that is above it reaches nothing.
            guard bottomIndex > index else { return ([], false) }
            return (Set(timeline.layers[(index + 1)...bottomIndex].map(\.id)), false)
        }
        for layer in timeline.layers {
            // Sound and Music layers act as a fader over their clips' own
            // volumes; video layers have no volume of their own.
            let layerVolume = layer.kind.isAudio ? [VolumeStage(id: layer.id, shift: offset)] : []
            let volume = layerVolume + outerVolume
            let clips = layer.clips.sorted(by: { $0.startOffset < $1.startOffset })
            let own = TrackHost(volume: volume)
            // The incoming clip's frames before a joined cut, on a track of
            // their own above the layer's, so they can overlap the outgoing
            // clip that is still playing there.
            let overlay = TrackHost()
            // Frames shown under a transition at a cut, on a track of their
            // own below the layer's so the two can overlap.
            let underlay = TrackHost()
            // The sound of clips with a volume of their own, each on a track
            // of its own to be played through that volume.
            var clipSound: [TrackHost] = []
            // The footage again, for frame blending, echo and trails.
            var copyHosts: [TrackHost] = []
            var nestedHosts: [TrackHost] = []
            var overlayNodes: [BuildNode] = [], ownNodes: [BuildNode] = [], underlayNodes: [BuildNode] = []

            for clip in clips {
                func stack(of clip: TimelineClip, edges: EdgeTransitions? = nil) -> ClipStack {
                    ClipStack(clip: clip, center: center, shift: offset, edges: edges, colorSpace: timeline.colorSpace, frameDuration: timeline.frameDuration)
                }
                // The clip's volume counts in its source time, which a
                // retimed clip plays through at its speed (at the speed it
                // starts at, when that is changing).
                let rate = abs(clip.speed(atSource: clip.trimStart)) / 100
                let clipVolume = VolumeStage(
                    id: clip.id,
                    shift: CMTimeAdd(offset, CMTimeSubtract(clip.startOffset, CMTimeMultiplyByFloat64(clip.trimStart, multiplier: 1 / rate))),
                    rate: rate
                )
                let hasOwnVolume = clip.volume != AnimatedValue(0.0)
                let lead = project.joinedLead(of: clip, among: clips) ?? .zero
                var clipStack = stack(of: clip)
                if project.playsVideo(clip) {
                    clipStack.edges = EdgeTransitions(clip: clip, frameSize: timeline.frameSize, lead: lead)
                }
                let placed = CMTimeRange(start: CMTimeSubtract(clip.startOffset, lead), end: clip.endOffset)
                let visible = placed.intersection(window)
                guard visible.isValid, visible.duration > .zero else { continue }
                let owner = rootClipID ?? clip.id

                // The pictures its effects take come from the browser, not
                // the timeline: footage on tracks of its own, or a nested
                // timeline drawn as one picture.
                var inputs: [UUID: BuildInput] = [:]
                for effect in clip.effects where effect.enabled && effect.kind.takesInput {
                    guard let input = effect.input else { continue }
                    switch input.source {
                    case .asset(let assetID):
                        if let (placement, base) = try await inputPlacement(
                            assetID, input: input, clip: clip, visible: visible,
                            project: project, frameSize: timeline.frameSize, offset: offset
                        ) {
                            copyHosts.append(TrackHost(placements: [placement]))
                            inputs[effect.id] = .track(placement, base: base)
                        }
                    case .timeline(let nestedID):
                        guard let nested = project.timeline(id: nestedID) else { continue }
                        guard !visiting.contains(nestedID) else { throw CompositionError.cyclicTimeline }
                        var inner: [TrackHost] = []
                        let children = try await flatten(
                            project: project, timelineID: nestedID, visiting: visiting,
                            window: CMTimeRange(
                                start: CMTimeAdd(input.offset, CMTimeSubtract(visible.start, clip.startOffset)), duration: visible.duration
                            ),
                            offset: CMTimeAdd(offset, CMTimeSubtract(clip.startOffset, input.offset)),
                            outerVolume: [], rootClipID: owner, silent: true, hosts: &inner
                        )
                        nestedHosts += inner
                        if !children.isEmpty {
                            inputs[effect.id] = .group(
                                frameSize: nested.frameSize, toOuter: fitTransform(from: nested.frameSize, to: timeline.frameSize), children: children
                            )
                        }
                    }
                }

                switch clip.source {
                case .media(let mediaID):
                    let main: (Placement, CGAffineTransform)?
                    if clip.isRetimed {
                        main = try await retimedPlacement(
                            of: clip, project: project, frameSize: timeline.frameSize, frameDuration: timeline.frameDuration,
                            window: window, offset: offset,
                            includesVideo: clip.streams != .audio, includesAudio: clip.streams != .video
                        )
                    } else {
                        main = try await mediaPlacement(
                            of: clip, from: clip.trimStart, at: clip.startOffset, for: clip.trimmedDuration,
                            project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                            includesVideo: clip.streams != .audio, includesAudio: clip.streams != .video
                        )
                    }
                    if let (placement, base) = main {
                        if silent { placement.includesAudio = false }
                        // A retimed clip's sound is silent, or played at its
                        // new speed with or without its pitch changing.
                        if clip.isRetimed, clip.time.sound == .mute || clip.isReversed { placement.includesAudio = false }
                        if placement.includesAudio, hasOwnVolume || clip.isRetimed {
                            let sound = placement.copy()
                            sound.includesVideo = false
                            let pitch: AVAudioTimePitchAlgorithm? = clip.isRetimed ? (clip.time.sound == .changePitch ? .varispeed : .spectral) : nil
                            clipSound.append(TrackHost(placements: [sound], volume: [clipVolume] + volume, pitch: pitch))
                            placement.includesAudio = false
                        }
                        own.placements.append(placement)
                        if placement.includesVideo {
                            let media = project.mediaClip(id: mediaID)
                            var extras = PlacementExtras(
                                frameDuration: Timeline.frameDuration(for: media.map { $0.frameRate > 0 ? $0.frameRate : timeline.frameRate } ?? timeline.frameRate),
                                alignmentOffset: media?.alignmentOffset ?? .zero
                            )
                            func copy(_ delay: CMTime, inFileBy fileShift: CMTime = .zero) -> Placement {
                                let copy = placement.shifted(by: delay, inFileBy: fileShift)
                                copy.includesAudio = false
                                copyHosts.append(TrackHost(placements: [copy]))
                                return copy
                            }
                            // Blend mixes the frame the footage is at with the
                            // one after it.
                            if clip.time.frameBlending != .off {
                                extras.next = copy(.zero, inFileBy: extras.frameDuration)
                                extras.opticalFlow = clip.time.frameBlending == .opticalFlow
                            }
                            // Echo and trails are the footage again, later in
                            // time, so each moment has an earlier one to show.
                            if let echo = clip.time.echo?.clamped {
                                extras.echoes = (1...echo.count).map { k in
                                    (copy(CMTimeMultiply(echo.delay, multiplier: Int32(k))), pow(echo.decay, Double(k)))
                                }
                            }
                            if let trails = clip.shutter.trails?.clamped {
                                extras.trails = (1...trails.count).map { k in
                                    (copy(CMTimeMultiply(trails.delay, multiplier: Int32(k))), pow(trails.decay, Double(k)))
                                }
                            }
                            ownNodes.append(BuildNode(
                                content: .media(placement, base: base, extras: extras), stack: clipStack, range: .invalid,
                                owner: owner, layerID: layer.id, inputs: inputs
                            ))
                        }
                    }
                    // Where this clip meets its neighbor at a cut, the
                    // neighbor's frames beyond its trim play underneath the
                    // transition, so a dissolve blends the two clips rather
                    // than passing through what is below the layer. A way in
                    // that joins the clip before may also start before the
                    // cut, playing this clip's frames before its in point.
                    // Without spare frames there is nothing to show, and the
                    // transition plays over the layers below.
                    let durations = clipStack.edges == nil ? (leading: CMTime.zero, trailing: CMTime.zero) : clip.effectiveTransitionDurations(lead: lead)
                    if lead > .zero, let (placement, base) = try await mediaPlacement(
                        of: clip, from: CMTimeSubtract(clip.trimStart, lead), at: CMTimeSubtract(clip.startOffset, lead), for: lead,
                        project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                        includesVideo: true, includesAudio: false
                    ) {
                        overlay.placements.append(placement)
                        overlayNodes.append(BuildNode(content: .media(placement, base: base, extras: PlacementExtras()), stack: clipStack, range: .invalid, owner: owner, layerID: layer.id))
                    }
                    if durations.leading > .zero, let previous = project.predecessor(joining: clip, among: clips),
                       let (placement, base) = try await mediaPlacement(
                           of: previous, from: previous.trimEnd, at: clip.startOffset, for: durations.leading,
                           project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                           includesVideo: true, includesAudio: false
                       ) {
                        underlay.placements.append(placement)
                        underlayNodes.append(BuildNode(content: .media(placement, base: base, extras: PlacementExtras()), stack: stack(of: previous), range: .invalid, owner: owner, layerID: layer.id))
                    }
                    if durations.trailing > .zero, let next = project.successor(joining: clip, among: clips),
                       let (placement, base) = try await mediaPlacement(
                           of: next, from: CMTimeSubtract(next.trimStart, durations.trailing),
                           at: CMTimeSubtract(clip.endOffset, durations.trailing), for: durations.trailing,
                           project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                           includesVideo: true, includesAudio: false
                       ) {
                        underlay.placements.append(placement)
                        underlayNodes.append(BuildNode(content: .media(placement, base: base, extras: PlacementExtras()), stack: stack(of: next), range: .invalid, owner: owner, layerID: layer.id))
                    }
                case .timeline(let nestedID):
                    guard let nested = project.timeline(id: nestedID) else { continue }
                    // Nested time = this timeline's time - clip.startOffset + clip.trimStart.
                    let shift = CMTimeSubtract(clip.startOffset, clip.trimStart)
                    let nestedWindow = CMTimeRange(start: CMTimeSubtract(visible.start, shift), duration: visible.duration)
                    var inner: [TrackHost] = []
                    let children = try await flatten(
                        project: project,
                        timelineID: nestedID,
                        visiting: visiting,
                        window: nestedWindow,
                        offset: CMTimeAdd(offset, shift),
                        outerVolume: [clipVolume] + volume,
                        rootClipID: owner,
                        silent: silent,
                        hosts: &inner
                    )
                    nestedHosts += inner
                    guard !children.isEmpty else { continue }
                    ownNodes.append(BuildNode(
                        content: .group(
                            frameSize: nested.frameSize, toOuter: fitTransform(from: nested.frameSize, to: timeline.frameSize),
                            passThrough: clip.passThrough, children: children
                        ),
                        stack: clipStack,
                        range: CMTimeRange(start: CMTimeAdd(visible.start, offset), duration: visible.duration),
                        owner: owner,
                        layerID: layer.id,
                        inputs: inputs
                    ))
                case .adjustment:
                    // No picture: its stack is applied to the layers it
                    // reaches while it plays.
                    let reached = reach(of: layer)
                    ownNodes.append(BuildNode(
                        content: .adjustment(reachedLayerIDs: reached.layers, reachesAll: reached.all),
                        stack: clipStack,
                        range: CMTimeRange(start: CMTimeAdd(visible.start, offset), duration: visible.duration),
                        owner: owner,
                        layerID: layer.id,
                        inputs: inputs
                    ))
                }
            }

            result += overlayNodes + ownNodes + underlayNodes
            hosts += [overlay, own, underlay].filter { !$0.placements.isEmpty }
            hosts += clipSound
            hosts += copyHosts
            hosts += nestedHosts
        }
        return result
    }

    /// A media clip's frames from `sourceStart` (in its asset's original
    /// time) placed at `placedStart` in the timeline for `duration`, cut to
    /// the window, with the transform that orients and fits them into the
    /// timeline's frame. Nil when it falls outside the window, the clip
    /// isn't media, or its file is missing. Frames past either end of the
    /// file are dropped when the tracks are built.
    private static func mediaPlacement(
        of clip: TimelineClip,
        from sourceStart: CMTime,
        at placedStart: CMTime,
        for duration: CMTime,
        project: EditingProject,
        frameSize: CGSize,
        window: CMTimeRange,
        offset: CMTime,
        includesVideo: Bool,
        includesAudio: Bool
    ) async throws -> (Placement, CGAffineTransform)? {
        guard case .media(let mediaID) = clip.source,
              let media = project.mediaClip(id: mediaID), let url = media.url
        else {
            return nil
        }
        let visible = CMTimeRange(start: placedStart, duration: duration).intersection(window)
        guard visible.isValid, visible.duration > .zero else { return nil }
        let intoClip = CMTimeSubtract(visible.start, placedStart)
        let info: MediaTrackInfo
        do {
            info = try await MediaTrackCache.shared.info(for: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A file that is there but unreadable is a real failure; one
            // that is gone is offline media (see `skipsMissingMedia`).
            guard !FileManager.default.fileExists(atPath: url.path) else { throw error }
            if skipsMissingMedia { return nil }
            throw CompositionError.missingMedia(media.name)
        }
        let wanted = CMTimeRange(start: media.fileTime(forSourceTime: CMTimeAdd(sourceStart, intoClip)), duration: visible.duration)
        let base = info.orientedTransform
            .concatenating(fitTransform(from: info.orientedSize, to: frameSize))
        let placement = Placement(
            info: info,
            file: wanted,
            at: CMTimeAdd(visible.start, offset),
            includesVideo: includesVideo,
            includesAudio: includesAudio
        )
        return (placement, base)
    }

    /// A retimed media clip's footage, cut to the window: one piece playing
    /// the file at the clip's speed, or for a speed that changes, a piece
    /// for every few frames each at the speed it has there.
    private static func retimedPlacement(
        of clip: TimelineClip,
        project: EditingProject,
        frameSize: CGSize,
        frameDuration: CMTime,
        window: CMTimeRange,
        offset: CMTime,
        includesVideo: Bool,
        includesAudio: Bool
    ) async throws -> (Placement, CGAffineTransform)? {
        guard case .media(let mediaID) = clip.source,
              let media = project.mediaClip(id: mediaID), let url = media.url
        else {
            return nil
        }
        let visible = CMTimeRange(start: clip.startOffset, end: clip.endOffset).intersection(window)
        guard visible.isValid, visible.duration > .zero else { return nil }
        let info = try await MediaTrackCache.shared.info(for: url)

        func piece(from a: CMTime, to b: CMTime) -> Placement.Piece {
            let first = clip.sourceTime(atTimelineTime: a), last = clip.sourceTime(atTimelineTime: b)
            // Backwards, a piece is a frame's worth of footage starting at
            // where the piece starts, so it shows that moment.
            return Placement.Piece(
                file: CMTimeRange(start: media.fileTime(forSourceTime: first), duration: CMTimeSubtract(max(first, last), min(first, last))),
                at: CMTimeAdd(a, offset), duration: CMTimeSubtract(b, a)
            )
        }
        var pieces: [Placement.Piece] = []
        if clip.isReversed || clip.time.speed.isAnimated {
            // A composition can't play footage backwards, so backwards
            // footage is a piece for every frame, each placed after the
            // one that follows it in the file.
            let step = clip.isReversed ? frameDuration : CMTimeMultiply(frameDuration, multiplier: 4)
            var cursor = visible.start
            while cursor < visible.end {
                let end = CMTimeMinimum(CMTimeAdd(cursor, step), visible.end)
                pieces.append(piece(from: cursor, to: end))
                cursor = end
            }
        } else {
            pieces = [piece(from: visible.start, to: visible.end)]
        }
        let base = info.orientedTransform.concatenating(fitTransform(from: info.orientedSize, to: frameSize))
        return (Placement(info: info, pieces: pieces, includesVideo: includesVideo, includesAudio: includesAudio), base)
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

    /// Splits the timeline where any picture starts or ends, and each
    /// stretch draws the clips whose pictures cover all of it (top first).
    /// Stretches that need rendering are cut into pieces of at most
    /// `RenderSegment.maxFrames` frames.
    private static func planRanges(
        tree: [DrawClip],
        overallDuration: CMTime,
        allowsPassthrough: Bool,
        frameSize: CGSize,
        frameRate: Double,
        colorSpace: ProjectColorSpace,
        canvasMargin: Double
    ) -> [PlannedRange] {
        var breakpoints: [CMTime] = [.zero]
        // Wherever a picture, a nested timeline or an adjustment starts or
        // ends, something about the drawing changes.
        func collect(_ clips: [DrawClip]) {
            for clip in clips {
                breakpoints.append(clip.range.start)
                breakpoints.append(clip.range.end)
                switch clip.content {
                case .group(let group):
                    collect(group.children)
                case .media(let media):
                    // Where its other tracks start and end, so each stretch
                    // has them throughout or not at all.
                    for copy in [media.nextFrame].compactMap({ $0 }) + media.echoes + media.trails {
                        breakpoints.append(copy.range.start)
                        breakpoints.append(copy.range.end)
                    }
                case .adjustment:
                    break
                }
                for input in clip.inputs.values {
                    switch input {
                    case .track(let copy, _):
                        breakpoints.append(copy.range.start)
                        breakpoints.append(copy.range.end)
                    case .group(let group):
                        collect(group.children)
                    }
                }
            }
        }
        collect(tree)
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
            let clips = DrawClip.assembled(tree.compactMap { $0.pruned(to: whole) })
            let leaves = clips.flatMap(\.leaves)
            let owners = Set(clips.map(\.owner))

            // One picture drawn the same way throughout plays from its file;
            // stacking it with others, or anything changing over time, is
            // rendered.
            let animated = clips.contains { clip in
                clip.animatedRanges.contains { range in
                    let overlap = range.intersection(whole)
                    return overlap.isValid && overlap.duration > .zero
                }
            }
            let changesPixels = clips.contains { clip in clip.everyClip.contains { $0.stack.resolve(atRoot: whole.start).changesPixels } }
            // Frames mixed from several, earlier copies, and motion blur
            // draw a clip more than once.
            let drawsTwice = clips.contains { clip in
                clip.everyClip.contains { clip in
                    if case .media(let media) = clip.content, media.nextFrame != nil || !media.echoes.isEmpty || !media.trails.isEmpty { return true }
                    return clip.stack.shutter.motionBlur != nil
                }
            }
            let needsRender = whole.duration >= frame && (leaves.count > 1 || animated || changesPixels || drawsTwice)

            // A single picture with nothing done to it and no fitting is the
            // stretch's frames as they are.
            var straight: CMPersistentTrackID?
            if allowsPassthrough, !needsRender, clips.count == 1, case .media(let media) = clips[0].content,
               media.base == .identity, clips[0].stack.isNoOp(over: whole, frame: frame) {
                straight = media.trackID
            }
            guard needsRender else {
                plan.append(PlannedRange(
                    range: whole, clips: clips,
                    segment: RenderSegment(range: whole, key: "", needsRender: false, clipIDs: owners),
                    passthrough: straight
                ))
                continue
            }
            var start = whole.start
            while start < whole.end {
                let range = CMTimeRange(start: start, end: CMTimeMinimum(CMTimeAdd(start, piece), whole.end))
                let key = renderKey(
                    for: range, clips: clips, frame: frame,
                    frameSize: frameSize, frameRate: frameRate, colorSpace: colorSpace, canvasMargin: canvasMargin
                )
                plan.append(PlannedRange(
                    range: range, clips: clips,
                    segment: RenderSegment(range: range, key: key, needsRender: true, clipIDs: owners),
                    passthrough: nil
                ))
                start = range.end
            }
        }
        return plan
    }

    /// A hash of everything that decides a stretch's frames: each picture's
    /// file, its version on disk and the file time it starts at, and what
    /// is done to it on every frame, in the structure the clips are nested
    /// in. Where the stretch sits in the timeline is left out, so moving it
    /// keeps its render.
    private static func renderKey(
        for range: CMTimeRange,
        clips: [DrawClip],
        frame: CMTime,
        frameSize: CGSize,
        frameRate: Double,
        colorSpace: ProjectColorSpace,
        canvasMargin: Double
    ) -> String {
        func number(_ value: Double) -> String { String(format: "%.5f", value) }
        func matrix(_ t: CGAffineTransform) -> String { [t.a, t.b, t.c, t.d, t.tx, t.ty].map(number).joined(separator: " ") }
        let frames = Int((range.duration.seconds / frame.seconds).rounded(.up))
        var text = "v\(RenderSegment.formatVersion) \(number(frameSize.width))x\(number(frameSize.height)) \(number(frameRate)) \(colorSpace.rawValue) \(number(canvasMargin)) \(frames)\n"

        func describe(_ clip: DrawClip) {
            switch clip.content {
            case .media(let media):
                let stamp = FileStamp(url: media.url)
                let fileStart = CMTimeAdd(media.sourceStart, CMTimeSubtract(range.start, media.segmentStart))
                text += "L \(media.url.path) \(stamp?.byteCount ?? -1) \(number(stamp?.modified ?? 0)) \(number(fileStart.seconds)) \(matrix(media.base))\n"
                // What is done to the footage's time, which the picture
                // depends on beyond the file time it starts at.
                text += "T \(number(media.frameDuration.seconds)) \(number(media.alignmentOffset.seconds)) next:\(media.nextFrame != nil) flow:\(media.opticalFlow)"
                text += " echo:" + media.echoes.map { "\(number($0.strength))@\(number($0.delay.seconds))" }.joined(separator: ",")
                text += " trails:" + media.trails.map { "\(number($0.strength))@\(number($0.delay.seconds))" }.joined(separator: ",") + "\n"
            case .group(let group):
                text += "G \(number(group.frameSize.width))x\(number(group.frameSize.height)) \(matrix(group.toOuter)) \(group.passThrough ? "pass" : "closed")\n"
            case .adjustment(let adjustment):
                text += "A \(adjustment.reachesAll ? "all" : "some")\n"
            }
            if let blur = clip.stack.shutter.motionBlur {
                text += "B \(number(blur.angle)) \(blur.samples) \(number(clip.stack.frameDuration.seconds))\n"
            }
            for index in 0..<frames {
                let time = CMTimeAdd(range.start, CMTimeMultiply(frame, multiplier: Int32(index)))
                let resolved = clip.stack.resolve(atRoot: time)
                // Retimed, the file time each frame comes from isn't a
                // straight line from where the stretch starts.
                if clip.stack.retimed != nil {
                    text += "s \(number(clip.stack.sourceTime(atLocal: clip.stack.localTime(atRoot: time)).seconds)) "
                }
                for step in resolved.steps {
                    switch step {
                    case .place(let m, let opacity): text += "p \(matrix(m)) \(number(opacity))"
                    case .mark(let id): text += "m \(id.uuidString)"
                    case .matte(let effect, let mode, let amount): text += "k \(effect.uuidString) \(mode.rawValue) \(number(amount))"
                    case .blend(let mode, let amount, let against): text += "b \(mode.rawValue) \(number(amount)) \(against?.uuidString ?? "-")"
                    case .color(let ops):
                        text += "g \(clip.stack.colorSpace.rawValue) " + ops.map { op in
                            "\(op.kind.rawValue):" + (0..<4).map { number(Double(op.value[$0])) }.joined(separator: ",")
                        }.joined(separator: " ")
                    }
                    text += " "
                }
                if let transition = resolved.transition {
                    text += "t \(number(transition.opacity)) \(matrix(transition.transform))"
                    if let visible = transition.visibleRect {
                        text += " c" + [visible.minX, visible.minY, visible.width, visible.height].map(number).joined(separator: " ")
                    }
                    if let reveal = transition.lumaReveal {
                        text += " r\(number(reveal.progress)) \(reveal.keysIncoming)"
                    }
                }
                if let drawn = clip.stack.transitionFrame(atRoot: time) {
                    text += " x \(drawn.key)"
                    if drawn.kind == .matteWipe, case .clip(let id) = drawn.options.matte {
                        text += " \(MatteMaps.shared.stamp(for: id) ?? "noise")"
                    }
                }
                text += "\n"
            }
            switch clip.content {
            case .group(let group):
                text += "(\n"
                group.children.forEach(describe)
                text += ")\n"
            case .adjustment(let adjustment):
                text += "(\n"
                adjustment.reached.forEach(describe)
                text += ")\n"
            case .media:
                break
            }
        }
        clips.forEach(describe)
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Puts the cached render of each stretch that has one on a track of
    /// its own, and has the stretch show only that. Returns the keys used.
    ///
    /// A render can come out a little shorter than its stretch: the
    /// stretch's ends are clip edges, which at rates such as 29.97 fall
    /// between the exact frame times, and the render holds whole frames.
    /// One short by less than a frame is stretched to fit, rather than let
    /// go, which left the stretch compositing live although the timeline
    /// showed it rendered.
    private static func substituteCachedRanges(
        _ plan: inout [PlannedRange],
        from cache: RenderCache,
        into composition: AVMutableComposition,
        frame: CMTime
    ) async throws -> Set<String> {
        var used: Set<String> = []
        var track: AVMutableCompositionTrack?
        for index in plan.indices where plan[index].segment.needsRender {
            let segment = plan[index].segment
            guard let file = cache.file(for: segment.key),
                  let info = try? await MediaTrackCache.shared.info(for: file),
                  let video = info.video,
                  info.videoRange.duration > .zero,
                  CMTimeAdd(info.videoRange.duration, frame) > segment.range.duration
            else {
                continue
            }
            if track == nil {
                track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let track else { break }
            let source = CMTimeRange(start: info.videoRange.start, duration: CMTimeMinimum(info.videoRange.duration, segment.range.duration))
            try track.insertTimeRange(source, of: video, at: segment.range.start)
            if source.duration < segment.range.duration {
                track.scaleTimeRange(CMTimeRange(start: segment.range.start, duration: source.duration), toDuration: segment.range.duration)
            }
            plan[index].clips = [DrawClip(
                content: .media(MediaDraw(
                    trackID: track.trackID, base: .identity, url: file,
                    sourceStart: source.start, segmentStart: segment.range.start
                )),
                stack: .none, range: segment.range, owner: UUID()
            )]
            cache.markUsed(segment.key)
            used.insert(segment.key)
        }
        return used
    }

    /// The per-stretch drawing instructions. Gaps are stretches with
    /// nothing to draw, which render black.
    private static func buildVideoComposition(
        plan: [PlannedRange],
        hasPictures: Bool,
        renderSize: CGSize,
        frameRate: Double,
        colorSpace: ProjectColorSpace,
        forPreview: Bool,
        canvasMargin: Double,
        meter: RenderMeter?,
        options: DrawingOptions?
    ) -> AVMutableVideoComposition? {
        guard hasPictures else { return nil }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration(for: frameRate)
        // The viewer draws SDR timelines in 8 bits, which decodes cheaper.
        videoComposition.customVideoCompositorClass = forPreview && colorSpace == .rec709
            ? SDRLayeredCompositor.self : LayeredCompositor.self
        videoComposition.instructions = plan.map { planned in
            LayeredInstruction(
                timeRange: planned.range, clips: planned.clips, passthrough: planned.passthrough ?? kCMPersistentTrackID_Invalid,
                renderSize: renderSize, colorSpace: colorSpace, canvasMargin: canvasMargin, meter: meter, options: options
            )
        }
        return videoComposition
    }

    private static func frameDuration(for frameRate: Double) -> CMTime {
        Timeline.frameDuration(for: frameRate)
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

private extension Placement.Piece {
    /// The part of the piece the file has frames for, where it plays in
    /// root time, and for how long: the piece itself unless the file runs
    /// out at one end, when the footage that is left plays for the share of
    /// the piece's time it has the share of the piece's file for. Nil when
    /// none of it is in the file.
    func within(_ available: CMTimeRange) -> (file: CMTimeRange, at: CMTime, length: CMTime)? {
        let kept = file.intersection(available)
        guard kept.isValid, kept.duration > .zero else { return nil }
        guard kept != file else { return (file, at, duration) }
        let ratio = file.duration.seconds > 0 ? duration.seconds / file.duration.seconds : 1
        let skipped = CMTimeSubtract(kept.start, file.start)
        return (
            kept,
            duration == file.duration ? CMTimeAdd(at, skipped) : CMTimeAdd(at, CMTimeMultiplyByFloat64(skipped, multiplier: ratio)),
            duration == file.duration ? kept.duration : CMTimeMultiplyByFloat64(kept.duration, multiplier: ratio)
        )
    }
}

extension CompositionExporter {
    /// The footage an effect takes, for the stretch of the timeline `visible`
    /// where its clip is: it starts with the clip, `input.offset` into itself,
    /// and plays at its own speed. At its end it holds its last frame, or
    /// plays again from its start when it loops. Nil when the asset has no
    /// file or no pictures.
    fileprivate static func inputPlacement(
        _ assetID: UUID,
        input: EffectInput,
        clip: TimelineClip,
        visible: CMTimeRange,
        project: EditingProject,
        frameSize: CGSize,
        offset: CMTime
    ) async throws -> (Placement, CGAffineTransform)? {
        guard let media = project.mediaClip(id: assetID), media.kind == .video, let url = media.url else { return nil }
        let info = try await MediaTrackCache.shared.info(for: url)
        guard info.video != nil, media.duration > .zero else { return nil }

        let frame = Timeline.frameDuration(for: media.frameRate > 0 ? media.frameRate : 24)
        let length = media.duration
        var position = CMTimeAdd(input.offset, CMTimeSubtract(visible.start, clip.startOffset))
        var left = visible.duration
        var at = CMTimeAdd(visible.start, offset)
        var pieces: [Placement.Piece] = []
        if input.loops {
            position = CMTime(seconds: position.seconds.truncatingRemainder(dividingBy: length.seconds), preferredTimescale: 240_000)
        }
        while left > .zero, pieces.count < 4000 {
            if position < length {
                let span = CMTimeMinimum(left, CMTimeSubtract(length, position))
                pieces.append(Placement.Piece(
                    file: CMTimeRange(start: media.fileTime(forSourceTime: position), duration: span), at: at, duration: span
                ))
                left = CMTimeSubtract(left, span)
                at = CMTimeAdd(at, span)
                position = CMTimeAdd(position, span)
            } else if !input.loops {
                // Past the end: its last frame, held for what remains.
                let last = CMTimeMaximum(.zero, CMTimeSubtract(length, frame))
                pieces.append(Placement.Piece(
                    file: CMTimeRange(start: media.fileTime(forSourceTime: last), duration: frame), at: at, duration: left
                ))
                left = .zero
            } else {
                position = .zero
            }
        }
        guard !pieces.isEmpty else { return nil }
        let base = info.orientedTransform.concatenating(fitTransform(from: info.orientedSize, to: frameSize))
        return (Placement(info: info, pieces: pieces, includesVideo: true, includesAudio: false), base)
    }
}
