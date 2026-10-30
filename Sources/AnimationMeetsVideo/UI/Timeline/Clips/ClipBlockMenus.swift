import CoreMedia
import SwiftUI

/// What an adjustment clip's menu offers to set its reach, which it sets
/// through `ClipBlockHandlers.onSetReach`.
struct ReachMenu: Equatable {
    struct Option: Equatable, Identifiable {
        var id: UUID
        var name: String
    }

    /// The layer it reaches down to; nil for every layer below.
    var current: UUID?
    /// The layers below its layer, which it can reach down to.
    var options: [Option]
    /// What it reaches, in words.
    var summary: String
}

/// A clip block's context menu, built again only when what it offers
/// changes (`ClipBlockView.menuKey`): nothing in it depends on zoom, and
/// the block is built again on every step of one. Its items act through
/// the block's closures, which don't read what changed.
struct ClipMenuHost: View, Equatable {
    let block: ClipBlockView
    let key: Key

    struct Key: Equatable {
        var clip: TimelineClip
        var hasLinkedAudio: Bool
        var hasBeatMatch: Bool
        var hasBeats: Bool
        var canFollowMusic: Bool
        var canMotionDesign: Bool
        var canConformTimeline: Bool
        var passesThrough: Bool
        var acceptsEffects: Bool
        var acceptsSoundEffects: Bool
        var playsSound: Bool
        var reach: ReachMenu?
        /// What the menu's Paste items are enabled by.
        var canPasteClip: Bool
        /// Whether the clip is one of several selected together.
        var inGroup: Bool
        var groupSpansLayers: Bool
        var canPasteEffects: Bool
    }

    var body: some View { block.clipMenu }

    nonisolated static func == (lhs: ClipMenuHost, rhs: ClipMenuHost) -> Bool {
        MainActor.assumeIsolated { lhs.key == rhs.key }
    }
}

// The context menus of a clip block and of the transitions on it.
extension ClipBlockView {
    var menuKey: ClipMenuHost.Key {
        ClipMenuHost.Key(
            clip: model.clip, hasLinkedAudio: model.hasLinkedAudio, hasBeatMatch: handlers.onBeatMatch != nil, hasBeats: handlers.onRemoveBeats != nil, canFollowMusic: handlers.onAttachToMusic != nil,
            canMotionDesign: handlers.onMotionDesign != nil, canConformTimeline: handlers.onConformTimeline != nil, passesThrough: model.passesThrough,
            acceptsEffects: model.acceptsEffects, acceptsSoundEffects: model.acceptsSoundEffects, playsSound: model.playsSound,
            reach: model.reach,
            canPasteClip: EditorClipboard.shared.hasClips, inGroup: model.isInGroup, groupSpansLayers: model.groupSpansLayers,
            canPasteEffects: EditorClipboard.shared.canPasteEffects
        )
    }

