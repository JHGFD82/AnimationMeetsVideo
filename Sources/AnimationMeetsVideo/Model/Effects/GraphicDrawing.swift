import Foundation

extension TimelineClip {
    /// The effects that are this clip's drawing: on a shape or text clip
    /// (`ClipSource.graphic`), the shapes and text in its stack, in stack
    /// order. The effects panel shows them as the clip's own content,
    /// pinned at the top, rather than as effects that can be moved, turned
    /// off or deleted (see docs/graphic-layers.md). Empty for any other
    /// clip. This is the one place that says where a clip's drawing is
    /// kept; if it moves out of the stack, only this changes.
    var drawingEffects: [Effect] {
        guard source == .graphic else { return [] }
        return effects.filter { $0.kind.drawsShape }
    }

    /// Whether `effectID` is one of the clip's `drawingEffects`.
    func isDrawing(_ effectID: UUID) -> Bool {
        drawingEffects.contains { $0.id == effectID }
    }

    /// The clip's picture effects other than its drawing: its stack, as
    /// the effects panel lists it.
    var stackEffects: [Effect] {
        let drawing = Set(drawingEffects.map(\.id))
        return effects.filter { !drawing.contains($0.id) }
    }
}
