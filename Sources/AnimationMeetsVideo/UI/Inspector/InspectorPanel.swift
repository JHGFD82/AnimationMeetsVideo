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

    private var maxDurationSeconds: Double? {
        switch info {
        case .media(let clip): clip.duration.seconds
        case .timeline(let timeline): timeline.duration.seconds
        case nil: nil
        }
    }

    var body: some View {
        Form {
            Section("Inspector") {
                switch info {
                case .media(let clip):
                    LabeledContent("Name", value: clip.name)
                    LabeledContent("Source duration", value: clip.duration.formatted)
                    if clip.frameRate > 0 {
                        LabeledContent("Frame rate", value: String(format: "%.2f fps", clip.frameRate))
                    }
                    LabeledContent("Codec", value: clip.codecName)
                    LabeledContent("Color", value: clip.colorSpace.rawValue)
                case .timeline(let timeline):
                    LabeledContent("Name", value: timeline.name)
                    LabeledContent("Duration", value: timeline.duration.formatted)
                    LabeledContent("Frame size", value: "\(Int(timeline.frameSize.width))×\(Int(timeline.frameSize.height))")
                    LabeledContent("Frame rate", value: String(format: "%.2f fps", timeline.frameRate))
                    LabeledContent("Color", value: timeline.colorSpace.rawValue)
                case nil:
                    Text("Select a clip to inspect it.")
                        .foregroundStyle(.secondary)
                }
            }

            if let selection, let timelineClip, let maxDurationSeconds {
                Section("Trim") {
                    Stepper(
                        "In: \(timelineClip.trimStart.formatted)",
                        value: Binding(
                            get: { timelineClip.trimStart.seconds },
                            set: { setTrimStart($0, selection: selection) }
                        ),
                        in: 0...max(0, timelineClip.trimEnd.seconds - 0.1),
                        step: 0.5
                    )
                    Stepper(
                        "Out: \(timelineClip.trimEnd.formatted)",
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
                    )
                }

                if let timeline = project.timeline(id: timelineID),
                   let layer = timeline.layer(id: selection.layerID),
                   layer.isVisual(in: project) {
                    Section("Layer Transform") {
                        TransformInspectorSection(
                            transform: layer.transform,
                            time: timeline.snappedToFrame(playheadTime),
                            frameSize: timeline.frameSize,
                            onEdit: { change in project.editTransform(of: layer.id, in: timelineID, change) },
                            onSeek: onSeek
                        )
                    }
                }

                if timelineClip.transitionIn != nil || timelineClip.transitionOut != nil {
                    Section("Transitions") {
                        transitionRow(.leading, of: timelineClip, selection: selection)
                        transitionRow(.trailing, of: timelineClip, selection: selection)
                    }
                }

                Section("Arrange") {
                    if project.hasLinkedAudio(timelineClip) {
                        Button("Detach Audio") {
                            project.detachAudio(of: [timelineClip.id], in: timelineID, layer: selection.layerID)
                        }
                    }
                    Button("Delete Clip", role: .destructive) {
                        project.deleteClip(selection.timelineClipID, in: timelineID, layer: selection.layerID)
                        onDeleteSelection()
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(info == nil)
    }

    /// A transition's kind and length, a frame per step, with a way to
    /// remove it.
    @ViewBuilder
    private func transitionRow(_ edge: TransitionEdge, of clip: TimelineClip, selection: TimelineSelection) -> some View {
        if let transition = clip.transition(at: edge), let timeline = project.timeline(id: timelineID) {
            let frames = Int((transition.duration.seconds / timeline.frameDuration.seconds).rounded())
            HStack {
                Stepper(
                    "\(edge == .leading ? "Start" : "End"): \(transition.kind.name), \(frames) fr",
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
                )
                Button {
                    project.removeTransition(at: edge, of: clip.id, in: timelineID, layer: selection.layerID)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove transition")
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
