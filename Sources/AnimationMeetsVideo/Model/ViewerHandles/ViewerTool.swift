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
    /// Transform handles for a clip with pictures that isn't an
    /// adjustment clip; later, the selected effect's own and a tool's.
    static func active(for clip: TimelineClip, on layer: TimelineLayer, in project: EditingProject) -> [any ViewerHandleSet] {
        guard project.hasEffectStack(clip), clip.source != .adjustment, !layer.isAdjustment else { return [] }
        return [TransformHandles()]
    }
}
