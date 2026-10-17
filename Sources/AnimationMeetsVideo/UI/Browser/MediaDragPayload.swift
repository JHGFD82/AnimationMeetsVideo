import CoreMedia
import CoreTransferable
import Foundation

/// Media being dragged from the browser: pieces of one or more assets (whole
/// clips, scenes or a picked range) in the order they go down. It travels
/// as plain text so it works without a registered content type (this app
/// runs unbundled).
struct MediaDragPayload: Transferable, Equatable {
    private struct Wire: Codable {
        struct Piece: Codable {
            var assetID: UUID
            var startValue: Int64
            var startScale: Int32
            var endValue: Int64
            var endScale: Int32
        }

        var pieces: [Piece]
    }

    private static let prefix = "amv-media:"

    /// The first asset of the drag in progress, set as a drag begins. A drop
    /// target can't read the payload until it is dropped, and the timeline
    /// needs to know sooner whether it is sound, to offer the right kind of
    /// new layer. Left set after the drag; only read during one.
    @MainActor static var draggedAssetID: UUID?

    /// The payload for a drag starting now, noting its first asset.
    @MainActor static func beginDrag(_ pieces: [MediaPiece]) -> MediaDragPayload {
        draggedAssetID = pieces.first?.assetID
        return MediaDragPayload(pieces: pieces)
    }

    var pieces: [MediaPiece]

    init(pieces: [MediaPiece]) {
        self.pieces = pieces
    }

    init?(text: String) {
        guard text.hasPrefix(Self.prefix),
              let wire = try? JSONDecoder().decode(Wire.self, from: Data(text.dropFirst(Self.prefix.count).utf8)),
              !wire.pieces.isEmpty,
              wire.pieces.allSatisfy({ $0.startScale > 0 && $0.endScale > 0 })
        else { return nil }
        pieces = wire.pieces.map {
            MediaPiece(
                assetID: $0.assetID,
                start: CMTime(value: $0.startValue, timescale: $0.startScale),
                end: CMTime(value: $0.endValue, timescale: $0.endScale)
            )
        }
    }

    var text: String {
        let wire = Wire(pieces: pieces.map {
            Wire.Piece(
                assetID: $0.assetID, startValue: $0.start.value, startScale: $0.start.timescale,
                endValue: $0.end.value, endScale: $0.end.timescale
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(wire)) ?? Data()
        return Self.prefix + String(decoding: data, as: UTF8.self)
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { $0.text }, importing: { text in
            guard let payload = MediaDragPayload(text: text) else { throw CocoaError(.coderInvalidValue) }
            return payload
        })
    }
}
