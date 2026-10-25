import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The trim preview keeps up with a drag: asked for frame after frame
/// faster than they can be read, it shows the newest once it settles,
/// rather than nothing new until the asking stops.
@MainActor
@Suite struct TrimPreviewTests {
    private func brightness(_ image: CGImage?) -> Int? {
        guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        // The middle pixel's first channel.
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * (image.bitsPerPixel / 8)
        return Int(bytes[offset])
    }

    @Test func showsTheNewestFrameOfAQuickDrag() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "amv-trim-preview-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        // Black for a second, then white for a second.
        try await writeMovie(to: url, segments: [(0, 24), (255, 24)])
        let model = TrimPreviewModel()
        // A drag from the black half into the white one, a step every few
        // milliseconds, as fast as the pointer reports.
        var shownDuringDrag = 0
        var lastShown: CGImage?
        for frame in 0..<40 {
            let time = CMTime(value: Int64(frame), timescale: 24)
            model.show(url: url, first: time, last: time, labelFirst: time, labelLast: time, frames: .first)
            try await Task.sleep(for: .milliseconds(8))
            if let image = model.firstFrame, image !== lastShown {
                shownDuringDrag += 1
                lastShown = image
            }
        }
        // The picture changed as the drag went, not only once it stopped.
        #expect(shownDuringDrag >= 2)
        // Black was read along the way; the white the drag ended on is shown.
        for _ in 0..<400 where (brightness(model.firstFrame) ?? 0) < 200 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect((brightness(model.firstFrame) ?? 0) > 200)
        #expect(model.firstTime == CMTime(value: 39, timescale: 24))
    }
}
