import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import AnimationMeetsVideo

/// Media and projects made for the code review in place of licensed footage
/// (code-review-plan.md, stabilization checkpoint D): every frame carries
/// its own number as a barcode across its top, so the frame a viewer,
/// export or seek shows can be read back exactly, and its picture holds
/// what anime footage holds that the app's correctness turns on (held
/// drawings, flashes, fades, flat gradients, sharp outlines). Sound is a
/// click at the sample each flash starts, for sync to the sample.
///
/// Small enough to make in a test; `ReviewFixtureTests.makeTheReviewSet`
/// writes the whole set to `REVIEW_FIXTURES` for benchmarks and by-hand
/// review.
enum ReviewFixtures {
    static let width = 320, height = 180
    /// The barcode's bars: the frame number in binary, most significant
    /// first, across the top `barHeight` rows.
    static let bars = 16
    static let barHeight = 24
    static let sampleRate = 48_000.0

    /// What a frame shows below its number.
    enum Picture: Sendable {
        /// A drawing held for `hold` frames (2 for "on twos"), as a disc
        /// that moves only when the drawing changes, over a flat field.
        case held(hold: Int)
        /// White every `every` frames, else the held drawing.
        case flashes(every: Int, hold: Int)
        /// From black to white and back over `length` frames.
        case fade(length: Int)
        /// A shallow horizontal gradient across 20 levels, which bands at 8
        /// bits if anything flattens it.
        case gradient
        /// One-pixel black outlines on flat color, moving a pixel a frame,
        /// for ringing and halos from resampling and sharpening.
        case outlines
    }

    /// How frames are timed.
    enum Timing: Sendable {
        /// A constant rate: one frame every `duration`.
        case constant(CMTime)
        /// Each frame's own duration, in order, cycling: a screen recording's
        /// variable rate.
        case variable([CMTime])
    }

    /// Each frame's presentation time.
    static func times(_ timing: Timing, count: Int) -> [CMTime] {
        switch timing {
        case .constant(let duration):
            return (0..<count).map { CMTimeMultiply(duration, multiplier: Int32($0)) }
        case .variable(let durations):
            var time = CMTime.zero
            return (0..<count).map { index in
                defer { time = CMTimeAdd(time, durations[index % durations.count]) }
                return time
            }
        }
    }

    /// The color at (x, y) of frame `index`.
    static func color(of picture: Picture, frame index: Int, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        if y < barHeight {
            let bar = x * bars / width
            let bit = (index >> (bars - 1 - bar)) & 1
            // A dark gap between bars so they don't run together.
            if x % (width / bars) < 2 { return (40, 40, 40) }
            return bit == 1 ? (255, 255, 255) : (0, 0, 0)
        }
        switch picture {
        case .held(let hold):
            return disc(drawing: index / max(hold, 1), x: x, y: y)
        case .flashes(let every, let hold):
            if index % max(every, 1) == 0 { return (255, 255, 255) }
            return disc(drawing: index / max(hold, 1), x: x, y: y)
        case .fade(let length):
            let phase = Double(index % max(length, 1)) / Double(max(length, 1))
            let level = UInt8((phase < 0.5 ? phase * 2 : (1 - phase) * 2) * 255)
            return (level, level, level)
        case .gradient:
            let level = UInt8(110 + 20 * x / width)
            return (level, level, UInt8(min(255, Int(level) + 10)))
        case .outlines:
            let shift = index % 40
            if (x + shift) % 40 == 0 || (y - barHeight + shift) % 40 == 0 { return (0, 0, 0) }
            return (230, 170, 120)
        }
    }

    private static func disc(drawing: Int, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let cx = 40 + (drawing * 23) % (width - 80), cy = barHeight + 30 + (drawing * 17) % (height - barHeight - 60)
        let dx = x - cx, dy = y - cy
        if dx * dx + dy * dy < 400 { return (240, 90, 60) }
        return (70, 120, 200)
    }

