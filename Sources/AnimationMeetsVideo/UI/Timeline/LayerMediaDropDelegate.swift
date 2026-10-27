import CoreMedia
import SwiftUI

/// Takes media dragged from the browser onto a layer, and while the drag is
/// over the layer, marks it as the drag's target where the media would fit
/// (`MediaDragSession`), so the layer draws it where it would land.
/// Anything else dragged over the layer, such as an effect, is left alone.
struct LayerMediaDropDelegate: DropDelegate {
    let layerID: UUID
    let pixelsPerSecond: CGFloat
    /// Whether the media being dragged would fit on the layer from a time.
    let fits: (CMTime) -> Bool
    let onDrop: ([MediaDragPayload], CMTime) -> Bool
    /// The drag moved over the layer, for the area to scroll at its edge.
    var onHover: () -> Void = {}

    private var session: MediaDragSession { .shared }

    private func time(_ info: DropInfo) -> CMTime {
        CMTime(seconds: max(0, Double(info.location.x / pixelsPerSecond)), preferredTimescale: 600)
    }

    func validateDrop(info: DropInfo) -> Bool {
        session.isDragging && info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        mark(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        mark(info)
        onHover()
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if session.targetLayerID == layerID { session.target(nil) }
    }

    private func mark(_ info: DropInfo) {
        let time = time(info)
        if fits(time) {
            session.target(layerID, at: time)
        } else if session.targetLayerID == layerID {
            session.target(nil)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let time = time(info)
        // A drag SwiftUI started (a timeline's name) has no end of its own
        // to tell the session.
        session.end()
        let providers = info.itemProviders(for: [.text])
        guard !providers.isEmpty else { return false }
        let onDrop = onDrop
        Task { @MainActor in
            var payloads: [MediaDragPayload] = []
            for provider in providers {
                if let payload = await Self.load(provider) { payloads.append(payload) }
            }
            if !payloads.isEmpty { _ = onDrop(payloads, time) }
        }
        return true
    }

    private static func load(_ provider: NSItemProvider) async -> MediaDragPayload? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: MediaDragPayload.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}
