import Foundation
import SwiftUI

/// How the timeline's three areas share its height: which are shown, how
/// much of the height each takes, and how tall each one's layers are.
///
/// Heights are kept as shares rather than points, so resizing the whole
/// timeline (the grip between it and the viewer) grows or shrinks every
/// area in proportion. Growing an area shows more of its layers; it never
/// makes them taller. Layer height is each area's own vertical zoom.
/// Saved in the app's defaults, so the layout outlives the window.
struct TimelineAreaLayout: Equatable, Codable {
    /// Top to bottom, as the timeline stacks them.
    static let order: [LayerKind] = [.video, .sound, .music]

    static let minimumAreaHeight: CGFloat = 44
    static let layerHeightRange: ClosedRange<CGFloat> = 24...240

    var hidden: Set<LayerKind> = []
    var shares: [LayerKind: CGFloat] = [.video: 0.5, .sound: 0.25, .music: 0.25]
    var layerHeights: [LayerKind: CGFloat] = [.video: 56, .sound: 44, .music: 44]

    /// The shown areas, top to bottom.
    var shown: [LayerKind] { Self.order.filter { !hidden.contains($0) } }

    func isShown(_ kind: LayerKind) -> Bool { !hidden.contains(kind) }

    mutating func setShown(_ kind: LayerKind, _ isShown: Bool) {
        if isShown { hidden.remove(kind) } else { hidden.insert(kind) }
    }

    func layerHeight(_ kind: LayerKind) -> CGFloat {
        layerHeights[kind] ?? 56
    }

    mutating func setLayerHeight(_ kind: LayerKind, _ height: CGFloat) {
        layerHeights[kind] = min(max(height, Self.layerHeightRange.lowerBound), Self.layerHeightRange.upperBound)
    }

    /// Each shown area's height when `available` points are split among
    /// them by their shares.
    func heights(splitting available: CGFloat) -> [LayerKind: CGFloat] {
        let shown = shown
        let total = shown.reduce(0) { $0 + max(share($1), 0.01) }
        var heights: [LayerKind: CGFloat] = [:]
        for kind in shown {
            heights[kind] = max(0, available * max(share(kind), 0.01) / total)
        }
        return heights
    }

    /// Moves the boundary above `kind` down by `dy` points (up when
    /// negative), trading height with the shown area above it. Neither
    /// gets smaller than `minimumAreaHeight`.
    mutating func moveBoundary(above kind: LayerKind, by dy: CGFloat, from start: [LayerKind: CGFloat], available: CGFloat) {
        let shown = shown
        guard available > 0, let index = shown.firstIndex(of: kind), index > 0,
              let below = start[kind], let above = start[shown[index - 1]]
        else {
            return
        }
        let minimum = min(Self.minimumAreaHeight, (above + below) / 2)
        let clamped = min(max(dy, minimum - above), below - minimum)
        var heights = start
        heights[shown[index - 1]] = above + clamped
        heights[kind] = below - clamped
        for kind in shown {
            shares[kind] = (heights[kind] ?? 0) / available
        }
    }

    private func share(_ kind: LayerKind) -> CGFloat {
        shares[kind] ?? 1.0 / 3
    }
}

extension TimelineAreaLayout: RawRepresentable {
    init?(rawValue: String) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: Data(rawValue.utf8)) else { return nil }
        self = decoded
    }

    var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension LayerKind: Codable {
    /// The area's hue: the colour of its clips, its title and its "new
    /// layer" drop zone.
    var tone: Color {
        switch self {
        case .video: Design.ClipTone.video.color
        case .sound: Design.ClipTone.audio.color
        case .music: Design.ClipTone.music.color
        }
    }
}

/// Where things are on screen, for drags that cross the areas: each area
/// scrolls on its own, so a layer's place can't be worked out from the
/// layout alone. A reference type, so recording a frame on every scroll
/// doesn't redraw the timeline; it is read only while dragging.
final class TimelineGeometryStore {
    /// Each layer's clip row, in window coordinates.
    var layerRows: [UUID: CGRect] = [:]
    /// The layer names column, across every shown area, in window
    /// coordinates. Clips and media dropped here go on a new layer.
    var namesColumn: CGRect = .zero
    /// Each shown area's visible part, in window coordinates.
    var areas: [LayerKind: CGRect] = [:]
}
