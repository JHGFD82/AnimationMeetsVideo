import AVFoundation
import CoreMedia
import SwiftUI

/// The viewer + inspector + timeline for a single timeline within a project.
/// Reused by both the main window and the external display's independent mode.
/// The main window puts its library to the left of the viewer, so the
/// timeline below runs the full width of the window.
struct TimelineEditorSurface<Library: View>: View {
    @Binding var project: EditingProject
    @Binding var timelineID: UUID
    @Binding var selection: TimelineSelection?
    let playback: PlaybackModel
    let analysis: AssetAnalysis
    @ViewBuilder let library: () -> Library

    @State private var playheadTime: CMTime = .zero
    @State private var buildTask: Task<Void, Never>?
    @State private var buildError: String?
    @State private var timelineHeight: CGFloat = 280
    /// What the timeline needs to show all its layers. It is never drawn
    /// taller, so there is no empty space under the layers; the viewer
    /// gets the rest.
    @State private var timelineIdealHeight: CGFloat = .infinity
    @AppStorage("showsTransitionsPanel") private var showsTransitions = false

    private let minTimelineHeight: CGFloat = 140
    private let minTopAreaHeight: CGFloat = 220

    private var timeline: Timeline? {
        project.timeline(id: timelineID)
    }

    private var compositionKey: CompositionKey { CompositionKey(project: project) }

    private var selectedTimelineClip: TimelineClip? {
        guard let selection, selection.timelineID == timelineID, let timeline,
              let layer = timeline.layer(id: selection.layerID)
        else {
            return nil
        }
        return layer.clips.first { $0.id == selection.timelineClipID }
    }

    private var selectedInfo: ResolvedClipInfo? {
        guard let selectedTimelineClip else { return nil }
        return project.resolvedInfo(for: selectedTimelineClip.source)
    }

    var body: some View {
        GeometryReader { geometry in
            let maxTimelineHeight = max(minTimelineHeight, geometry.size.height - minTopAreaHeight)
            // The transitions panel needs room for its tiles.
            let neededHeight = showsTransitions ? max(timelineIdealHeight, 240) : timelineIdealHeight
            let resolvedTimelineHeight = min(min(max(timelineHeight, minTimelineHeight), maxTimelineHeight), neededHeight)

            VStack(spacing: 0) {
                TimelineHeaderBar(project: $project, timelineID: $timelineID)
                Divider()

                HStack(spacing: 0) {
                    library()
                    ViewerPanel(
                        playback: playback,
                        hasContent: !(timeline?.layers.isEmpty ?? true),
                        frameSize: timeline?.frameSize ?? CGSize(width: 16, height: 9),
                        frameRate: timeline?.frameRate ?? 24,
                        buildError: buildError
                    )
                    InspectorPanel(
                        project: $project,
                        timelineID: timelineID,
                        selection: selection,
                        info: selectedInfo,
                        timelineClip: selectedTimelineClip,
                        playheadTime: playheadTime,
                        onSeek: { time in scrub(to: time) },
                        onDeleteSelection: { selection = nil }
                    )
                    .frame(width: 280)
                }
                .frame(maxHeight: .infinity)

                TimelineResizeHandle(
                    height: Binding(get: { resolvedTimelineHeight }, set: { timelineHeight = $0 }),
                    minHeight: min(minTimelineHeight, resolvedTimelineHeight),
                    maxHeight: maxTimelineHeight
                )

                HStack(spacing: 0) {
                    timelineView
                    if showsTransitions {
                        Divider()
                        TransitionsPanel(onClose: { showsTransitions = false })
                            .frame(width: 220)
                            .transition(.move(edge: .trailing))
                    }
                }
                .frame(height: resolvedTimelineHeight)
                .animation(.easeInOut(duration: 0.2), value: showsTransitions)
            }
        }
        .onChange(of: timelineID) { _, newValue in
            if selection?.timelineID != newValue {
                selection = nil
            }
            playback.player.pause()
            playheadTime = .zero
            rebuildPlayerItem(resetPosition: true)
        }
        .onChange(of: compositionKey) { _, _ in
            rebuildPlayerItem()
        }
        .onChange(of: playback.currentTime) { _, newValue in
            if playback.isPlaying {
                playheadTime = newValue
            }
        }
        .onAppear {
            rebuildPlayerItem(resetPosition: true)
        }
        .dropDestination(for: SceneDragPayload.self) { payloads, _ in
            dropScenes(payloads, onLayer: nil, at: .zero)
        }
    }

