import Foundation

/// What a press in the viewer that hits no handle does, as `TimelineTool`
/// says for the tracks; the viewer's rail picks one (`ViewerToolPicker`).
enum ViewerTool: String, CaseIterable, Identifiable, Sendable {
    /// Drags handles. A press on nothing does nothing: the viewer never
    /// selects.
    case arrow
    /// Draws paths: a press adds a point (see docs/pen-tool.md).
    case pen
    // Later: rectangle, ellipse, text, each with its own key.

    var id: Self { self }

    var name: String {
        switch self {
        case .arrow: "Arrow"
        case .pen: "Pen"
        }
    }

    var systemImage: String {
        switch self {
        case .arrow: "cursorarrow"
        case .pen: "pencil.tip"
        }
    }

    var help: String {
        switch self {
        case .arrow: "Arrow: drag the handles of the clip selected in the timeline"
        case .pen: "Pen (P): click to add points, drag to curve them"
        }
    }
}

/// Which handle sets the viewer shows for a clip, decided in one place.
enum ViewerHandleSets {
    /// The effect selected in the effects panel's own handles when it has
    /// any (a path's points, a shape's or a text block's, its point
    /// controls, and those its package declares), on any clip, an
    /// adjustment clip's included; otherwise Transform handles, for a clip
    /// with pictures that isn't an adjustment clip. The pen draws its own
    /// path's handles (`PenOverlay`).
    static func active(
        for clip: TimelineClip, on layer: TimelineLayer, in project: EditingProject, selectedEffectID: UUID?
    ) -> [any ViewerHandleSet] {
        if let selectedEffectID, let effect = clip.effects.first(id: selectedEffectID) {
            var own: [any ViewerHandleSet] = []
            if PathHandles.applies(to: effect) {
                // A path's Position stays in the panel: its points are what
                // the viewer shows.
                own.append(PathHandles(effectID: effect.id))
            } else if ShapeHandles.applies(to: effect) {
                own.append(ShapeHandles(effectID: effect.id))
            }
            if PointControlHandles.applies(to: effect) { own.append(PointControlHandles(effectID: effect.id)) }
            // Drawn over the points, so asked first for a press.
            if DeclaredHandles.applies(to: effect) { own.append(DeclaredHandles(effectID: effect.id)) }
            if !own.isEmpty { return own }
        }
        guard project.hasEffectStack(clip), clip.source != .adjustment, !layer.isAdjustment else { return [] }
        return [TransformHandles()]
    }
}
