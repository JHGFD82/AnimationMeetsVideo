import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@Suite struct MediaDragPayloadTests {
    @Test func roundTripsPiecesOfSeveralAssetsInOrder() throws {
        let a = UUID(), b = UUID()
        let pieces = [
            MediaPiece(assetID: b, start: CMTime(value: 1001, timescale: 24000), end: CMTime(value: 5, timescale: 1)),
            MediaPiece(assetID: a, start: .zero, end: CMTime(value: 9, timescale: 1)),
            MediaPiece(assetID: b, start: CMTime(value: 7, timescale: 1), end: CMTime(value: 8, timescale: 1)),
        ]
        let payload = try #require(MediaDragPayload(text: MediaDragPayload(pieces: pieces).text))
        #expect(payload.pieces == pieces)
    }

    @Test func roundTripsTimelinesWithClips() throws {
        let pieces = [
            MediaPiece.timeline(UUID(), from: CMTime(value: 1, timescale: 1), to: CMTime(value: 3, timescale: 1)),
            MediaPiece(assetID: UUID(), start: .zero, end: CMTime(value: 2, timescale: 1)),
        ]
        let payload = try #require(MediaDragPayload(text: MediaDragPayload(pieces: pieces).text))
        #expect(payload.pieces == pieces)
        #expect(payload.pieces.map(\.isTimeline) == [true, false])
    }

    @Test func ordinaryTextIsNotAPayload() {
        #expect(MediaDragPayload(text: "hello") == nil)
        #expect(MediaDragPayload(text: "amv-media:{}") == nil)
        #expect(MediaDragPayload(text: "amv-media:{\"pieces\":[]}") == nil)
        #expect(MediaDragPayload(text: "amv-media:not json") == nil)
    }

    @Test func rejectsZeroTimescales() {
        let piece = "{\"assetID\":\"\(UUID().uuidString)\",\"endScale\":0,\"endValue\":1,\"startScale\":24,\"startValue\":0}"
        #expect(MediaDragPayload(text: "amv-media:{\"pieces\":[\(piece)]}") == nil)
    }
}
