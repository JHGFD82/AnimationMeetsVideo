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

    /// What is being dragged; empty when no drag from the browser is on.
    private(set) var pieces: [MediaPiece] = []
    /// The layer the drag is over, while the media would go on it.
    private(set) var targetLayerID: UUID?
    /// Where the pointer is on that layer: where the media would start. Kept
    /// apart from the layer so views of other layers, which read only the
    /// layer, don't redraw each time the pointer moves.
    private(set) var targetTime = CMTime.zero

    var isDragging: Bool { !pieces.isEmpty }

    func begin(_ pieces: [MediaPiece]) {
        self.pieces = pieces
        targetLayerID = nil
    }

    func target(_ layerID: UUID?, at time: CMTime = .zero) {
        if targetLayerID != layerID { targetLayerID = layerID }
        if layerID != nil, targetTime != time { targetTime = time }
    }

    func end() {
        pieces = []
        targetLayerID = nil
    }
}
