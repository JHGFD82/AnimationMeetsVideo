import CoreMedia
import SwiftUI

/// A numeric value in a `ToggleFieldsRow`.
struct ToggleField: Identifiable {
    var id: String { label }
    let label: String
    let value: Double
    var unit = ""
    var step = 1.0
    var range: ClosedRange<Double>?
    var fractionDigits = 0
    let onCommit: (Double) -> Void
}

/// A setting that is either off or has a few numbers: a checkbox, its name,
/// and a field for each number while it is on.
struct ToggleFieldsRow: View {
    let title: String
    let isOn: Bool
    var help = ""
    let onToggle: @MainActor (Bool) -> Void
    let fields: [ToggleField]

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 12)
            Toggle("", isOn: Binding(get: { isOn }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
            Text(title)
                .foregroundStyle(isOn ? Design.textSecondary : Design.textTertiary)
                .lineLimit(1)
                .frame(width: 66, alignment: .leading)
            if isOn {
                ForEach(fields) { field in
                    Text(field.label)
                        .font(Design.Typeface.micro)
                        .foregroundStyle(Design.textTertiary)
                    NumericField(
                        value: field.value, unit: field.unit, fractionDigits: field.fractionDigits,
                        dragStep: field.step, dragRange: field.range, onCommit: field.onCommit
                    )
                }
            }
            Spacer(minLength: 2)
        }
        .font(Design.Typeface.label)
        .padding(.horizontal, 4)
        .frame(height: EffectsPanelMetrics.rowHeight)
        .help(help)
    }
}

/// The pinned Time rows above the anchor point, and the Shutter rows below
/// the transitions (see docs/effects.md, "Time and Shutter").
extension EffectsPanel {
    private func hasMedia(_ clip: TimelineClip) -> Bool {
        if case .media = clip.source { return true }
        return false
    }

    private func editTime(_ c: RowContext, _ change: @escaping (inout ClipTime) -> Void) {
        project.editTime(ofClip: c.clip.id, in: timelineID, layer: c.layer.id, change)
    }

    private func frames(_ time: CMTime, in c: RowContext) -> Double {
        let frame = c.timeline.frameDuration.seconds
        return frame > 0 ? (time.seconds / frame).rounded() : 0
    }

    private func time(frames: Double, in c: RowContext) -> CMTime {
        CMTimeMultiply(c.timeline.frameDuration, multiplier: Int32(max(1, min(frames.rounded(), 1000))))
    }

    @ViewBuilder
    func timeRows(_ c: RowContext) -> some View {
        let clip = c.clip
        if hasMedia(clip) {
            labelled(
                PinnedRow(title: "Time", systemImage: "clock") { EmptyView() },
                lane: emptyLane(c)
            )
            speedRow(c)
            if project.playsVideo(clip) {
                frameBlendingRow(c)
                if clip.time.frameBlending == .opticalFlow {
                    HStack(spacing: 0) {
                        EffectNoteRow(note: EffectNote(text: "Shown as Blend until the stretch is rendered.", dims: false))
                            .frame(width: EffectsPanelMetrics.labelWidth, alignment: .leading)
                        Color.black.opacity(0.12)
                    }
                }
                echoRow(c)
            }
            if project.playsAudio(clip) {
                soundRow(c)
            }
        }
    }

    @ViewBuilder
    func shutterRows(_ c: RowContext) -> some View {
        let clip = c.clip
        if project.playsVideo(clip), clip.source != .adjustment {
            labelled(
                PinnedRow(title: "Shutter", systemImage: "camera.aperture") { EmptyView() },
                lane: emptyLane(c)
            )
            motionBlurRow(c)
            if hasMedia(clip) { trailsRow(c) }
        }
    }

    private func speedRow(_ c: RowContext) -> some View {
        let clip = c.clip
        let key = ParameterKey(timelineID: timelineID, parameter: .speed(clipID: clip.id))
        let speed = clip.time.speed
        return labelled(
            ParameterRow(
                name: "Speed",
                indent: 14,
                components: [clip.speed(atSource: c.sourceNow)],
                unit: "%",
                dragRange: { _ in ClipTime.speedRange },
                isAnimated: speed.isAnimated,
                isSelected: false,
                keyframeTimes: speed.keyframes.map { clip.timelineTime(forSourceTime: $0.time) },
                playhead: c.frameTime,
                onSelect: {},
                onSetComponent: { _, value in editTime(c) { $0.speed.set(value, at: c.sourceNow) } },
                onToggleAnimated: { editTime(c) { $0.speed.setAnimated(!$0.speed.isAnimated, at: c.sourceNow) } },
                onToggleKeyframe: { editTime(c) { $0.speed.toggleKeyframe(at: c.sourceNow) } },
                onSeek: onSeek,
                onShowGraph: graphs.map { graphs in { graphs.show(key) } }
            ) {
                Button("Reset") { editTime(c) { $0.speed = AnimatedValue(100) } }
                    .disabled(!clip.isRetimed)
            },
            lane: ParameterLane(
                marks: speed.marks, geometry: c.geometry, playhead: c.frameTime, height: EffectsPanelMetrics.rowHeight,
                onSeek: onSeek,
                onMove: { from, to in editTime(c) { $0.speed.moveKeyframe(at: from, to: to) } },
                onDelete: { time in editTime(c) { $0.speed.removeKeyframe(at: time) } },
                onEase: { time, preset in editTime(c) { $0.speed.applyEase(preset, at: time) } }
            )
        )
        .help("How fast the clip plays, as a percentage of its source's own speed. The clip lasts as long as its source does at that speed; keyframes (in the source's time) make a speed ramp.")
    }

