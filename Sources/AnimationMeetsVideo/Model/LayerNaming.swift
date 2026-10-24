import Foundation

extension EditingProject {
    /// A layer's name as shown in the timeline: its own name, else its kind
    /// and number, such as "Video 2" or "Music 1", counting layers of its
    /// kind from the top. Footage names made poor defaults: a layer
    /// outlives its first clip, and several layers cut from one file all
    /// read the same.
    func displayName(of layer: TimelineLayer, in timeline: Timeline) -> String {
        if let customName = layer.customName, !customName.isEmpty { return customName }
        if layer.isAdjustment {
            let adjustments = timeline.layers.filter(\.isAdjustment)
            return "Adjustment \((adjustments.firstIndex(id: layer.id) ?? 0) + 1)"
        }
        let sameKind = timeline.layers.filter { $0.kind == layer.kind && !$0.isAdjustment }
        let number = (sameKind.firstIndex(id: layer.id) ?? 0) + 1
        return "\(layer.kind.name) \(number)"
    }
}
