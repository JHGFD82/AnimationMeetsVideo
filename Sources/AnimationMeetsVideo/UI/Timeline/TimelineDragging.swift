import CoreMedia
import SwiftUI

// Dragging layers to reorder them, and clips across layers.
extension TimelineView {
    /// Where a layer dragged by `dy` would go among the layers of its
    /// area: the number of others whose middle is above its middle.
    func dropPosition(forLayer id: UUID, dy: CGFloat) -> Int? {
        guard let kind = timeline.layer(id: id)?.kind else { return nil }
        let layers = areaLayers(kind)
        let tops = tops(of: layers)
        guard let from = layers.firstIndex(where: { $0.id == id }) else { return nil }
        let middle = tops[from] + blockHeight(of: layers[from]) / 2 + dy
        return layers.indices.filter { index in
            index != from && tops[index] + blockHeight(of: layers[index]) / 2 < middle
        }.count
    }

    /// A line where a layer dragged in this area will land.
    @ViewBuilder
    func layerDropIndicator(_ kind: LayerKind) -> some View {
        if let drag = layerDrag, timeline.layer(id: drag.id)?.kind == kind,
           let position = dropPosition(forLayer: drag.id, dy: drag.dy) {
            let layers = areaLayers(kind)
            let tops = tops(of: layers)
            let others = layers.indices.filter { layers[$0].id != drag.id }
            let y = position < others.count
                ? tops[others[position]]
                : tops.last.map { $0 + blockHeight(of: layers[layers.count - 1]) } ?? 0
            InsertionLine()
                .offset(y: y - 3.5)
        }
    }

    /// The scrolling of the area of `kind`.
    func areaScroller(_ kind: LayerKind) -> EdgeAutoScroll {
        areaScrollers[kind] ?? EdgeAutoScroll()
    }

    /// A layer's header dragged `dy` from where it started. Near the top
    /// or bottom of its area the area scrolls, and what it has scrolled
    /// counts toward the drag. Option shows the copy pointer.
    func dragLayer(_ layer: TimelineLayer, by dy: CGFloat) {
        let scroller = areaScroller(layer.kind)
        if layerDrag?.id != layer.id { scroller.begin() }
        layerDrag = (layer.id, dy + scroller.scrolled)
        CopyDragCursor.update()
        autoScroll.trackVertically(in: layer.kind) { layerDrag = (layer.id, dy + scroller.scrolled) }
    }

    /// Drops a dragged layer where the line shows, or with Option a copy
    /// of it there, the layer itself staying put.
    func endLayerDrag(_ id: UUID, dy: CGFloat) {
        let copying = CopyDragCursor.update()
        CopyDragCursor.end()
        if let kind = timeline.layer(id: id)?.kind, let position = dropPosition(forLayer: id, dy: dy) {
            if copying {
                // The place counts the layers left in, the original among
                // them, which is above the line when dragged down.
                onEditProject { $0.duplicateLayer(id, in: timelineID, toPositionInKind: position + (dy > 0 ? 1 : 0)) }
            } else if position != areaLayers(kind).firstIndex(where: { $0.id == id }) {
                onMoveLayerTo(id, position)
            }
        }
        layerDrag = nil
    }

    /// Where a clip dragged with the pointer at `pointer` (window
    /// coordinates) and asked to start at `start` lands: on the layer
    /// under the pointer when that layer can take it, otherwise on its own
    /// layer. Layers are found by where they are on screen, since each
    /// area scrolls on its own.
    func resolveMove(_ clip: TimelineClip, from layerID: UUID, pointer: CGPoint, to start: CMTime) -> ClipMovePreview? {
        let rows = geometryStore.layerRows
        guard let fromRow = rows[layerID], let fromLayer = timeline.layer(id: layerID) else { return nil }
        // Over the layer names: onto a new layer, keeping its time.
        let column = geometryStore.namesColumn
        if column.contains(pointer) {
            let hover = NewLayerHover(audio: project.isAudioOnly(clip), pointerY: pointer.y, in: column)
            return ClipMovePreview(start: clip.startOffset, layerID: nil, offsetY: 0, newLayer: hover.hovered)
        }
        let target = timeline.layers.first { layer in
            guard layer.id != layerID, let row = rows[layer.id],
                  // A row scrolled out of its area's view isn't under the pointer.
                  geometryStore.areas[layer.kind]?.contains(pointer) == true
            else {
                return false
            }
            return pointer.y >= row.minY && pointer.y < row.maxY
        }
        if let target, let landed = project.resolvedMove(ofMoving: clip.id, in: timelineID, layer: layerID, onto: target.id, to: start),
           let targetRow = rows[target.id] {
            return ClipMovePreview(
                start: landed.start, layerID: target.id, offsetY: targetRow.minY - fromRow.minY,
                pushed: pushed(on: target, by: landed, excluding: clip.id)
            )
        }
        // Over the empty part of another area that takes it, below its
        // layers: onto a new layer there, where it was dragged to. This is
        // how detached sound goes from the Sound area to Music.
        if target == nil, let kind = emptyAreaKind(at: pointer), kind != fromLayer.kind,
           project.layerKind(kind, accepts: clip) {
            return ClipMovePreview(start: CMTimeMaximum(.zero, start), layerID: nil, offsetY: 0, newLayer: kind)
        }
        return project.resolvedMove(ofMoving: clip.id, in: timelineID, layer: layerID, to: start).map {
            ClipMovePreview(start: $0.start, layerID: nil, offsetY: 0, pushed: pushed(on: fromLayer, by: $0, excluding: clip.id))
        }
    }

    /// The area whose empty space, below its layers, is under the pointer.
    func emptyAreaKind(at pointer: CGPoint) -> LayerKind? {
        guard let kind = areaLayout.shown.first(where: { geometryStore.areas[$0]?.contains(pointer) == true }) else { return nil }
        let onLayer = areaLayers(kind).contains { geometryStore.layerRows[$0.id]?.contains(pointer) == true }
        return onLayer ? nil : kind
    }

    /// Shows what a clip drag from `layerID` will do, or stops with nil.
    func showMovePreview(_ preview: ClipMovePreview?, from layerID: UUID) {
        let hover = preview?.newLayer.map(NewLayerHover.init(hovering:))
        if hover != newLayerHover { newLayerHover = hover }
        let next = preview.flatMap { preview in
            preview.pushed.isEmpty ? nil : (layerID: preview.layerID ?? layerID, clips: preview.pushed)
        }
        if next?.layerID != pushedClips?.layerID || next?.clips != pushedClips?.clips {
            pushedClips = next
        }
    }

    /// The clips on `layer` that `move` pushes right, and where to.
    func pushed(on layer: TimelineLayer, by move: ClipMove, excluding movingID: UUID) -> [UUID: PushedClip] {
        guard move.push > .zero else { return [:] }
        var pushed: [UUID: PushedClip] = [:]
        for clip in layer.clips where clip.id != movingID && clip.startOffset >= move.pushFrom {
            pushed[clip.id] = PushedClip(from: clip.startOffset, to: CMTimeAdd(clip.startOffset, move.push))
        }
        return pushed
    }
}
