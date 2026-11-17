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

    /// The EQ at a size for fine work, editing the same controls, in the
    /// frame every sheet has: the clip and the EQ as its title, how to
    /// work the graph as its subtitle, and Done in the footer.
    func expandedEqualizerSheet(_ item: ExpandedEqualizer) -> some View {
        let found: (clip: TimelineClip, effect: Effect)? = project.clipAndLayer(item.clipID, in: timelineID).flatMap { pair in
            pair.clip.effect(id: item.effectID).map { (clip: pair.clip, effect: $0) }
        }
        let close = { expandedEqualizer = nil }
        return SheetFrame(
            title: found.map { "\(project.clipName($0.clip.id, in: timelineID)) · \($0.effect.displayName)" } ?? "EQ",
            subtitle: "Drag a band to move it, ⌥-drag or scroll over it for its Q, double-click to turn it on or off.",
            width: Design.SheetWidth.graph
        ) {
            if let found, let timeline {
                let source = ClipLaneGeometry(clip: found.clip, timeline: timeline, width: 100)
                    .clampedSource(atTimeline: timeline.snappedToFrame(playheadTime))
                equalizerGraph(found.effect, of: found.clip, at: source, dimmed: !found.effect.enabled, onExpand: nil)
                    .frame(minHeight: 320)
                EqualizerBandStrip(effect: found.effect, time: source) { kind, change in
                    editEffect(found.effect.id, in: found.clip) { effect in
                        effect.changeControl(kind, change)
                    }
                }
            } else {
                Text(verbatim: "The EQ is no longer there.")
                    .font(Design.Typeface.body)
                    .foregroundStyle(Design.textSecondary)
            }
        } actions: {
            Button("Done", action: close)
                .keyboardShortcut(.defaultAction)
        }
        // Done is the only action, so Escape closes too.
        .onExitCommand(perform: close)
    }

    // MARK: Sound

    func audioRow(_ property: AudioProperty, _ c: RowContext) -> some View {
        let clip = c.clip
        let value = property == .volume ? clip.volume : clip.pan
        let keyPath: WritableKeyPath<TimelineClip, AnimatedValue<Double>> = property == .volume ? \.volume : \.pan
        let parameter: AnimatedParameter = property == .volume ? .clipVolume(clipID: clip.id) : .clipPan(clipID: clip.id)
        let key = ParameterKey(timelineID: timelineID, parameter: parameter)
        let method = property == .volume ? methodBadge(.volume, c) : nil
        return labelled(
            HStack(spacing: 4) {
            AudioPropertyRow(
                property: property,
                value: value,
                playhead: PlayheadTime(c.playhead) { c.geometry.clampedSource(atTimeline: c.timeline.snappedToFrame($0)) },
                onEdit: { change in editClip(clip.id) { change(&$0[keyPath: keyPath]) } },
                onSeek: { onSeek(clip.timelineTime(forSourceTime: $0)) },
                onShowGraph: graphs.map { graphs in { graphs.show(key) } },
                held: { projectState?.held?.clipAndLayer(clip.id, in: timelineID)?.clip[keyPath: keyPath] }
            )
                if let method {
                    KeyframeMethodBadge(info: method) { openDesigner(on: .volume, of: clip) }
                }
            }
            .padding(.horizontal, 8),
            lane: ParameterLane(
                id: key, marks: (projectState?.held?.clipAndLayer(clip.id, in: timelineID)?.clip[keyPath: keyPath] ?? value).marks,
                geometry: c.geometry, playhead: c.frameTime(animated: value.isAnimated), height: EffectsPanelMetrics.rowHeight,
                onSeek: onSeek,
                edits: LaneKeyframeEdits { (change: @escaping (inout AnimatedValue<Double>) -> Void) in editClip(clip.id) { change(&$0[keyPath: keyPath]) } }
            )
        )
    }
}
