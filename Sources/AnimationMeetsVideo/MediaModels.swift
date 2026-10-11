import AVFoundation
import CoreMedia
import Foundation

struct EditingProject: Identifiable {
    let id: UUID
    var name: String
    var clips: [MediaClip]
    var frameRate: Double
    var colorSpace: ProjectColorSpace

    var timebaseSummary: String {
        "\(Int(frameRate)) fps · \(colorSpace.rawValue)"
    }

    static let empty = EditingProject(
        id: UUID(),
        name: "Untitled Project",
        clips: [],
        frameRate: 24,
        colorSpace: .rec709
    )

    static let demo = EditingProject(
        id: UUID(),
        name: "Animation Meets Video",
        clips: [
            MediaClip(name: "Opening animation", kind: .video, duration: CMTime(seconds: 8.4, preferredTimescale: 600), colorSpace: .rec709),
            MediaClip(name: "Voiceover", kind: .audio, duration: CMTime(seconds: 12.1, preferredTimescale: 600), colorSpace: .rec709),
            MediaClip(name: "ProRes plate", kind: .video, duration: CMTime(seconds: 14.8, preferredTimescale: 600), colorSpace: .rec2020PQ)
        ],
        frameRate: 24,
        colorSpace: .rec2020PQ
    )
}

struct MediaClip: Identifiable {
    let id = UUID()
    var name: String
    var kind: MediaKind
    var duration: CMTime
    var colorSpace: ProjectColorSpace

    var formatSummary: String {
        "\(kind.rawValue) · \(colorSpace.rawValue)"
    }
}

enum MediaKind: String {
    case video = "Video"
    case audio = "Audio"

    var systemImage: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        }
    }
}

enum ProjectColorSpace: String {
    case rec709 = "Rec. 709"
    case rec2020PQ = "Rec. 2020 PQ HDR"
    case rec2020HLG = "Rec. 2020 HLG"
}

extension CMTime {
    var formatted: String {
        guard isNumeric else { return "--:--" }
        let totalSeconds = max(0, seconds)
        return String(format: "%02d:%04.1f", Int(totalSeconds) / 60, totalSeconds.truncatingRemainder(dividingBy: 60))
    }
}
