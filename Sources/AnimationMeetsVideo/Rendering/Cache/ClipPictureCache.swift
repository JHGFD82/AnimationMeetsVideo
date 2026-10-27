import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os

/// Clips' finished pictures (each put into the frame and run through its
/// stack and transitions, before it is drawn over what is below), drawn
/// into memory and kept for frames that would draw the same picture again,
/// least recently used going first once they pass a budget in bytes:
///
/// - **Trails.** A copy of a clip from `delay` earlier is the picture the
///   clip finished as `delay` earlier, which sequential playback and export
///   have just drawn. It is kept as it is drawn and taken for the copy.
/// - **Dragging a value.** A paused frame drawn again with new values
///   (`LiveFrameRenderer`) draws the same pictures for every clip but the
///   one being changed. A clip drawn the same way twice in a row is kept,
///   and the frames after take it rather than drawing it again.
/// - **Drawn ahead.** The viewer's playhead neighborhood drawn while it is
///   paused keeps every clip it can (`PlayheadPrerenderer`), for playback
///   and scrubbing there to take.
///
/// A picture is found by its `Recipe`: everything that decides it. A clip
/// whose picture depends on more than that (what is below it, another
/// picture, other moments of its footage) is never kept, nor one with
/// nothing done to it, which costs no more to draw than to take from here.
final class ClipPictureCache: @unchecked Sendable {
    /// When a picture drawn is kept.
    enum Keeping: Sendable {
        /// A clip with trails, for its copies in later frames.
        case trails
        /// Also a clip drawn the same way as the last time it was drawn, as
        /// when another clip's value is dragged.
        case steady
        /// Every clip that can be.
        case all
    }

    /// Everything that decides a clip's finished picture.
    struct Recipe: Equatable {
        /// Whose picture it is, and where.
        var clipID: UUID?
        var owner: UUID
        var layerID: UUID
        var url: URL
        var still: ObjectIdentifier?
        var base: CGAffineTransform
        /// The file time of the footage it is drawn from: the clip's at the
        /// frame being drawn, a trail copy's that long before. Nil for a
        /// still or a shape clip.
        var footage: CMTime?
        /// The moment a frame blend is mixed at, and the extra footage
        /// mixed in. A trail copy has neither.
        var blendMoment: CMTime?
        var nextFrame: TrackCopy?
        var echoes: [TrackCopy]
        var opticalFlow: Bool
        /// The stack and transitions at the moment it is drawn at.
        var resolved: ResolvedClip
        /// How it is placed in the timeline it is drawn into.
        var outerMatrix: CGAffineTransform
        var outerOpacity: Double
        var passesThrough: Bool
        var frameSize: CGSize
        var scale: CGSize
        var canvasMargin: Double
        var colorSpace: ProjectColorSpace
        /// Whether it is drawn as the viewer plays, which some looks draw
        /// less for, and whether at export's quality.
        var playing: Bool
        var fullQuality: Bool

        /// The clip, wherever it is drawn: the last recipe drawn for each is
        /// remembered, to see which clips stay the same.
        var clip: Clip { Clip(clipID: clipID, owner: owner, layerID: layerID, scale: scale) }

        fileprivate var slot: Slot {
            Slot(clip: clip, footage: footage.map { Int64(($0.seconds * 1_000_000).rounded()) })
        }
    }

    struct Clip: Hashable {
        var clipID: UUID?
        var owner: UUID
        var layerID: UUID
        var width: Double
        var height: Double

        init(clipID: UUID?, owner: UUID, layerID: UUID, scale: CGSize) {
            self.clipID = clipID
            self.owner = owner
            self.layerID = layerID
            width = scale.width
            height = scale.height
        }
    }

    /// Where recipes are filed: those that can match share one.
    fileprivate struct Slot: Hashable {
        var clip: Clip
        /// In microseconds.
        var footage: Int64?
    }

    private struct Entry {
        var recipe: Recipe
        var picture: CIImage
        var bytes: Int
        var used: UInt64
    }

    private struct State {
        var entries: [Slot: [Entry]] = [:]
        var bytes = 0
        var clock: UInt64 = 0
        var lastDrawn: [Clip: Recipe] = [:]
        var hits = 0
        var kept = 0
        var keptBytes = 0
    }

