import CoreMedia
import SwiftUI

/// What an adjustment clip's menu offers to set its reach.
struct ReachMenu {
    /// The layer it reaches down to; nil for every layer below.
    var current: UUID?
    /// The layers below its layer, which it can reach down to.
    var options: [(id: UUID, name: String)]
    /// What it reaches, in words.
    var summary: String
    let onChoose: (UUID?) -> Void
}

// The context menus of a clip block and of the transitions on it.
extension ClipBlockView {
    @ViewBuilder
    var clipMenu: some View {
        if let reach {
            reachMenu(reach)
            Divider()
        }
        if let transition = clip.transitionIn {
            Button("Remove \(transition.kind.name) at Start") { onRemoveTransition(.leading) }
        }
        if let transition = clip.transitionOut {
            Button("Remove \(transition.kind.name) at End") { onRemoveTransition(.trailing) }
        }
        if hasLinkedAudio {
            if clip.transitionIn != nil || clip.transitionOut != nil { Divider() }
            Button("Detach Audio", action: onDetachAudio)
        }
        if let onBeatMatch {
            Button("Beat Match…", action: onBeatMatch)
        }
        if case .timeline = clip.source {
            Toggle("Pass Through", isOn: Binding(get: { passesThrough }, set: { onSetPassThrough($0) }))
        }
        if acceptsEffects || acceptsSoundEffects {
            Divider()
            Button("Copy Effects", action: onCopyEffects)
                .disabled(clip.effects.isEmpty && clip.audioEffects.isEmpty)
            Button("Paste Effects", action: onPasteEffects)
                .disabled(EffectClipboard.shared.isEmpty)
        }
        if case .media = clip.source {
            Divider()
            timeMenu
            if acceptsEffects { shutterMenu }
        }
    }

    /// How far down an adjustment clip reaches: every layer below, or down
    /// to one of them.
    func reachMenu(_ reach: ReachMenu) -> some View {
        Menu("Reach: \(reach.summary)") {
            Button {
                reach.onChoose(nil)
            } label: {
                if reach.current == nil { Image(systemName: "checkmark") }
                Text("All Layers Below")
            }
            ForEach(reach.options, id: \.id) { option in
                Button {
                    reach.onChoose(option.id)
                } label: {
                    if reach.current == option.id { Image(systemName: "checkmark") }
                    Text("Down to \(option.name)")
                }
            }
        }
    }

    /// Speed, frame blending, echo and the sound choice, set on the clip
    /// (and shown in the effects panel).
    @ViewBuilder
    var timeMenu: some View {
        Menu("Speed") {
            ForEach([25.0, 50, 100, 200, 400], id: \.self) { percent in
                Button {
                    onEditTime { $0.speed = AnimatedValue(percent) }
                } label: {
                    if !clip.time.speed.isAnimated, clip.time.speed.value == percent { Image(systemName: "checkmark") }
                    Text(percent == 100 ? "Normal (100%)" : "\(Int(percent))%")
                }
            }
            if clip.time.speed.isAnimated {
                Divider()
                Button("Remove Speed Ramp") { onEditTime { $0.speed = AnimatedValue(100) } }
            }
        }
        if acceptsEffects {
            Menu("Frame Blending") {
                ForEach(FrameBlending.allCases) { mode in
                    Button {
                        onEditTime { $0.frameBlending = mode }
                    } label: {
                        if clip.time.frameBlending == mode { Image(systemName: "checkmark") }
                        Text(mode.name)
                    }
                }
            }
            Toggle("Echo", isOn: Binding(
                get: { clip.time.echo != nil },
                set: { on in onEditTime { $0.echo = on ? Echo(count: 4, delay: CMTime(value: 1, timescale: 12), decay: 0.6) : nil } }
            ))
        }
        if playsSound {
            Menu("Sound at Other Speeds") {
                ForEach(SoundMode.allCases) { mode in
                    Button {
                        onEditTime { $0.sound = mode }
                    } label: {
                        if clip.time.sound == mode { Image(systemName: "checkmark") }
                        Text(mode.name)
                    }
                }
            }
        }
    }

    /// Motion blur and trails.
    @ViewBuilder
    var shutterMenu: some View {
        Menu("Shutter") {
            Toggle("Motion Blur", isOn: Binding(
                get: { clip.shutter.motionBlur != nil },
                set: { on in onEditClip { $0.shutter.motionBlur = on ? MotionBlur() : nil } }
            ))
            Toggle("Trails", isOn: Binding(
                get: { clip.shutter.trails != nil },
                set: { on in onEditClip { $0.shutter.trails = on ? Trails(count: 4, delay: CMTime(value: 1, timescale: 12), decay: 0.6) : nil } }
            ))
        }
    }

    @ViewBuilder
    func transitionMenu(_ transition: ClipTransition, edge: TransitionEdge) -> some View {
        let current = transition.curve.preset
        ForEach(TransitionCurve.Preset.allCases) { preset in
            Button {
                onSetTransitionCurve(edge, TransitionCurve(preset: preset))
            } label: {
                if current == preset {
                    Label(preset.name, systemImage: "checkmark")
                } else {
                    Text(preset.name)
                }
            }
            .help(preset.detail)
        }
        Divider()
        Button("Remove \(transition.kind.name)") { onRemoveTransition(edge) }
    }
}
