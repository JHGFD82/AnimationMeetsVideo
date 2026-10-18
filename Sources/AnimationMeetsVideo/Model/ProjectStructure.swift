import Foundation

extension EditingProject {
    /// The project without what dragging a value changes: every effect
    /// control's values, and each clip's anchor point, volume and pan.
    /// Effects themselves stay, with their inputs, since a Matte's input
    /// decides what a timeline can be nested in. Views that draw only from
    /// what is left (the browser, and the timeline's other layers) compare
    /// it to skip redrawing while a value is dragged.
    var structure: EditingProject {
        var copy = self
        for t in copy.timelines.indices {
            for l in copy.timelines[t].layers.indices {
                for c in copy.timelines[t].layers[l].clips.indices {
                    copy.timelines[t].layers[l].clips[c].dropValues()
                }
            }
        }
        return copy
    }
}

private extension TimelineClip {
    mutating func dropValues() {
        func bare(_ effect: Effect) -> Effect {
            var effect = effect
            effect.controls = []
            effect.pasteChanges = []
            return effect
        }
        effects = effects.map(bare)
        audioEffects = audioEffects.map(bare)
        anchorPoint = AnimatedValue(.zero)
        volume = AnimatedValue(0)
        pan = AnimatedValue(0)
    }
}