    /// Items for a clip picked with others act on them all (the timeline
    /// hands them out to each, see `TimelineAreas`); items that only make
    /// sense for one clip are greyed out. Toggles set every clip to the
    /// opposite of this one rather than flipping each.
    @ViewBuilder
    var clipMenu: some View {
        let group = model.isInGroup
        Button("Cut") { handlers.onClipboard(.cut) }
            .keyboardShortcut("x", modifiers: .command)
        Button("Copy") { handlers.onClipboard(.copy) }
            .keyboardShortcut("c", modifiers: .command)
        Button("Paste") { handlers.onClipboard(.paste) }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(!EditorClipboard.shared.hasClips)
        Button("Duplicate") { handlers.onClipboard(.duplicate) }
            .keyboardShortcut("d", modifiers: .command)
        Button(model.isInGroup ? "Put Selection in New Timeline" : "Put in New Timeline") { handlers.onClipboard(.nest) }
        Divider()
        Button(model.clip.enabled ? "Turn Off" : "Turn On") { handlers.onEditClip { [enabled = !model.clip.enabled] in $0.enabled = enabled } }
            .keyboardShortcut("v", modifiers: [])
        if model.playsSound {
            Button(model.clip.soundMuted ? "Unmute Sound" : "Mute Sound") { handlers.onEditClip { [muted = !model.clip.soundMuted] in $0.soundMuted = muted } }
        }
        Divider()
        if let reach = model.reach {
            reachMenu(reach)
                .disabled(group)
            Divider()
        }
        if let transition = model.clip.transitionIn {
            Button("Remove \(transition.kind.name) at Start") { handlers.onRemoveTransition(.leading) }
                .disabled(group)
        }
        if let transition = model.clip.transitionOut {
            Button("Remove \(transition.kind.name) at End") { handlers.onRemoveTransition(.trailing) }
                .disabled(group)
        }
        if model.hasLinkedAudio {
            if model.clip.transitionIn != nil || model.clip.transitionOut != nil { Divider() }
            Button("Detach Audio", action: handlers.onDetachAudio)
        }
        if let onBeatMatch = handlers.onBeatMatch {
            Button("Beat Match…", action: onBeatMatch)
                .disabled(group)
        }
        if let onRemoveBeats = handlers.onRemoveBeats {
            Button("Remove Beats", action: onRemoveBeats)
                .disabled(group)
        }
        if case .timeline = model.clip.source {
            if let onOpenNested = handlers.onOpenNested { Button("Open Timeline", action: onOpenNested).disabled(group) }
            Toggle("Pass Through", isOn: Binding(get: { model.passesThrough }, set: { handlers.onSetPassThrough($0) }))
        }
        if let onAttachToMusic = handlers.onAttachToMusic {
            Divider()
            Toggle("Follow Music", isOn: Binding(get: { model.clip.followsMusic }, set: { follows in handlers.onEditClip { $0.followsMusic = follows } }))
            Button("Attach to Music at Playhead", action: onAttachToMusic)
                .disabled(group)
        }
        if let onMotionDesign = handlers.onMotionDesign {
            Button(model.isInGroup ? "Motion Designer for Selection…" : "Motion Designer…", action: onMotionDesign)
                .disabled(group && model.groupSpansLayers)
                .help(group && model.groupSpansLayers ? "The motion designer opens on clips on one layer" : "")
        }
        if model.acceptsEffects || model.acceptsSoundEffects {
            Divider()
            Button("Paste Effects", action: handlers.onPasteEffects)
                .disabled(!EditorClipboard.shared.canPasteEffects)
        }
        if let piece = model.clip.footagePiece {
            Divider()
            Button("Show in Clips Browser") { NotificationCenter.default.post(name: .revealInBrowser, object: piece) }
                .keyboardShortcut("f", modifiers: .shift)
                .disabled(group)
            if let onConformTimeline = handlers.onConformTimeline {
                Button("Conform Timeline to Clip", action: onConformTimeline)
                    .disabled(group)
                    .help("Give the timeline this clip's frame size, frame rate and SDR or HDR colour space")
            }
            Divider()
            timeMenu
            if model.acceptsEffects { shutterMenu }
        }
    }

    /// How far down an adjustment clip reaches: every layer below, or down
    /// to one of them.
    func reachMenu(_ reach: ReachMenu) -> some View {
        Menu("Reach: \(reach.summary)") {
            Button {
                handlers.onSetReach(nil)
            } label: {
                if reach.current == nil { Image(systemName: "checkmark") }
                Text("All Layers Below")
            }
            ForEach(reach.options) { option in
                Button {
                    handlers.onSetReach(option.id)
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
                    handlers.onEditTime { $0.speed = AnimatedValue(percent) }
                } label: {
                    if !model.clip.time.speed.isAnimated, model.clip.time.speed.value == percent { Image(systemName: "checkmark") }
                    Text(percent == 100 ? "Normal (100%)" : "\(Int(percent))%")
                }
            }
            if model.clip.time.speed.isAnimated {
                Divider()
                Button("Remove Speed Ramp") { handlers.onEditTime { $0.speed = AnimatedValue(100) } }
            }
        }
        if model.acceptsEffects {
            Menu("Frame Blending") {
                ForEach(FrameBlending.allCases) { mode in
                    Button {
                        handlers.onEditTime { $0.frameBlending = mode }
                    } label: {
                        if model.clip.time.frameBlending == mode { Image(systemName: "checkmark") }
                        Text(mode.name)
                    }
                }
            }
            Toggle("Echo", isOn: Binding(
                get: { model.clip.time.echo != nil },
                set: { on in handlers.onEditTime { $0.echo = on ? Echo(count: 4, delay: CMTime(value: 1, timescale: 12), decay: 0.6) : nil } }
            ))
        }
        if model.playsSound {
            Menu("Sound at Other Speeds") {
                ForEach(SoundMode.allCases) { mode in
                    Button {
                        handlers.onEditTime { $0.sound = mode }
                    } label: {
                        if model.clip.time.sound == mode { Image(systemName: "checkmark") }
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
                get: { model.clip.shutter.motionBlur != nil },
                set: { on in handlers.onEditClip { $0.shutter.motionBlur = on ? MotionBlur() : nil } }
            ))
            Toggle("Trails", isOn: Binding(
                get: { model.clip.shutter.trails != nil },
                set: { on in handlers.onEditClip { $0.shutter.trails = on ? Trails(count: 4, delay: CMTime(value: 1, timescale: 12), decay: 0.6) : nil } }
            ))
        }
    }

    @ViewBuilder
    func transitionMenu(_ transition: ClipTransition, edge: TransitionEdge) -> some View {
        let current = transition.curve.preset
        ForEach(TransitionCurve.Preset.allCases) { preset in
            Button {
                handlers.onSetTransitionCurve(edge, TransitionCurve(preset: preset))
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
        Button("Remove \(transition.kind.name)") { handlers.onRemoveTransition(edge) }
    }
}
