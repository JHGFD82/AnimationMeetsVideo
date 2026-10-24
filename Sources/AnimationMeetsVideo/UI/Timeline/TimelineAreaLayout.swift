import Foundation
import SwiftUI

/// How the timeline's three areas share its height: which are shown, how
/// much of the height each takes, and how tall each one's layers are.
///
/// Heights are kept as shares rather than points, so resizing the whole
/// timeline (the grip between it and the viewer) grows or shrinks every
/// area in proportion. Growing an area shows more of its layers; it never
/// makes them taller. Layer height is each area's own vertical zoom, and a
/// layer can be taller or shorter than its area's by a scale of its own,
/// so zooming the area keeps it in proportion. Saved in the app's
/// defaults, so the layout outlives the window.
struct TimelineAreaLayout: Equatable, Codable {
    /// Top to bottom, as the timeline stacks them.
    static let order: [LayerKind] = [.video, .sound, .music]

    static let minimumAreaHeight: CGFloat = 44
    static let layerHeightRange: ClosedRange<CGFloat> = 24...240

    var hidden: Set<LayerKind> = []
    /// Whether the sections lane under the ruler shows.
    var showsSections = true
    var shares: [LayerKind: CGFloat] = [.video: 0.5, .sound: 0.25, .music: 0.25]
    var layerHeights: [LayerKind: CGFloat] = [.video: 56, .sound: 44, .music: 44]
    /// Layers sized apart from their area, as a multiple of its height.
    var layerScales: [UUID: CGFloat] = [:]

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
        layerHeights[kind] = Self.clamped(height)
    }

    private static func clamped(_ height: CGFloat) -> CGFloat {
        height.clamped(between: layerHeightRange.lowerBound, and: layerHeightRange.upperBound)
    }

    /// One layer's height: its area's, times its own scale if it has one.
    func height(of layerID: UUID, kind: LayerKind) -> CGFloat {
        Self.clamped(layerHeight(kind) * (layerScales[layerID] ?? 1))
    }

    /// Sizes one layer apart from the others of its area.
    mutating func setHeight(_ height: CGFloat, of layerID: UUID, kind: LayerKind) {
        let scale = Self.clamped(height) / layerHeight(kind)
        layerScales[layerID] = abs(scale - 1) < 1e-6 ? nil : scale
    }

    /// Sizes every layer of an area alike: the area's height, with the
    /// scales of `layers` (its layers) dropped.
    mutating func setHeightOfAll(_ height: CGFloat, kind: LayerKind, layers: [UUID]) {
        setLayerHeight(kind, height)
        for id in layers { layerScales[id] = nil }
    }

    /// Sizes every shown area's layers alike, `layers` being all of them.
    mutating func setHeightOfAllShown(_ height: CGFloat, layers: [UUID]) {
        for kind in shown { setLayerHeight(kind, height) }
        for id in layers { layerScales[id] = nil }
    }

    /// A layer height on a 0...1 scale that is even in ratio, so each step
    /// of a slider multiplies the height by the same amount.
    static func fraction(ofLayerHeight height: CGFloat) -> Double {
        ZoomScale.fraction(of: Double(height), in: heightScale)
    }

    static func layerHeight(atFraction fraction: Double) -> CGFloat {
        CGFloat(ZoomScale.zoom(atFraction: fraction, in: heightScale))
    }

    /// The heights the slider spans, as `ZoomScale` takes them.
    private static var heightScale: ClosedRange<Double> {
        Double(layerHeightRange.lowerBound)...Double(layerHeightRange.upperBound)
    }

    /// The shown areas' layer heights together, on the scale of
    /// `fraction(ofLayerHeight:)`: their mean there, which is the
    /// geometric mean of the heights.
    var shownLayerHeightFraction: Double {
        let shown = shown
        guard !shown.isEmpty else { return 0 }
        return shown.reduce(0) { $0 + Self.fraction(ofLayerHeight: layerHeight($1)) } / Double(shown.count)
    }

    /// Zooms every shown area's layers together, to `fraction` on the
    /// scale of `shownLayerHeightFraction`. Each moves by the same ratio,
    /// so an area made taller than the others stays taller. Near either end
    /// of the range the differences shrink just enough to fit, so the
    /// slider's ends make every area shortest or tallest, and the mean is
    /// always exactly `fraction` (the slider never jumps under the pointer).
    mutating func setShownLayerHeightFraction(_ fraction: Double) {
        let shown = shown
        let target = fraction.clamped(between: 0, and: 1)
        let mean = shownLayerHeightFraction
        let offsets = shown.map { Self.fraction(ofLayerHeight: layerHeight($0)) - mean }
        var spread = 1.0
        for offset in offsets where abs(offset) > 1e-12 {
            spread = min(spread, offset > 0 ? (1 - target) / offset : target / -offset)
        }
        for (kind, offset) in zip(shown, offsets) {
            setLayerHeight(kind, Self.layerHeight(atFraction: target + offset * spread))
        }
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
        let clamped = dy.clamped(between: minimum - above, and: below - minimum)
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

    // Written out rather than synthesized: being RawRepresentable as a
    // String (for @AppStorage) brings the standard library's Codable,
    // which goes through rawValue, and rawValue encodes with Codable, so
    // the two would call each other until the stack ran out.
    private enum CodingKeys: String, CodingKey {
        case hidden, shares, layerHeights, layerScales, showsSections
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try container.decode(Set<LayerKind>.self, forKey: .hidden)
        shares = try container.decode([LayerKind: CGFloat].self, forKey: .shares)
        layerHeights = try container.decode([LayerKind: CGFloat].self, forKey: .layerHeights)
        showsSections = try container.decodeIfPresent(Bool.self, forKey: .showsSections) ?? true
        layerScales = try container.decodeIfPresent([UUID: CGFloat].self, forKey: .layerScales) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hidden, forKey: .hidden)
        try container.encode(shares, forKey: .shares)
        try container.encode(layerHeights, forKey: .layerHeights)
        try container.encode(showsSections, forKey: .showsSections)
        try container.encode(layerScales, forKey: .layerScales)
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
    /// Each area's names column, as laid out inside its scrolling, in
    /// window coordinates.
    var headerColumns: [LayerKind: CGRect] = [:]
}
