import AppKit
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
    /// The text on the system's drag pasteboard: the payload of the drag
    /// now on, or what an earlier one left. Replaced in tests.
    @ObservationIgnored var dragText: () -> String? = { NSPasteboard(name: .drag).string(forType: .string) }

    /// Whether a drag of media from the browser is on. A drag SwiftUI
    /// started (a timeline's name) tells no one when it ends, so one
    /// cancelled leaves `pieces` behind; text another drag carries that
    /// isn't media from the browser (text from another app, an effect)
    /// says that drag is a different one. Text that can't be read yet
    /// doesn't say, so it is taken as this drag's.
    var isDragging: Bool {
        guard !pieces.isEmpty else { return false }
        return dragText().map(MediaDragPayload.isPayloadText) ?? true
    }

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
