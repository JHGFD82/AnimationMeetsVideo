import CoreMedia
import Foundation

struct MediaClip: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: MediaKind
    var url: URL?
    var duration: CMTime
    var frameRate: Double
    var colorSpace: ProjectColorSpace
    var codecName: String
    /// Whether the file has an audio track, which is what beat detection reads.
    /// True for audio files and for videos with sound.
    var hasAudio = false
    /// Hand-made changes to this asset's scene list. Detected cuts are not
    /// stored; they are recomputed from the saved change scores.
    var sceneEdits = SceneEdits()
    /// Set by Don't Detect Scenes: the asset's cuts aren't looked for (a
    /// search under way stops), and any found aren't used, so it is one
    /// clip in the browser. An edit like any other, so it can be undone.
    var skipsSceneDetection = false
    /// The beats as the person confirmed them, in original time. Detected
    /// beats are not stored here; they are a cache in the package.
    var beatMap = BeatMap()
    /// How much later a moment is in the current file than in the original:
    /// original time `t` is at `t + alignmentOffset` in the file. Trims,
    /// scenes and cuts stay in original time; this is added when reading.
    var alignmentOffset = CMTime.zero
    /// Files this asset used to point at, newest last. Only paths are kept,
    /// so a person can point the asset back at an earlier file.
    var previousPaths: [String] = []
    /// Size and modification time of the file when the project last accepted
    /// it. A different stamp on opening means it was swapped outside the app.
    var acceptedStamp: FileStamp?
    /// How long the original file was, kept when the asset is first
    /// replaced. The original's editing time stays `0..<originalDuration`:
    /// a longer replacement does not extend it, and a shorter one leaves
    /// part of it uncovered. Nil while the file is the original, and for
    /// assets replaced before it was kept.
    var originalDuration: CMTime?
    /// True once the person chose to forget the original. Its reference data
    /// is deleted at the next save and not captured again from whatever file
    /// is there now.
    var referenceForgotten = false

    /// True once the asset points at a file other than the one it was
    /// imported with, or at the same file realigned after it changed.
    var wasReplaced: Bool { !previousPaths.isEmpty || alignmentOffset != .zero }

    /// Where original time `time` is in the current file.
    func fileTime(forSourceTime time: CMTime) -> CMTime {
        CMTimeAdd(time, alignmentOffset)
    }

    var formatSummary: String {
        "\(kind.rawValue) · \(codecName) · \(colorSpace.rawValue)"
    }

    /// How long a still lasts when placed from the browser. It is a still's
    /// `duration`; its clips can then be trimmed to any length.
    static let stillLength = CMTime(value: 5, timescale: 1)
}

enum MediaKind: String, CaseIterable {
    case video = "Video"
    case audio = "Audio"
    /// A still picture (see docs/graphic-layers.md): no time of its own,
    /// so its clips can last as long as anyone wants.
    case image = "Image"

    var systemImage: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }

    /// Whether it has pictures to draw.
    var hasPictures: Bool { self != .audio }
}

enum ProjectColorSpace: String, CaseIterable, Identifiable {
    case rec709 = "Rec. 709"
    case rec2020PQ = "Rec. 2020 PQ HDR"
    case rec2020HLG = "Rec. 2020 HLG"

    var id: Self { self }

    var isHDR: Bool {
        switch self {
        case .rec709: false
        case .rec2020PQ, .rec2020HLG: true
        }
    }
}
