import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// Draws frames straight through `LayeredCompositor` from synthetic
/// pictures, so what each step does can be checked against exact numbers.
/// Pictures are half-float RGBA, premultiplied, the size of the frame.
struct CompositorHarness {
    typealias Color = SIMD4<Float>

    let size: CGSize
    private(set) var pictures: [CMPersistentTrackID: CVPixelBuffer] = [:]
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    init(size: CGSize = CGSize(width: 16, height: 8)) {
        self.size = size
    }

    /// A picture in which `color(x, y)` (fractions across and down, from
    /// the top left) gives the straight RGBA of each pixel.
    mutating func addPicture(track: CMPersistentTrackID, _ color: (Double, Double) -> Color) throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_64RGBAHalf, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<Int(size.height) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<Int(size.width) {
                let c = color((Double(x) + 0.5) / Double(size.width), (Double(y) + 0.5) / Double(size.height))
                row[x * 4] = Float16(c.x * c.w)
                row[x * 4 + 1] = Float16(c.y * c.w)
                row[x * 4 + 2] = Float16(c.z * c.w)
                row[x * 4 + 3] = Float16(c.w)
            }
        }
        pictures[track] = pixels
    }

    mutating func addSolid(track: CMPersistentTrackID, _ color: Color) throws {
        try addPicture(track: track) { _, _ in color }
    }

    /// A picture clip showing track `track` as it is, with this stack.
    static func clip(
        track: CMPersistentTrackID, effects: [Effect] = [], frame: CGSize = CGSize(width: 16, height: 8),
        base: CGAffineTransform = .identity, layer: UUID = UUID()
    ) -> DrawClip {
        DrawClip(
            content: .media(MediaDraw(
                trackID: track, base: base, url: URL(fileURLWithPath: "/dev/null"), sourceStart: .zero, segmentStart: .zero
            )),
            stack: ClipStack(effects: effects, center: CGPoint(x: frame.width / 2, y: frame.height / 2)),
            range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), owner: UUID(), layerID: layer
        )
    }

    /// An adjustment clip applying `effects` to the layers `reaching` (all
    /// the layers below it when nil). Clips are given to `draw` through
    /// `DrawClip.assembled`, as the composition does.
    static func adjustment(
        effects: [Effect], reaching layers: Set<UUID>? = nil, frame: CGSize = CGSize(width: 16, height: 8)
    ) -> DrawClip {
        DrawClip(
            content: .adjustment(AdjustmentDraw(reachedLayerIDs: layers ?? [], reachesAll: layers == nil)),
            stack: ClipStack(effects: effects, center: CGPoint(x: frame.width / 2, y: frame.height / 2)),
            range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), owner: UUID()
        )
    }

    /// A nested timeline of `children` (top first), drawn as one picture
    /// unless it passes through.
    static func group(
        _ children: [DrawClip], effects: [Effect] = [], passThrough: Bool = false,
        frame: CGSize = CGSize(width: 16, height: 8), nestedFrame: CGSize? = nil,
        toOuter: CGAffineTransform = .identity, pushesTransforms: Bool = true
    ) -> DrawClip {
        DrawClip(
            content: .group(GroupDraw(
                frameSize: nestedFrame ?? frame, toOuter: toOuter, passThrough: passThrough, children: children,
                pushesTransforms: pushesTransforms
            )),
            stack: ClipStack(effects: effects, center: CGPoint(x: frame.width / 2, y: frame.height / 2)),
            range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), owner: UUID()
        )
    }

    /// The frame drawn from `clips` (top first), as straight RGBA per pixel
    /// from the top left, row by row.
    func draw(_ clips: [DrawClip], at time: CMTime = .zero, options: DrawingOptions? = nil) throws -> [Color] {
        let instruction = LayeredInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)),
            clips: DrawClip.assembled(clips), renderSize: size, colorSpace: .rec709, options: options
        )
        let pictures = pictures
        let image = LayeredCompositor.compose(instruction, at: time, outputSize: size) { pictures[$0] }
        let width = Int(size.width), height = Int(size.height)
        var bytes = [Float](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(origin: .zero, size: size), format: .RGBAf, colorSpace: nil)
        }
        // CI's rows start at the bottom; return them from the top.
        var colors: [Color] = []
        for y in (0..<height).reversed() {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let a = bytes[i + 3]
                colors.append(a > 0 ? Color(bytes[i] / a, bytes[i + 1] / a, bytes[i + 2] / a, a) : .zero)
            }
        }
        return colors
    }

    func pixel(_ colors: [Color], x: Int, y: Int) -> Color {
        colors[y * Int(size.width) + x]
    }
}

func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, tolerance: Float = 0.01) -> Bool {
    (0..<4).allSatisfy { abs(a[$0] - b[$0]) <= tolerance }
}