    /// The frame number a picture's barcode holds, read from 8-bit RGBA or
    /// BGRA rows; nil when it can't be read.
    static func frameNumber(in image: CGImage) -> Int? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }
        let scaleX = Double(image.width) / Double(width), scaleY = Double(image.height) / Double(height)
        var number = 0
        for bar in 0..<bars {
            let x = Int((Double(bar) + 0.5) * Double(width / bars) * scaleX)
            let y = Int(Double(barHeight / 2) * scaleY)
            let offset = y * image.bytesPerRow + x * bytesPerPixel
            let luma = (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
            number = number << 1 | (luma > 128 ? 1 : 0)
        }
        return number
    }

    /// Writes `count` frames of `picture` as H.264 with a key frame only
    /// every `keyFrameInterval` frames (long-GOP, as broadcast and web video
    /// are).
    static func writeMovie(
        to url: URL, picture: Picture, timing: Timing, count: Int, keyFrameInterval: Int = 120
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoAverageBitRateKey: 2_000_000,
            ],
        ])
        if case .constant(let duration) = timing { input.mediaTimeScale = duration.timescale }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for (index, time) in times(timing, count: count).enumerated() {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let pixels = buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = color(of: picture, frame: index, x: x, y: y)
                    let offset = y * stride + x * 4
                    base[offset] = b; base[offset + 1] = g; base[offset + 2] = r; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// The sample at which frame `index` of a constant-rate `duration`
    /// begins, rounded to the nearest: exact at 24 and 23.976 fps (2,000
    /// and 2,002 samples a frame), within half a sample at 29.97.
    static func sample(ofFrame index: Int, duration: CMTime) -> Int {
        Int((Double(index) * Double(duration.value) * sampleRate / Double(duration.timescale)).rounded())
    }

    /// A stereo WAV `seconds` long, silent but for a click (2 ms at 0.9 of
    /// full scale) at each of `samples`.
    static func writeClicks(to url: URL, at samples: [Int], seconds: Double) throws {
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)
        else { throw CocoaError(.fileWriteUnknown) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = Int(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(count)
        let click = Int(sampleRate * 0.002)
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for index in 0..<count { data[index] = 0 }
            for start in samples where start < count {
                for offset in 0..<min(click, count - start) { data[start + offset] = 0.9 }
            }
        }
        try file.write(from: buffer)
    }

    /// Frame durations at the rates the review checks.
    static let rates: [(name: String, duration: CMTime)] = [
        ("23.976", CMTime(value: 1001, timescale: 24000)),
        ("24", CMTime(value: 1, timescale: 24)),
        ("29.97", CMTime(value: 1001, timescale: 30000)),
        ("30", CMTime(value: 1, timescale: 30)),
        ("60", CMTime(value: 1, timescale: 60)),
    ]

    /// A dense edit: `clipCount` clips of the numbered movie `media`, each
    /// two to six frames long, cut end to end on a 24 fps timeline, every
    /// fifth with a Transform and every seventh blurred, over a song on a
    /// Music layer.
    static func denseProject(media: MediaClip, song: MediaClip, clipCount: Int) throws -> EditingProject {
        var project = EditingProject.empty
        project.name = "Dense review edit"
        let timelineID = project.rootTimelineID
        project.clips.append(media)
        project.clips.append(song)
        project.putOnMusicLayer([song.id])
        let frame = CMTime(value: 1, timescale: 24)
        var source = CMTime.zero
        let lengths = [2, 3, 4, 6, 5, 2, 3]
        var pieces: [MediaPiece] = []
        for index in 0..<clipCount {
            let length = CMTimeMultiply(frame, multiplier: Int32(lengths[index % lengths.count]))
            if CMTimeAdd(source, length) > media.duration { source = .zero }
            pieces.append(MediaPiece(assetID: media.id, start: source, end: CMTimeAdd(source, length)))
            source = CMTimeAdd(source, CMTimeMultiply(length, multiplier: 3))
        }
        // One after another on one layer.
        guard let placed = project.addPieces(pieces, intoTimeline: timelineID, at: .zero) else { throw CocoaError(.fileWriteUnknown) }
        let blur = EffectKind(builtIn: "gaussianBlur")
        for (index, clipID) in placed.clipIDs.enumerated() {
            if index % 5 == 0 { _ = project.addEffect(.transform, toClip: clipID, in: timelineID) }
            if index % 7 == 0 { _ = project.addEffect(blur, toClip: clipID, in: timelineID) }
        }
        return project
    }
}
