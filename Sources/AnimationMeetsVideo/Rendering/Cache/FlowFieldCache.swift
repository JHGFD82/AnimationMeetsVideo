import CoreGraphics
import CoreVideo
import Foundation
import os

/// Optical Flow's motion between two neighboring frames of footage, kept by
/// the compositor that measured it. The motion depends only on the two
/// frames, not on how far between them a moment falls, so every moment
/// drawn from the same pair takes it from here: each motion blur sample of
/// one frame, and each frame of a slowed clip that falls between the same
/// two frames of its file. Measuring takes many milliseconds; drawing along
/// it, a fraction of one.
///
/// A pair is looked up by the file and where the first frame is in it,
/// counted as the blend counts frames to find its fraction. That count
/// assumes every frame lasts as long, which footage with uneven frame
/// timing (as phones record) breaks, so a field is only taken when the two
/// frames are also the ones it was measured from: each pair keeps a
/// fingerprint of both frames' pixels (`Fingerprint`), and one that doesn't
/// match is measured again. It lives as long as its compositor: one
/// export or render.
final class FlowFieldCache: Sendable {
    struct Pair: Hashable, Sendable {
        var url: URL
        /// The first frame, counted in `frameSeconds` from the start of the
        /// file, moved by `alignmentSeconds` as the blend's position is.
        var frame: Int64
        var frameSeconds: Double
        var alignmentSeconds: Double
        /// How much later the second frame's track plays the footage.
        var nextDelaySeconds: Double
        /// The frames' size in pixels.
        var width: Double
        var height: Double
    }

    /// The pixels of both frames at a sparse grid of points, hashed: enough
    /// to tell two different frames apart, and read in microseconds.
    struct Fingerprint: Equatable, Sendable {
        var first: Int
        var second: Int

        /// Nil when a buffer can't be read, in which case nothing is kept.
        init?(_ first: CVPixelBuffer, _ second: CVPixelBuffer) {
            guard let a = Self.hash(first), let b = Self.hash(second) else { return nil }
            self.first = a
            self.second = b
        }

        /// Points across and down the grid.
        static let columns = 32, rows = 18

        private static func hash(_ buffer: CVPixelBuffer) -> Int? {
            guard !CVPixelBufferIsPlanar(buffer) else { return nil }
            let bytesPerPixel: Int
            switch CVPixelBufferGetPixelFormatType(buffer) {
            case kCVPixelFormatType_64RGBAHalf: bytesPerPixel = 8
            case kCVPixelFormatType_32BGRA: bytesPerPixel = 4
            default: return nil
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            guard width > 0, height > 0 else { return nil }
            var hasher = Hasher()
            hasher.combine(width)
            hasher.combine(height)
            for row in 0..<rows {
                let y = (2 * row + 1) * height / (2 * rows)
                for column in 0..<columns {
                    let x = (2 * column + 1) * width / (2 * columns)
                    hasher.combine(bytes: UnsafeRawBufferPointer(start: base.advanced(by: y * rowBytes + x * bytesPerPixel), count: bytesPerPixel))
                }
            }
            return hasher.finalize()
        }
    }

    private struct Kept {
        var fingerprint: Fingerprint
        /// Nil where Vision couldn't measure the pair, so it isn't asked again.
        var field: OpticalFlow.Field?
    }

    private struct State {
        var fields: [Pair: Kept] = [:]
        /// Oldest use first.
        var order: [Pair] = []
        var measured = 0
    }

    /// How many pairs are kept. A field is under 2 MB, and frames are drawn
    /// in order, a few at a time, so a handful covers what is in flight.
    let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    /// The field for `pair`, whose frames have `fingerprint`, measured by
    /// `measure` the first time it is asked for, and again if the frames
    /// found under it differ. Two frames drawn at once may both measure a
    /// new pair; the second's is kept.
    func field(for pair: Pair, fingerprint: Fingerprint, measure: () -> OpticalFlow.Field?) -> OpticalFlow.Field? {
        if let kept = state.withLock({ state -> OpticalFlow.Field?? in
            guard let kept = state.fields[pair], kept.fingerprint == fingerprint else { return nil }
            state.order.removeAll { $0 == pair }
            state.order.append(pair)
            return .some(kept.field)
        }) {
            return kept
        }
        let field = measure()
        state.withLock { state in
            state.measured += 1
            if state.fields.updateValue(Kept(fingerprint: fingerprint, field: field), forKey: pair) == nil {
                state.order.append(pair)
            }
            while state.order.count > capacity {
                state.fields[state.order.removeFirst()] = nil
            }
        }
        return field
    }

    /// How many times a field was measured rather than found, for tests.
    var measuredCount: Int { state.withLock { $0.measured } }
}
