import CoreMedia
import SwiftUI

// Coloring the timeline's bars from their menus' Other…, and Clear Layer.
// See docs/bar-colors.md.
extension TimelineView {
    /// The color picker on the clips `ids`, showing `clipID`'s color (or
    /// its tone, without one). Every change recolors them all, by ID, as
    /// the project is when it arrives.
    func pickColor(ofClips ids: Set<UUID>, like clipID: UUID) {
        guard let found = project.clipAndLayer(clipID, in: timelineID) else { return }
        let tone = Design.tone(of: found.clip, info: project.resolvedInfo(for: found.clip), on: found.layer.kind)
        let timelineID = timelineID
        let host = host
        BarColorPanel.shared.show(current: found.clip.color ?? BarColor(tone) ?? BarColor(0x7D7D7D)) { color in
            host.dispatch(.editProject { $0.setColor(color, ofClips: ids, in: timelineID) })
        }
    }

    /// The color picker on every clip a layer has now.
    func pickColor(ofLayer layerID: UUID) {
        guard let layer = timeline.layer(id: layerID), let first = layer.clips.first else { return }
        pickColor(ofClips: Set(layer.clips.map(\.id)), like: first.id)
    }

    /// The color picker on a section.
    func pickColor(ofSection id: UUID) {
        guard let section = timeline.sections.first(where: { $0.id == id }) else { return }
        let timelineID = timelineID
        let host = host
        BarColorPanel.shared.show(current: section.color ?? BarColor(Design.section) ?? BarColor(0xB08A52)) { color in
            host.dispatch(.editProject { $0.setColor(color, ofSection: id, in: timelineID) })
        }
    }

    /// Clear Layer: the layer's clips deleted as by hand, as one edit, and
    /// no longer selected; the layer stays, and so does its selection.
    func clearLayer(_ layerID: UUID) {
        guard let layer = timeline.layer(id: layerID), !layer.clips.isEmpty else { return }
        let cleared = Set(layer.clips.map(\.id))
        host.dispatch(.editProject { $0.clearLayer(layerID, in: timelineID) })
        groupSelection.subtract(cleared)
        if let selection, selection.timelineID == timelineID, cleared.contains(selection.timelineClipID) {
            host.dispatch(.selectLayer)
        }
    }
}