    /// How many bytes of pictures are kept before the least recently used go.
    let budget: Int
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private static let context: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        return MetalDevice.shared.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    /// The viewer's budget: a sixteenth of the Mac's memory, at most 1 GB.
    /// Half floats take 8 bytes a pixel, so that is about 60 full HD pictures.
    static let viewerBudget = Int(min(UInt64(1 << 30), ProcessInfo.processInfo.physicalMemory / 16))

    init(budget: Int = ClipPictureCache.viewerBudget) {
        self.budget = max(0, budget)
    }

    /// The picture kept for `recipe`, if there is one.
    func picture(for recipe: Recipe) -> CIImage? {
        state.withLock { state in
            let slot = recipe.slot
            guard let index = state.entries[slot]?.firstIndex(where: { $0.recipe == recipe }) else { return nil }
            state.clock += 1
            state.entries[slot]?[index].used = state.clock
            state.hits += 1
            return state.entries[slot]?[index].picture
        }
    }

    /// Notes that `recipe` was drawn, and says whether its clip was drawn
    /// the same way the last time it was.
    func drawnAgain(_ recipe: Recipe) -> Bool {
        state.withLock { state in
            let same = state.lastDrawn[recipe.clip] == recipe
            state.lastDrawn[recipe.clip] = recipe
            return same
        }
    }

    /// `picture` drawn into memory over `canvas` (output pixels) and kept for
    /// `recipe`, returned as the kept picture; nil when it couldn't be
    /// drawn or is larger than the whole budget, and the caller draws it
    /// as it is.
    func keep(_ picture: CIImage, for recipe: Recipe, within canvas: CGRect) -> CIImage? {
        let extent = picture.extent.intersection(canvas).integral
        guard !extent.isNull, !extent.isEmpty, !extent.isInfinite else { return nil }
        let width = Int(extent.width), height = Int(extent.height)
        let bytes = width * height * 8
        guard bytes <= budget else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        // A picture made from a pixel buffer takes its first row as the
        // top, so the top is drawn into the first row; finished before
        // anything reads it.
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = nil
        destination.isFlipped = true
        let placed = picture.cropped(to: extent).transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        guard (try? Self.context.startTask(toRender: placed, to: destination).waitUntilCompleted()) != nil else { return nil }
        let kept = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        state.withLock { state in
            let slot = recipe.slot
            state.clock += 1
            var entries = state.entries[slot] ?? []
            if let index = entries.firstIndex(where: { $0.recipe == recipe }) {
                state.bytes -= entries[index].bytes
                entries.remove(at: index)
            }
            entries.append(Entry(recipe: recipe, picture: kept, bytes: bytes, used: state.clock))
            state.entries[slot] = entries
            state.bytes += bytes
            state.kept += 1
            state.keptBytes += bytes
            Self.evict(&state, toFit: budget)
        }
        return kept
    }

    /// Lets go of the least recently used pictures until the rest fit.
    private static func evict(_ state: inout State, toFit budget: Int) {
        while state.bytes > budget {
            var oldest: (slot: Slot, index: Int, used: UInt64)?
            for (slot, entries) in state.entries {
                for (index, entry) in entries.enumerated() where entry.used < oldest?.used ?? .max {
                    oldest = (slot, index, entry.used)
                }
            }
            guard let oldest else { return }
            state.bytes -= state.entries[oldest.slot]?[oldest.index].bytes ?? 0
            state.entries[oldest.slot]?.remove(at: oldest.index)
            if state.entries[oldest.slot]?.isEmpty == true { state.entries[oldest.slot] = nil }
        }
    }

    /// Lets go of every picture.
    func removeAll() {
        state.withLock { state in
            state.entries = [:]
            state.bytes = 0
            state.lastDrawn = [:]
        }
    }

    /// Pictures taken from here, pictures kept, the bytes kept now, and the
    /// bytes of every picture ever kept, which says how much a pass of
    /// drawing has added whatever went to make room.
    var counts: (hits: Int, kept: Int, bytes: Int, keptBytes: Int) {
        state.withLock { ($0.hits, $0.kept, $0.bytes, $0.keptBytes) }
    }
}
