import CoreGraphics
import CoreVideo
import Foundation

/// A picture the viewer shows over the video while paused (`PlaybackModel
/// .cover`): an image, such as a full-size still, or a frame of the
/// timeline as the compositor draws it, tagged with the timeline's colors
/// as the player's frames are. The screen color-matches a frame on the GPU
/// as it does the video; an image Core Animation converts on the main
/// thread each time it is shown, which a frame for every step of a drag
/// can't afford.
///
/// Sendable: neither picture is changed once drawn.
enum CoverPicture: @unchecked Sendable {
    case image(CGImage)
    case frame(CVPixelBuffer)

    /// What a layer shows it with.
    var layerContents: Any {
        switch self {
        case .image(let image): image
        case .frame(let buffer): CVPixelBufferGetIOSurface(buffer).map { $0.takeUnretainedValue() as Any } ?? buffer
        }
    }

    /// Whether it is the very same picture as `other`.
    func isSame(as other: CoverPicture?) -> Bool {
        switch (self, other) {
        case (.image(let a), .image(let b)?): a === b
        case (.frame(let a), .frame(let b)?): a === b
        default: false
        }
    }
}
