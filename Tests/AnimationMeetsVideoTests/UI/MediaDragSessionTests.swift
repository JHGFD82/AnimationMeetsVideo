import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

@MainActor
struct MediaDragSessionTests {
    private let pieces = [MediaPiece(assetID: UUID(), start: .zero, end: CMTime(seconds: 2, preferredTimescale: 600))]

    @Test func aDragOfMediaFromTheBrowserIsOn() {
        let session = MediaDragSession()
        session.dragText = { [pieces] in MediaDragPayload(pieces: pieces).text }
        #expect(!session.isDragging)
        session.begin(pieces)
        #expect(session.isDragging)
        session.end()
        #expect(!session.isDragging)
    }

    @Test func otherTextDraggedAfterACancelledDragIsNotTaken() {
        // A timeline's name dragged and let go with Escape tells the
        // session nothing; text from another app is a drag of its own.
        let session = MediaDragSession()
        session.begin(pieces)
        session.dragText = { "Hello from another app" }
        #expect(!session.isDragging)
    }

    @Test func textNotYetReadableIsTakenAsTheDrags() {
        let session = MediaDragSession()
        session.begin(pieces)
        session.dragText = { nil }
        #expect(session.isDragging)
    }
}
