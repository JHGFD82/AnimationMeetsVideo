import CoreMedia
import SwiftUI

struct InspectorPanel: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    var selection: TimelineSelection?
    let info: ResolvedClipInfo?
    let timelineClip: TimelineClip?
    let playheadTime: CMTime
    let onSeek: (CMTime) -> Void
    let onDeleteSelection: () -> Void
    /// The surface's graph editor panels.
    @Environment(KeyframeGraphHUDs.self) private var graphs: KeyframeGraphHUDs?
    @Environment(BeatMatchController.self) private var beatMatch: BeatMatchController?

    /// The song of a selected clip on a Music layer, which can be beat matched.
    private var beatMatchAsset: MediaClip? {
        guard let selection, case .media(let clip) = info, clip.url != nil, clip.hasAudio,
              project.timeline(id: selection.timelineID)?.layer(id: selection.layerID)?.kind == .music
        else { return nil }
        return clip
    }

    private var maxDurationSeconds: Double? {
        switch info {
        case .media(let clip): clip.duration.seconds
        case .timeline(let timeline): timeline.duration.seconds
        case .adjustment: 36_000
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
                        InspectorGroup("Volume") {
                            VolumePropertyRow(
                                volume: timelineClip.volume,
                                time: timeline.snappedToFrame(timelineClip.sourceTime(atTimelineTime: playheadTime)),
                                onEdit: { change in
                                    project.editClip(timelineClip.id, in: timelineID) { change(&$0.volume) }
                                },
                                onSeek: { onSeek(timelineClip.timelineTime(forSourceTime: $0)) },
                                onShowGraph: graphs.map { graphs in
                                    { graphs.show(ParameterKey(timelineID: timelineID, parameter: .clipVolume(clipID: timelineClip.id))) }
                                }
                            )
                        }
                    }
                    if let layer = timeline.layer(id: selection.layerID), layer.kind.isAudio {
                        InspectorGroup("Layer volume") {
                            VolumePropertyRow(
                                volume: layer.volume,
                                time: timeline.snappedToFrame(playheadTime),
                                onEdit: { change in project.editVolume(of: layer.id, in: timelineID, change) },
                                onSeek: onSeek,
                                onShowGraph: graphs.map { graphs in
                                    { graphs.show(ParameterKey(timelineID: timelineID, parameter: .layerVolume(layerID: layer.id))) }
                                }
                            )
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
                    if project.hasLinkedAudio(timelineClip) {
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
            to: CMTime(seconds: seconds, preferredTimescale: 600)
        )
    }

    private func setTrimEnd(_ seconds: Double, selection: TimelineSelection) {
        project.trimClipEnd(
            selection.timelineClipID,
            in: timelineID,
            layer: selection.layerID,
            to: CMTime(seconds: seconds, preferredTimescale: 600)
        )
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
