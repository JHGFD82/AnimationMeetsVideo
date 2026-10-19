import Foundation

extension EditingProject {
    /// The project without what dragging a value changes: every effect
    /// control's values, each clip's anchor point, volume and pan, and each
    /// layer's volume and pan. Effects themselves stay, with their inputs,
    /// since a Matte's input decides what a timeline can be nested in.
    /// Views that draw only from what is left (the browser, and the
    /// timeline's other layers) compare it to skip redrawing while a value
    /// is dragged.
    var structure: EditingProject {
        structure(withoutClipsIn: nil)
    }

    /// `structure` with the clips of one timeline's layers taken out too:
    /// what a layer's row can read beyond its own layer (the media, other
    /// timelines, the layers' order, kinds and names) without where the
    /// other layers' clips are. The timeline's rows compare it, so moving a
    /// clip redraws its own layer's row and not every row.
    func structure(withoutClipsIn timelineID: UUID?) -> EditingProject {
        var copy = self
        for t in copy.timelines.indices {
            let dropsClips = copy.timelines[t].id == timelineID
            for l in copy.timelines[t].layers.indices {
                copy.timelines[t].layers[l].volume = AnimatedValue(0)
                copy.timelines[t].layers[l].pan = AnimatedValue(0)
                copy.timelines[t].layers[l].audioEffects = copy.timelines[t].layers[l].audioEffects.map(Effect.bare)
                if dropsClips {
                    copy.timelines[t].layers[l].clips = []
                    continue
                }
                for c in copy.timelines[t].layers[l].clips.indices {
                    copy.timelines[t].layers[l].clips[c].dropValues()
                }
            }
        }
        return copy
    }
}

private extension Effect {
    /// The effect without its controls' values.
    static func bare(_ effect: Effect) -> Effect {
        var effect = effect
        effect.controls = []
        effect.pasteChanges = []
        return effect
    }
}

private extension TimelineClip {
    mutating func dropValues() {
        effects = effects.map(Effect.bare)
        audioEffects = audioEffects.map(Effect.bare)
        anchorPoint = AnimatedValue(.zero)
        volume = AnimatedValue(0)
        pan = AnimatedValue(0)
    }
}
