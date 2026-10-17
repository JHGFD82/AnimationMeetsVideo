import AVFoundation
import CoreMedia
import Foundation

// What a composition is built from on its way to being one: media placed
// in root time, the tracks hosting it, and the clips to draw.

/// Track metadata for one media file, loaded once and reused across the many
/// rebuilds an editing session triggers.
struct MediaTrackInfo: @unchecked Sendable {
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

actor MediaTrackCache {
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
final class Placement {
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
struct PlacementExtras {
    var next: Placement?
    var opticalFlow = false
    var echoes: [(placement: Placement, strength: Double)] = []
    var trails: [(placement: Placement, strength: Double)] = []
    var frameDuration = CMTime.zero
    var alignmentOffset = CMTime.zero
}

/// An ordered run of non-overlapping placements that share composition
/// tracks.
final class TrackHost {
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
enum BuildInput {
    case track(Placement, base: CGAffineTransform)
    case group(frameSize: CGSize, toOuter: CGAffineTransform, children: [BuildNode])
}

/// A clip on its way to being a `DrawClip`, once the composition's tracks
/// exist.
final class BuildNode {
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
struct PlannedRange {
    var range: CMTimeRange
    var clips: [DrawClip]
    var segment: RenderSegment
    /// The track whose frames are the stretch's as they are, when that is
    /// all it is.
    var passthrough: CMPersistentTrackID?
}

extension Placement.Piece {
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