    @ViewBuilder
    private var timelineView: some View {
        if let timeline {
            TimelineView(
                project: project,
                timeline: timeline,
                timelineID: timelineID,
                selection: selection,
                beatTracks: analysis.beats,
                beatClicks: playback.beatClicks,
                playheadTime: $playheadTime,
                onScrub: { time in scrub(to: time) },
                onSelectClip: { layerID, clip in
                    selection = TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clip.id)
                },
                onRenameLayer: { layerID, name in project.renameLayer(layerID, in: timelineID, to: name) },
                onMoveLayer: { layerID, offset in project.moveLayer(layerID, in: timelineID, by: offset) },
                onMoveLayerTo: { layerID, index in project.moveLayer(layerID, in: timelineID, toIndex: index) },
                onMoveClip: { layerID, clipID, targetLayerID, newStart in
                    project.moveClip(clipID, in: timelineID, layer: layerID, onto: targetLayerID, to: newStart)
                    if let targetLayerID, selection?.timelineClipID == clipID,
                       project.timeline(id: timelineID)?.layer(id: targetLayerID)?.clips.contains(where: { $0.id == clipID }) == true {
                        selection?.layerID = targetLayerID
                    }
                },
                onDropScenes: { payloads, layerID, time in dropScenes(payloads, onLayer: layerID, at: time) },
                onApplyJointEdit: { layerID, clipID, edit in
                    project.applyJointEdit(edit, at: clipID, in: timelineID, layer: layerID)
                },
                onIdealHeightChange: { timelineIdealHeight = $0 },
                onTrimClipStart: { layerID, clipID, newTrimStart in
                    project.trimClipStart(clipID, in: timelineID, layer: layerID, to: newTrimStart)
                },
                onTrimClipEnd: { layerID, clipID, newTrimEnd in
                    project.trimClipEnd(clipID, in: timelineID, layer: layerID, to: newTrimEnd)
                },
                onEditTransform: { layerID, change in
                    project.editTransform(of: layerID, in: timelineID, change)
                },
                onSetTransition: { layerID, clipID, kind, edge in
                    project.setTransition(kind, at: edge, of: clipID, in: timelineID, layer: layerID)
                },
                onRemoveTransition: { layerID, clipID, edge in
                    project.removeTransition(at: edge, of: clipID, in: timelineID, layer: layerID)
                },
                onSelectTransition: { layerID, clip, edge in
                    selection = TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clip.id, transitionEdge: edge)
                },
                onSetTransitionCurve: { layerID, clipID, edge, curve in
                    project.setTransitionCurve(curve, at: edge, of: clipID, in: timelineID, layer: layerID)
                },
                onDetachAudio: { layerID, clipIDs in
                    project.detachAudio(of: clipIDs, in: timelineID, layer: layerID)
                },
                showsTransitions: $showsTransitions
            )
        } else {
            ContentUnavailableView("No Timeline Selected", systemImage: "timeline.selection")
        }
    }

    /// Scenes dragged from the browser become ordinary clips, back to back.
    /// Dropped on a layer they go onto it at the drop time, if they fit;
    /// otherwise, or dropped elsewhere, onto a new layer.
    private func dropScenes(_ payloads: [SceneDragPayload], onLayer layerID: UUID?, at time: CMTime) -> Bool {
        var firstClip: (layerID: UUID, clipID: UUID)?
        for payload in payloads {
            if let layerID,
               let added = project.addScenes(payload.scenes, ofAsset: payload.assetID, intoLayer: layerID, in: timelineID, at: time) {
                if firstClip == nil, let clipID = added.first { firstClip = (layerID, clipID) }
            } else if let result = project.addScenes(payload.scenes, ofAsset: payload.assetID, intoTimeline: timelineID, at: time),
                      firstClip == nil, let clipID = result.clipIDs.first {
                firstClip = (result.layerID, clipID)
            }
        }
        guard let firstClip else { return false }
        selection = TimelineSelection(timelineID: timelineID, layerID: firstClip.layerID, timelineClipID: firstClip.clipID)
        return true
    }

    // MARK: -

    /// Scrubbing moves the shared playhead and seeks the player directly —
    /// the player always shows the whole composited timeline (every layer
    /// stacked together), not just one selected clip, so no per-clip time
    /// translation is needed here.
    private func scrub(to time: CMTime) {
        playheadTime = time
        playback.seek(to: time)
    }

    /// Rebuilds the player item from the current project. Keeps the
    /// position and play state the player has when the build *finishes*,
    /// not when it started, so edits made during playback don't jump back.
    private func rebuildPlayerItem(resetPosition: Bool = false) {
        buildTask?.cancel()
        guard let timeline, !timeline.layers.isEmpty else {
            playback.player.replaceCurrentItem(with: nil)
            buildError = nil
            return
        }
        let project = self.project
        let tID = timelineID
        let player = playback.player
        let playback = playback
        let frameRate = timeline.frameRate
        buildTask = Task {
            do {
                let composed = try await CompositionExporter.buildComposedTimeline(
                    for: project, timelineID: tID, forPreview: true, meter: playback.meter
                )
                guard !Task.isCancelled else { return }
                let wasPlaying = player.timeControlStatus != .paused
                let resumeTime = resetPosition ? playheadTime : player.currentTime()
                let item = AVPlayerItem(asset: composed.composition)
                playback.prepare(item, with: composed, frameRate: frameRate)
                player.replaceCurrentItem(with: item)
                _ = await player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { player.play() }
                buildError = nil
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                if let compositionError = error as? CompositionError, case .emptyTimeline = compositionError {
                    player.replaceCurrentItem(with: nil)
                    buildError = nil
                } else {
                    buildError = error.localizedDescription
                }
            }
        }
    }
}

extension TimelineEditorSurface where Library == EmptyView {
    init(
        project: Binding<EditingProject>,
        timelineID: Binding<UUID>,
        selection: Binding<TimelineSelection?>,
        playback: PlaybackModel,
        analysis: AssetAnalysis
    ) {
        self.init(project: project, timelineID: timelineID, selection: selection, playback: playback, analysis: analysis) {
            EmptyView()
        }
    }
}

/// A draggable divider that lets the timeline's height be resized relative
/// to the viewer/inspector area above it — previously fixed, splitting the
/// window roughly in half regardless of how much space the timeline needed.
struct TimelineResizeHandle: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        ZStack {
            Divider()
            Color.clear
        }
        .frame(height: 7)
        .contentShape(Rectangle())
        .pointerStyle(.rowResize)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? height
                    if dragStartHeight == nil { dragStartHeight = height }
                    height = min(maxHeight, max(minHeight, start - value.translation.height))
                }
                .onEnded { _ in
                    dragStartHeight = nil
                }
        )
    }
}
