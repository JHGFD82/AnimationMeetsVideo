import CoreMedia
import SwiftUI

/// The effects panel's sound: an EQ's graph, inline and in its larger
/// sheet, and the clip's volume and pan rows.
extension EffectsPanel {
    // MARK: EQ

    func equalizerGraph(_ effect: Effect, of clip: TimelineClip, at time: CMTime, dimmed: Bool, onExpand: (() -> Void)?) -> EqualizerGraph {
        EqualizerGraph(
            effect: effect, time: time, isDimmed: dimmed,
            onEdit: { kind, change in
                editEffect(effect.id, in: clip) { effect in
                    effect.changeControl(kind, change)
                }
            },
            onExpand: onExpand,
            readPaused: pausedSpectrumReader(for: clip)
        )
    }

    /// Reads an EQ's spectrum from the clip's own file while paused: only
    /// a media clip has one. Its source time is the file's, less any shift
    /// from replacing the file.
    private func pausedSpectrumReader(for clip: TimelineClip) -> EqualizerGraph.PausedReader? {
        guard case .media(let mediaID) = clip.source, let media = project.mediaClip(id: mediaID), let url = media.url else { return nil }
        let offset = media.alignmentOffset
        return { pre, effect, time in
            await EqualizerSpectrum.levels(ofFile: url, endingAt: CMTimeAdd(time, offset), through: effect, at: time, pre: pre)
        }
    }

    /// The EQ at a size for fine work, editing the same controls.
    @ViewBuilder
    func expandedEqualizerSheet(_ item: ExpandedEqualizer) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            if let clip = project.clipAndLayer(item.clipID, in: timelineID)?.clip, let effect = clip.effect(id: item.effectID), let timeline {
                Text("\(project.clipName(clip.id, in: timelineID)) · \(effect.displayName)")
                    .font(Design.Typeface.panelTitle)
                    .foregroundStyle(Design.textPrimary)
                let source = ClipLaneGeometry(clip: clip, timeline: timeline, width: 100)
                    .clampedSource(atTimeline: timeline.snappedToFrame(playheadTime))
                equalizerGraph(effect, of: clip, at: source, dimmed: !effect.enabled, onExpand: nil)
                    .frame(minWidth: 640, minHeight: 320)
                EqualizerBandStrip(effect: effect, time: source) { kind, change in
                    editEffect(effect.id, in: clip) { effect in
                        effect.changeControl(kind, change)
                    }
                }
            } else {
                Text("The EQ is no longer there.").foregroundStyle(Design.textSecondary)
            }
            HStack {
                Text("Drag a band to move it, ⌥-drag or scroll over it to change its Q, double-click to switch it on or off.")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textTertiary)
                Spacer()
                Button("Done") { expandedEqualizer = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Space.group)
    }

    // MARK: Sound

    func audioRow(_ property: AudioProperty, _ c: RowContext) -> some View {
        let clip = c.clip
        let value = property == .volume ? clip.volume : clip.pan
        let keyPath: WritableKeyPath<TimelineClip, AnimatedValue<Double>> = property == .volume ? \.volume : \.pan
        let parameter: AnimatedParameter = property == .volume ? .clipVolume(clipID: clip.id) : .clipPan(clipID: clip.id)
        let key = ParameterKey(timelineID: timelineID, parameter: parameter)
        return labelled(
            AudioPropertyRow(
                property: property,
                value: value,
                playhead: PlayheadTime(c.playhead) { c.geometry.clampedSource(atTimeline: c.timeline.snappedToFrame($0)) },
                onEdit: { change in editClip(clip.id) { change(&$0[keyPath: keyPath]) } },
                onSeek: { onSeek(clip.timelineTime(forSourceTime: $0)) },
                onShowGraph: graphs.map { graphs in { graphs.show(key) } },
                held: { projectState?.held?.clipAndLayer(clip.id, in: timelineID)?.clip[keyPath: keyPath] }
            )
            .padding(.horizontal, 8),
            lane: ParameterLane(
                marks: (projectState?.held?.clipAndLayer(clip.id, in: timelineID)?.clip[keyPath: keyPath] ?? value).marks,
                geometry: c.geometry, playhead: c.frameTime(animated: value.isAnimated), height: EffectsPanelMetrics.rowHeight,
                onSeek: onSeek,
                onMove: { from, to, copy in editClip(clip.id) { $0[keyPath: keyPath].moveKeyframe(at: from, to: to, copying: copy) } },
                onDelete: { time in editClip(clip.id) { $0[keyPath: keyPath].removeKeyframe(at: time) } },
                onEase: { time, preset in editClip(clip.id) { $0[keyPath: keyPath].applyEase(preset, at: time) } }
            )
        )
    }
}
