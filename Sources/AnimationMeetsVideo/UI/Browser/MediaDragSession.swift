import CoreMedia
import Foundation
import Observation

/// The drag of media from the browser in progress, shared by the browser
/// that started it and the timeline it is over. A drop target can't read
/// a drag's payload until the drop, so what is dragged is noted here as
/// the drag begins; the layer it is over notes itself here while the
/// media would fit there, so the layer draws where it would land and the
/// browser stops drawing its thumbnail under the pointer.
@MainActor @Observable
final class MediaDragSession {
    static let shared = MediaDragSession()

    struct Target: Equatable {
        var layerID: UUID
        /// Where the pointer is on the timeline: where the media would start.
        var time: CMTime
    }

    /// What is being dragged; empty when no drag from the browser is on.
    private(set) var pieces: [MediaPiece] = []
    /// The layer the drag is over, while the media would fit on it.
    var target: Target?

    var isDragging: Bool { !pieces.isEmpty }

    func begin(_ pieces: [MediaPiece]) {
        self.pieces = pieces
        target = nil
    }

    func end() {
        pieces = []
        target = nil
    }
}
