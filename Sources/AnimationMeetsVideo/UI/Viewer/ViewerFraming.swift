import CoreGraphics
import Observation
import SwiftUI

/// One viewer's zoom and place (see docs/viewer-handles.md, "Zooming and
/// scrolling the viewer"): nil zoom is Fit, nil place is centered. Each
/// viewer owns its own, and they aren't saved. The arithmetic is
/// `ViewerMapping`'s; this holds what it starts from.
@MainActor
@Observable
final class ViewerFraming {
    /// Nil for Fit.
    private(set) var zoom: Double?
    /// The frame pixel at the middle of the well; nil for centered.
    private(set) var center: CGPoint?
    /// Around the frame at Fit, in points.
    let fitMargin: Double
    /// The frame size the zoom and place were set for: a viewer shown a
    /// timeline with a different one goes back to Fit.
    @ObservationIgnored private var frameSize: CGSize?
    /// The viewer as it was last laid out, for the View menu's commands,
    /// which have no layout of their own. Set as the picture is drawn, so
    /// not watched.
    @ObservationIgnored private var laidOut: ViewerMapping?

    init(fitMargin: Double = 36) {
        self.fitMargin = fitMargin
    }

    /// The mapping for a well of `wellSize` showing a frame of `frameSize`.
    func mapping(frameSize: CGSize, wellSize: CGSize, backingScale: Double) -> ViewerMapping {
        let same = self.frameSize == frameSize
        return ViewerMapping(
            frameSize: frameSize, wellSize: wellSize, backingScale: backingScale, fitMargin: fitMargin,
            zoom: same ? zoom : nil, center: same ? center : nil
        )
    }

    /// Notes the viewer's layout, for the commands to start from.
    func note(_ mapping: ViewerMapping) {
        laidOut = mapping
    }

    /// The viewer as it is now, if it has been laid out.
    var current: ViewerMapping? {
        laidOut.map { mapping(frameSize: $0.frameSize, wellSize: $0.wellSize, backingScale: $0.backingScale) }
    }

    func apply(_ mapping: ViewerMapping) {
        frameSize = mapping.frameSize
        laidOut = mapping
        if zoom != mapping.zoom { zoom = mapping.zoom }
        if center != mapping.center { center = mapping.center }
    }

    var isFit: Bool { current?.isFit ?? (zoom == nil) }
    var isCentered: Bool { current?.isCentered ?? (center == nil) }
    /// The zoom now, as the Fit chip says it: "64%".
    var zoomText: String { current?.zoomText ?? "100%" }
    var zoomPercent: Int { Int(((current?.effectiveZoom ?? 1) * 100).rounded()) }

    // MARK: Commands

    func zoomIn() {
        if let current { apply(current.zoomedIn()) }
    }

    func zoomOut() {
        if let current { apply(current.zoomedOut()) }
    }

    /// Fit, centered (⌘0).
    func fit() {
        if let current { apply(current.fitted()) } else {
            zoom = nil
            center = nil
        }
    }

    /// Centered, keeping the zoom (⇧⌘0).
    func centerFrame() {
        if let current { apply(current.centered()) } else { center = nil }
    }

    /// Moves the picture half a well that way: VoiceOver's scroll actions.
    func scrollHalfAWell(_ edge: Edge) {
        guard let current else { return }
        let across = current.wellSize.width / 2, down = current.wellSize.height / 2
        let delta: CGVector = switch edge {
        case .leading: CGVector(dx: across, dy: 0)
        case .trailing: CGVector(dx: -across, dy: 0)
        case .top: CGVector(dx: 0, dy: down)
        case .bottom: CGVector(dx: 0, dy: -down)
        }
        apply(current.scrolled(by: delta))
    }
}

/// The viewer in the window that has the keys, for the View menu. Equal to
/// another for the same viewer, so the menu bar isn't rebuilt each redraw.
struct ViewerActions: Equatable {
    let framing: ViewerFraming

    nonisolated static func == (lhs: ViewerActions, rhs: ViewerActions) -> Bool {
        lhs.framing === rhs.framing
    }
}

private struct ViewerActionsKey: FocusedValueKey {
    typealias Value = ViewerActions
}

extension FocusedValues {
    var viewerActions: ViewerActions? {
        get { self[ViewerActionsKey.self] }
        set { self[ViewerActionsKey.self] = newValue }
    }
}
