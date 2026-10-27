import CoreMedia
import SwiftUI

struct InspectorPanel: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    var selection: TimelineSelection?
    let info: ResolvedClipInfo?
    let timelineClip: TimelineClip?
    /// Where the playhead is parked. Not read as this body is built, so a
    /// step of it redraws only the rows that show a value at the playhead.
    let playhead: PlayheadState
    let onSeek: (CMTime) -> Void
    let onDeleteSelection: () -> Void
    /// The assets' scene scores, so a trim typed in stops at a cut as a
    /// dragged one does.
    let sceneTracks: () -> [UUID: ChangeScoreTrack]
    /// The surface's graph editor panels.
    @Environment(KeyframeGraphHUDs.self) private var graphs: KeyframeGraphHUDs?
    @Environment(BeatMatchController.self) private var beatMatch: BeatMatchController?
    /// Read for the sound rows during a drag held to one side of the project.
    @Environment(ProjectState.self) private var projectState: ProjectState?

    init(
        project: Binding<EditingProject>, timelineID: UUID, selection: TimelineSelection? = nil, info: ResolvedClipInfo?,
        timelineClip: TimelineClip?, playhead: PlayheadState, onSeek: @escaping (CMTime) -> Void,
        onDeleteSelection: @escaping () -> Void, sceneTracks: @escaping () -> [UUID: ChangeScoreTrack] = { [:] }
    ) {
        _project = project
        self.timelineID = timelineID
        self.selection = selection
        self.info = info
        self.timelineClip = timelineClip
        self.playhead = playhead
        self.onSeek = onSeek
        self.onDeleteSelection = onDeleteSelection
        self.sceneTracks = sceneTracks
    }

    /// An inspector with the playhead parked at `playheadTime`.
    init(
        project: Binding<EditingProject>, timelineID: UUID, selection: TimelineSelection? = nil, info: ResolvedClipInfo?,
        timelineClip: TimelineClip?, playheadTime: CMTime, onSeek: @escaping (CMTime) -> Void,
        onDeleteSelection: @escaping () -> Void
    ) {
        self.init(
            project: project, timelineID: timelineID, selection: selection, info: info, timelineClip: timelineClip,
            playhead: PlayheadState(time: playheadTime), onSeek: onSeek, onDeleteSelection: onDeleteSelection
        )
    }

    /// The song of a selected clip on a Music layer, which can be beat matched.
    private var beatMatchAsset: MediaClip? {
        guard let selection, case .media(let clip) = info, clip.url != nil, clip.hasAudio,
              project.timeline(id: selection.timelineID)?.layer(id: selection.layerID)?.kind == .music
        else { return nil }
        return clip
    }

    private var maxDurationSeconds: Double? {
        switch info {
        case .media(let clip) where clip.kind == .image: EditingProject.unboundedLength.seconds
        case .media(let clip): clip.duration.seconds
        case .timeline(let timeline): timeline.duration.seconds
        case .adjustment, .graphic: EditingProject.unboundedLength.seconds
        case nil: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(Design.Typeface.panelTitle)
                    .foregroundStyle(Design.textPrimary)
                Spacer()
                if let info {
                    Text(info.name)
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, Design.Space.group)
            .padding(.vertical, Design.Space.step)
            .rail(.raised)

            if info == nil {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "square.dashed",
                    description: Text("Select a clip on the timeline to see and change what it does.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView { groups.padding(Design.Space.group) }
            }
        }
        .panelSurface(.base)
    }

    @ViewBuilder
    private var groups: some View {
        VStack(alignment: .leading, spacing: Design.Space.group) {
            InspectorGroup("Source") {
                switch info {
                case .media(let clip):
                    InspectorRow("Duration", value: clip.duration.formatted, numeric: true)
                    if clip.frameRate > 0 {
                        InspectorRow("Frame rate", value: String(format: "%.2f fps", clip.frameRate), numeric: true)
                    }
                    InspectorRow("Codec", value: clip.codecName)
                    InspectorRow("Colour", value: clip.colorSpace.rawValue)
                case .timeline(let timeline):
                    InspectorRow("Duration", value: timeline.duration.formatted, numeric: true)
                    InspectorRow("Frame size", value: "\(Int(timeline.frameSize.width))×\(Int(timeline.frameSize.height))", numeric: true)
                    InspectorRow("Frame rate", value: String(format: "%.2f fps", timeline.frameRate), numeric: true)
                    InspectorRow("Colour", value: timeline.colorSpace.rawValue)
                case .adjustment:
                    InspectorRow("Kind", value: "Adjustment")
                    reachPicker
                case .graphic(let title):
                    InspectorRow("Kind", value: title == nil ? "Shapes" : "Text")
                case nil:
                    EmptyView()
                }
            }

            if let asset = beatMatchAsset, let beatMatch {
                InspectorGroup("Beats") {
                    Text(asset.beatMap.hasConfirmedBeats
                         ? "Beat matched: the timeline shows the beats you confirmed."
                         : "Not beat matched: the timeline shows detected beats, which may be wrong.")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Beat Match…") { beatMatch.open(assetID: asset.id, in: project) }
                }
            }

            shapeGroups

            if let selection, let timelineClip, let maxDurationSeconds {
                InspectorGroup("Trim") {
                    Stepper(
                        value: Binding(
                            get: { timelineClip.trimStart.seconds },
                            set: { setTrimStart($0, selection: selection) }
                        ),
                        in: 0...max(0, timelineClip.trimEnd.seconds - 0.1),
                        step: 0.5
                    ) {
                        trimLabel("In", time: timelineClip.trimStart)
                    }
                    Stepper(
                        value: Binding(
                            get: { timelineClip.trimEnd.seconds },
                            set: { setTrimEnd($0, selection: selection) }
                        ),
                        // Clamp below maxDurationSeconds: a very short (or
                        // zero-duration, e.g. an embedded empty timeline)
                        // clip would otherwise make trimStart + 0.1 exceed
                        // maxDurationSeconds, producing an invalid range and
                        // crashing ("lowerBound <= upperBound").
                        in: min(maxDurationSeconds, timelineClip.trimStart.seconds + 0.1)...maxDurationSeconds,
                        step: 0.5
                    ) {
                        trimLabel("Out", time: timelineClip.trimEnd)
                    }
                }

                if let timeline = project.timeline(id: timelineID) {
                    if project.playsAudio(timelineClip) {
                        let sourceNow = PlayheadTime(playhead) {
                            timeline.snappedToFrame(timelineClip.sourceTime(atTimelineTime: $0))
                        }
                        InspectorGroup("Sound") {
                            ForEach([AudioProperty.volume, .pan], id: \.self) { property in
                                let keyPath: WritableKeyPath<TimelineClip, AnimatedValue<Double>> = property == .volume ? \.volume : \.pan
                                AudioPropertyRow(
                                    property: property,
                                    value: timelineClip[keyPath: keyPath],
                                    playhead: sourceNow,
                                    onEdit: { change in
                                        project.editClip(timelineClip.id, in: timelineID) { change(&$0[keyPath: keyPath]) }
                                    },
                                    onSeek: { onSeek(timelineClip.timelineTime(forSourceTime: $0)) },
                                    held: { projectState?.held?.clipAndLayer(timelineClip.id, in: timelineID)?.clip[keyPath: keyPath] },
                                    // A clip's sound is keyframed in the effects panel.
                                    keyframing: false
                                )
                            }
                        }
                    }
                    if let layer = timeline.layer(id: selection.layerID), layer.kind.isAudio {
                        let frameTime = PlayheadTime(playhead) { timeline.snappedToFrame($0) }
                        // Keeps its keyframe buttons: the effects panel shows
                        // a clip, not its layer, so a layer's pan and sound
                        // effects are keyframed nowhere else.
                        InspectorGroup("Layer sound") {
                            AudioPropertyRow(
                                value: layer.volume,
                                playhead: frameTime,
                                onEdit: { change in project.editVolume(of: layer.id, in: timelineID, change) },
                                onSeek: onSeek,
                                onShowGraph: graphs.map { graphs in
                                    { graphs.show(ParameterKey(timelineID: timelineID, parameter: .layerVolume(layerID: layer.id))) }
                                },
                                held: { projectState?.held?.timeline(id: timelineID)?.layer(id: layer.id)?.volume }
                            )
                            AudioPropertyRow(
                                property: .pan,
                                value: layer.pan,
                                playhead: frameTime,
                                onEdit: { change in project.editPan(of: layer.id, in: timelineID, change) },
                                onSeek: onSeek,
                                onShowGraph: graphs.map { graphs in
                                    { graphs.show(ParameterKey(timelineID: timelineID, parameter: .layerPan(layerID: layer.id))) }
                                },
                                held: { projectState?.held?.timeline(id: timelineID)?.layer(id: layer.id)?.pan }
                            )
                            LayerSoundEffectsList(project: $project, timelineID: timelineID, layer: layer, playhead: frameTime)
                        }
                    }
                }

                if timelineClip.transitionIn != nil || timelineClip.transitionOut != nil {
                    InspectorGroup("Transitions") {
                        transitionRow(.leading, of: timelineClip, selection: selection)
                        transitionRow(.trailing, of: timelineClip, selection: selection)
                    }
                }

                InspectorGroup("Arrange") {
                    if project.canDetachAudio(timelineClip) {
                        Button("Detach audio") {
                            project.detachAudio(of: [timelineClip.id], in: timelineID, layer: selection.layerID)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    Button("Delete clip", role: .destructive) {
                        project.deleteClip(selection.timelineClipID, in: timelineID, layer: selection.layerID)
                        onDeleteSelection()
                    }
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
    }

    private func trimLabel(_ name: String, time: CMTime) -> some View {
        HStack(spacing: Design.Space.close) {
            Text(name)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
            Text(time.formatted)
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(Design.textPrimary)
        }
    }

    /// A transition's kind and length, a frame per step, with a way to
    /// remove it.
    @ViewBuilder
    private func transitionRow(_ edge: TransitionEdge, of clip: TimelineClip, selection: TimelineSelection) -> some View {
        if let transition = clip.transition(at: edge), let timeline = project.timeline(id: timelineID) {
            let frames = Int((transition.duration.seconds / timeline.frameDuration.seconds).rounded())
            VStack(alignment: .leading, spacing: Design.Space.close) {
                HStack(spacing: Design.Space.close) {
                    Image(systemName: transition.kind.systemImage)
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textSecondary)
                    Text("\(edge == .leading ? "Start" : "End") · \(transition.kind.name)")
                        .font(Design.Typeface.bodyEmphasis)
                        .foregroundStyle(Design.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        project.removeTransition(at: edge, of: clip.id, in: timelineID, layer: selection.layerID)
                    } label: {
                        Image(systemName: Design.Symbol.remove)
                    }
                    .buttonStyle(.icon)
                    .help("Remove transition")
                    .accessibilityLabel("Remove \(transition.kind.name) at the \(edge == .leading ? "start" : "end")")
                }
                Stepper(
                    value: Binding(
                        get: { frames },
                        set: { newFrames in
                            project.setTransitionDuration(
                                CMTimeMultiply(timeline.frameDuration, multiplier: Int32(max(1, newFrames))),
                                at: edge, of: clip.id, in: timelineID, layer: selection.layerID
                            )
                        }
                    ),
                    in: 1...Int.max
                ) {
                    Text("\(frames) frames")
                        .font(Design.Typeface.numericSmall)
                        .foregroundStyle(Design.textSecondary)
                }
                TransitionSettingsControls(transition: transition, videos: project.clips.filter { $0.kind == .video }) { options in
                    project.setTransitionOptions(options, at: edge, of: clip.id, in: timelineID, layer: selection.layerID)
                }
                Menu("Curve: \(transition.curve.preset?.name ?? "Custom")") {
                    ForEach(TransitionCurve.Preset.allCases) { preset in
                        Button("\(preset.name) — \(preset.detail)") {
                            project.setTransitionCurve(
                                TransitionCurve(preset: preset),
                                at: edge, of: clip.id, in: timelineID, layer: selection.layerID
                            )
                        }
                    }
                }
                .help("Select the transition on the timeline and zoom in to edit its curve's points")
            }
        }
    }

    private func setTrimStart(_ seconds: Double, selection: TimelineSelection) {
        project.trimClipStart(
            selection.timelineClipID,
            in: timelineID,
            layer: selection.layerID,
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            sceneTracks: sceneTracks()
        )
    }

    private func setTrimEnd(_ seconds: Double, selection: TimelineSelection) {
        project.trimClipEnd(
            selection.timelineClipID,
            in: timelineID,
            layer: selection.layerID,
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            sceneTracks: sceneTracks()
        )
    }
}

// The shapes and text of a selected clip.
extension InspectorPanel {
    /// For each shape in the clip's stack, in order: a Text effect's words
    /// and type (`TextInspectorGroup`), another shape's own settings
    /// (`ShapeInspectorGroup`), and the fill and stroke of either
    /// (`PaintInspectorGroup`). A Stroke effect has one group, of its
    /// stroke. With more than one shape, each group is titled with its
    /// effect's name.
    @ViewBuilder
    var shapeGroups: some View {
        if let timelineClip, let timeline = project.timeline(id: timelineID) {
            let shapes = timelineClip.effects.filter { $0.kind.isShape && $0.missing == nil }
            let sourceNow = PlayheadTime(playhead) { timeline.snappedToFrame(timelineClip.sourceTime(atTimelineTime: $0)) }
            let named = shapes.count > 1
            ForEach(shapes) { effect in
                let onEdit: ((inout Effect) -> Void) -> Void = { change in
                    project.editEffect(effect.id, ofClip: timelineClip.id, in: timelineID, change)
                }
                let onSeek: (CMTime) -> Void = { onSeek(timelineClip.timelineTime(forSourceTime: $0)) }
                if effect.kind == .text {
                    TextInspectorGroup(
                        effect: effect, prefix: named ? effect.displayName : nil, playhead: sourceNow, onEdit: onEdit, onSeek: onSeek
                    )
                } else {
                    ShapeInspectorGroup(effect: effect, playhead: sourceNow, onEdit: onEdit, onSeek: onSeek)
                }
                if effect.kind.drawsShape {
                    PaintInspectorGroup(
                        effect: effect, title: named ? "\(effect.displayName) · Fill & Stroke" : "Fill & Stroke",
                        playhead: sourceNow, onEdit: onEdit, onSeek: onSeek
                    )
                }
            }
        }
    }
}

// The reach of a selected adjustment clip.
extension InspectorPanel {
    /// How far down the adjustment clip reaches: every layer below, or down
    /// to a video layer below, as in its context menu.
    @ViewBuilder
    var reachPicker: some View {
        if let selection, let timelineClip, timelineClip.source == .adjustment,
           let timeline = project.timeline(id: timelineID), let layer = timeline.layer(id: selection.layerID) {
            let options = project.reachOptions(below: layer, in: timeline)
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.step) {
                Text("Reach")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textTertiary)
                Spacer(minLength: Design.Space.step)
                Picker("Reach", selection: Binding(
                    get: { timelineClip.reach },
                    set: { project.setReach(ofClip: timelineClip.id, in: timelineID, toLayer: $0) }
                )) {
                    Text("All Layers Below").tag(UUID?.none)
                    ForEach(options) { option in
                        Text("Down to \(project.displayName(of: option, in: timeline))").tag(UUID?.some(option.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if project.reachesNothing(timelineClip, on: layer, in: timeline) {
                Text("The layer this adjustment reaches down to is above it, so it reaches nothing.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}


/// A block of related controls in the inspector. Each is a raised card on
/// the panel, which is what separates one group of options from the next —
/// the panel itself stays flat so the cards are the only thing with edges.
struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.close) {
            Text(title)
                .font(Design.Typeface.groupTitle)
                .foregroundStyle(Design.textSecondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Design.Space.close) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Space.step + 2)
            .beveledChip(fill: Design.Surface.overlay.color, radius: Design.Radius.panel)
        }
    }
}

/// A fact about the selection: its name on the left, its value on the
/// right. Values that are quantities are monospaced, so a column of them
/// lines up and doesn't shuffle as the playhead moves.
struct InspectorRow: View {
    let label: String
    let value: String
    var numeric = false

    init(_ label: String, value: String, numeric: Bool = false) {
        self.label = label
        self.value = value
        self.numeric = numeric
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.step) {
            Text(label)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
            Spacer(minLength: Design.Space.step)
            Text(value)
                .font(numeric ? Design.Typeface.numericSmall : Design.Typeface.label)
                .foregroundStyle(Design.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