    private func frameBlendingRow(_ c: RowContext) -> some View {
        let clip = c.clip
        return labelled(
            ChoiceRow(
                name: "Frames",
                indent: 14,
                options: FrameBlending.allCases.map { ($0.rawValue, $0.name) },
                selected: clip.time.frameBlending.rawValue,
                isSelected: false,
                dragHandle: nil,
                showsMenu: false,
                isDimmed: clip.time.frameBlending == .off,
                onSelect: {},
                onChoose: { choice in
                    editTime(c) { $0.frameBlending = FrameBlending(rawValue: choice) ?? .off }
                },
                menu: { EmptyView() }
            ),
            lane: emptyLane(c)
        )
        .help("Frame Blending: what plays when the speed doesn't land on whole frames. Blend mixes the two nearest frames; Optical Flow builds in-between frames, drawn only in renders and export (the viewer shows Blend until a stretch is rendered).")
    }

    private func echoRow(_ c: RowContext) -> some View {
        let echo = c.clip.time.echo
        let frame = c.timeline.frameDuration
        return labelled(
            ToggleFieldsRow(
                title: "Echo",
                isOn: echo != nil,
                help: "Earlier frames of the footage layered under the current one, each a share as strong as the one in front of it.",
                onToggle: { on in
                    editTime(c) { $0.echo = on ? Echo(count: 4, delay: CMTimeMultiply(frame, multiplier: 2), decay: 0.6) : nil }
                },
                fields: [
                    ToggleField(label: "Copies", value: Double(echo?.count ?? 0), step: 0.1, range: 1...16) { value in
                        editTime(c) { $0.echo?.count = Int(value.rounded()) }
                    },
                    ToggleField(label: "Delay", value: echo.map { frames($0.delay, in: c) } ?? 0, unit: " fr", step: 0.1, range: 1...240) { value in
                        editTime(c) { $0.echo?.delay = time(frames: value, in: c) }
                    },
                    ToggleField(label: "Decay", value: (echo?.decay ?? 0) * 100, unit: "%", step: 1, range: 0...100) { value in
                        editTime(c) { $0.echo?.decay = value / 100 }
                    },
                ]
            ),
            lane: emptyLane(c)
        )
    }

    private func soundRow(_ c: RowContext) -> some View {
        let clip = c.clip
        return labelled(
            ChoiceRow(
                name: "Sound",
                indent: 14,
                options: SoundMode.allCases.map { ($0.rawValue, $0.name) },
                selected: clip.time.sound.rawValue,
                isSelected: false,
                dragHandle: nil,
                showsMenu: false,
                isDimmed: !clip.isRetimed,
                onSelect: {},
                onChoose: { choice in editTime(c) { $0.sound = SoundMode(rawValue: choice) ?? .keepPitch } },
                menu: { EmptyView() }
            ),
            lane: emptyLane(c)
        )
        .help("What the sound does while the speed isn't 100%: Keep Pitch plays it at the new speed at its own pitch, Change Pitch like tape, Mute silences it.")
    }

    private func motionBlurRow(_ c: RowContext) -> some View {
        let blur = c.clip.shutter.motionBlur
        return labelled(
            ToggleFieldsRow(
                title: "Motion Blur",
                isOn: blur != nil,
                help: "The finished clip drawn at several moments across the shutter and averaged. The viewer draws two while playing; paused frames, renders and export use them all.",
                onToggle: { on in editClip(c.clip.id) { $0.shutter.motionBlur = on ? MotionBlur() : nil } },
                fields: [
                    ToggleField(label: "Angle", value: blur?.angle ?? 180, unit: "°", step: 1, range: 0...360) { value in
                        editClip(c.clip.id) { $0.shutter.motionBlur?.angle = value }
                    },
                    ToggleField(label: "Samples", value: Double(blur?.samples ?? 8), step: 0.2, range: 2...64) { value in
                        editClip(c.clip.id) { $0.shutter.motionBlur?.samples = Int(value.rounded()) }
                    },
                ]
            ),
            lane: emptyLane(c)
        )
    }

    private func trailsRow(_ c: RowContext) -> some View {
        let trails = c.clip.shutter.trails
        let frame = c.timeline.frameDuration
        return labelled(
            ToggleFieldsRow(
                title: "Trails",
                isOn: trails != nil,
                help: "Copies of the finished clip from earlier moments, movement and all, each a share as strong as the one in front of it.",
                onToggle: { on in
                    editClip(c.clip.id) { $0.shutter.trails = on ? Trails(count: 4, delay: CMTimeMultiply(frame, multiplier: 2), decay: 0.6) : nil }
                },
                fields: [
                    ToggleField(label: "Copies", value: Double(trails?.count ?? 0), step: 0.1, range: 1...16) { value in
                        editClip(c.clip.id) { $0.shutter.trails?.count = Int(value.rounded()) }
                    },
                    ToggleField(label: "Delay", value: trails.map { frames($0.delay, in: c) } ?? 0, unit: " fr", step: 0.1, range: 1...240) { value in
                        editClip(c.clip.id) { $0.shutter.trails?.delay = time(frames: value, in: c) }
                    },
                    ToggleField(label: "Decay", value: (trails?.decay ?? 0) * 100, unit: "%", step: 1, range: 0...100) { value in
                        editClip(c.clip.id) { $0.shutter.trails?.decay = value / 100 }
                    },
                ]
            ),
            lane: emptyLane(c)
        )
    }
}
