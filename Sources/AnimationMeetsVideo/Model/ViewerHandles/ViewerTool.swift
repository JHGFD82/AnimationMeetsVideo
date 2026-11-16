import Foundation

/// What a press in the viewer that hits no handle does, as `TimelineTool`
/// says for the tracks. With one tool there is no picker; the second
/// brings one into the viewer's rail.
enum ViewerTool: String, CaseIterable, Identifiable, Sendable {
    /// Drags handles. A press on nothing does nothing: the viewer never
    /// selects.
    case arrow
    // Later: pen (a press adds a vertex), rectangle, ellipse, text, hand
    // (a drag scrolls the view), each with its own key.

    var id: Self { self }
}

/// Which handle sets the viewer shows for a clip, decided in one place.
enum ViewerHandleSets {
    /// The effect selected in the effects panel's own handles when it has
    /// any (a shape's or a text block's, its point controls, and those its
    /// package declares), on any clip, an adjustment clip's
    /// included; otherwise Transform handles, for a clip with pictures
    /// that isn't an adjustment clip. Later, a tool's own set.
    static func active(
        for clip: TimelineClip, on layer: TimelineLayer, in project: EditingProject, selectedEffectID: UUID?
    ) -> [any ViewerHandleSet] {
        if let selectedEffectID, let effect = clip.effects.first(id: selectedEffectID) {
            var own: [any ViewerHandleSet] = []
            if ShapeHandles.applies(to: effect) { own.append(ShapeHandles(effectID: effect.id)) }
            if PointControlHandles.applies(to: effect) { own.append(PointControlHandles(effectID: effect.id)) }
            // Drawn over the points, so asked first for a press.
            if DeclaredHandles.applies(to: effect) { own.append(DeclaredHandles(effectID: effect.id)) }
            if !own.isEmpty { return own }
        }
        guard project.hasEffectStack(clip), clip.source != .adjustment, !layer.isAdjustment else { return [] }
        return [TransformHandles()]
    }
}
