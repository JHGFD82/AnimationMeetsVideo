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
    /// Renders in the background; absent in windows that don't render.
    @Environment(RenderScheduler.self) private var renderer: RenderScheduler?

    @State private var playheadTime: CMTime = .zero
    @State private var trimPreview = TrimPreviewModel()
    @State private var buildTask: Task<Void, Never>?
    @State private var buildError: String?
    /// A render finished while playing; its rebuild waits for a pause,
    /// since swapping the item mid-play freezes the picture.
    @State private var renderRebuildPending = false
    /// As tall as the person makes it, not as tall as its layers need: its
    /// areas share whatever height it has and scroll the rest.
    @AppStorage("timelineHeight") private var timelineHeight: Double = 280
    @AppStorage("showsTransitionsPanel") private var showsTransitions = false
    @AppStorage("showsEffectsPanel") private var showsEffects = false
    @AppStorage("effectsPanelWidth") private var effectsPanelWidth = 640.0
    @State private var effectsState = EffectsPanelState()
    @AppStorage("showsAudioMeter") private var showsMeter = false
    /// The graph editors this surface has open, one HUD per parameter.
    @State private var graphs = KeyframeGraphHUDs()

    private let minTimelineHeight: CGFloat = 140
    private let minTopAreaHeight: CGFloat = 220

    private var timeline: Timeline? {
        project.timeline(id: timelineID)
    }

    /// The effects panel's width, kept so the timeline keeps room.
    private func effectsWidth(in available: CGFloat) -> CGFloat {
        min(max(CGFloat(effectsPanelWidth), EffectsPanelResizeHandle.minimumWidth), max(EffectsPanelResizeHandle.minimumWidth, available * 0.8))
    }

    /// The clip and effect Show Up to Here is showing, while the effect
    /// is still there.
    private var partialView: EffectsPanelState.ShowUpTo? {
        guard let showing = effectsState.showUpTo,
              project.hasEffect(showing.effectID, ofClip: showing.clipID, in: timelineID)
        else {
            return nil
        }
        return showing
    }

    /// The project as the viewer draws it: the real one, except while Show
    /// Up to Here is on, when one clip is cut short. Export and renders
    /// always use the real one.
    private var viewedProject: EditingProject {
        guard let showing = partialView else { return project }
        return project.showing(upTo: showing.effectID, ofClip: showing.clipID, in: timelineID)
    }

    private var compositionKey: CompositionKey { CompositionKey(project: viewedProject) }

    /// What the viewer's banner says while Show Up to Here is on.
    private var partialBanner: String? {
        guard let showing = partialView,
              let effect = project.clipAndLayer(showing.clipID, in: timelineID)?.clip.effects.first(where: { $0.id == showing.effectID })
        else {
            return nil
        }
        return "Showing up to \(effect.displayName)"
    }

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
            let resolvedTimelineHeight = min(max(CGFloat(timelineHeight), minTimelineHeight), maxTimelineHeight)

            VStack(spacing: 0) {
                TimelineHeaderBar(project: $project, timelineID: $timelineID)

                HStack(spacing: 0) {
                    library()
                    ViewerPanel(
                        playback: playback,
                        hasContent: timeline?.layers.contains { !$0.clips.isEmpty } ?? false,
                        frameSize: timeline?.frameSize ?? CGSize(width: 16, height: 9),
                        frameRate: timeline?.frameRate ?? 24,
                        buildError: buildError,
                        trimPreview: trimPreview,
                        banner: partialBanner,
                        onClearBanner: { effectsState.showUpTo = nil }
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
                    .grooved(.leading)
                }
                .frame(maxHeight: .infinity)

                TimelineResizeHandle(
                    height: Binding(get: { resolvedTimelineHeight }, set: { timelineHeight = Double($0) }),
                    minHeight: minTimelineHeight,
                    maxHeight: maxTimelineHeight
                )

                HStack(spacing: 0) {
                    timelineView
                    if showsMeter {
                        AudioMeterView(playback: playback)
                            .frame(width: 52)
                            .grooved(.leading)
                            .transition(.move(edge: .trailing))
                    }
                    if showsTransitions {
                        TransitionsPanel(onClose: { showsTransitions = false })
                            .frame(width: 220)
                            .grooved(.leading)
                            .transition(.move(edge: .trailing))
                    }
                    if showsEffects {
                        EffectsPanel(
                            project: $project,
                            timelineID: timelineID,
                            selection: selection,
                            playheadTime: playheadTime,
                            state: effectsState,
                            onSeek: { time in scrub(to: time) },
                            onSelectTransition: { edge in
                                if let selection {
                                    self.selection = TimelineSelection(
                                        timelineID: selection.timelineID, layerID: selection.layerID,
                                        timelineClipID: selection.timelineClipID, transitionEdge: edge
                                    )
                                }
                            },
                            onClose: { showsEffects = false }
                        )
                        .frame(width: effectsWidth(in: geometry.size.width))
                        .overlay(alignment: .leading) { EffectsPanelResizeHandle(width: $effectsPanelWidth, maxWidth: geometry.size.width * 0.8) }
                        .grooved(.leading)
                        .transition(.move(edge: .trailing))
                    }
                }
                .frame(height: resolvedTimelineHeight)
                .editorAnimation(Design.Motion.panel, value: showsTransitions)
                .editorAnimation(Design.Motion.panel, value: showsEffects)
                .editorAnimation(Design.Motion.panel, value: showsMeter)
            }
        }
        .environment(graphs)
        // The effects and transitions panels share a place: opening one
        // closes the other.
        .onChange(of: showsEffects) { _, on in if on { showsTransitions = false } }
        .onChange(of: showsTransitions) { _, on in if on { showsEffects = false } }
        .onChange(of: project, initial: true) { _, project in
            graphs.update(project: project)
            // Show Up to Here lets go of an effect that is gone.
            if effectsState.showUpTo != nil, partialView == nil { effectsState.showUpTo = nil }
        }
        .onChange(of: playheadTime, initial: true) { _, time in graphs.playhead = time }
        .onAppear {
            let project = $project
            graphs.onEdit = { change in change(&project.wrappedValue) }
            graphs.onSeek = { time in scrub(to: time) }
        }
        .onDisappear { graphs.closeAll() }
        .onChange(of: timelineID) { _, newValue in
            if selection?.timelineID != newValue {
                selection = nil
            }
            playback.player.pause()
            playheadTime = .zero
            rebuildPlayerItem(resetPosition: true)
        }
        .onChange(of: compositionKey) { _, _ in
            renderer?.noteActivity()
            rebuildPlayerItem()
        }
        // Volumes aren't part of the composition: the player's audio taps
        // read them as they play, so an edit is heard without a rebuild.
        .onChange(of: VolumeCurves.of(project), initial: true) { _, curves in
            playback.volumeCurves.replace(with: curves)
        }
        // Wherever it stops, playing or scrubbing, is where rendering starts.
        .onChange(of: playheadTime) { _, time in
            renderer?.playhead = time
        }
        .onChange(of: playback.isPlaying) { _, playing in
            renderer?.setPlaying(playing)
            if !playing, renderRebuildPending {
                renderRebuildPending = false
                rebuildPlayerItem()
            }
        }
        // A finished render plays once the item is rebuilt with it.
        // Renders only run while paused, but one can finish just as play
        // is pressed.
        .onChange(of: renderer?.finishedCount) { _, _ in
            if playback.isPlaying {
                renderRebuildPending = true
            } else {
                rebuildPlayerItem()
            }
        }
        .onChange(of: renderer?.packageURL) { _, _ in
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
                onMoveLayerTo: { layerID, position in project.moveLayer(layerID, in: timelineID, toPositionInKind: position) },
                onMoveClip: { layerID, clipID, targetLayerID, newStart in
                    project.moveClip(clipID, in: timelineID, layer: layerID, onto: targetLayerID, to: newStart)
                    if let targetLayerID, selection?.timelineClipID == clipID,
                       project.timeline(id: timelineID)?.layer(id: targetLayerID)?.clips.contains(where: { $0.id == clipID }) == true {
                        selection?.layerID = targetLayerID
                    }
                },
                onMoveClipToNewLayer: { layerID, clipID, kind in
                    if let newLayer = project.moveClipToNewLayer(clipID, in: timelineID, layer: layerID, kind: kind),
                       selection?.timelineClipID == clipID {
                        selection?.layerID = newLayer
                    }
                },
                onDropScenes: { payloads, layerID, time, kind in dropScenes(payloads, onLayer: layerID, at: time, kind: kind) },
                onApplyJointEdit: { layerID, clipID, edit in
                    project.applyJointEdit(edit, at: clipID, in: timelineID, layer: layerID)
                },
                onTrimClipStart: { layerID, clipID, newTrimStart in
                    project.trimClipStart(clipID, in: timelineID, layer: layerID, to: newTrimStart)
                },
                onTrimClipEnd: { layerID, clipID, newTrimEnd in
                    project.trimClipEnd(clipID, in: timelineID, layer: layerID, to: newTrimEnd)
                },
                onEditVolume: { layerID, change in
                    project.editVolume(of: layerID, in: timelineID, change)
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
                onSelectLayer: { selection = nil },
                onDeleteClip: { layerID, clipID in
                    project.deleteClip(clipID, in: timelineID, layer: layerID)
                    selection = nil
                },
                onDeleteLayer: { layerID in
                    project.deleteLayer(layerID, in: timelineID)
                    if selection?.layerID == layerID { selection = nil }
                },
                onBladeClip: { layerID, clipID, time in
                    project.split(clipID, in: timelineID, layer: layerID, atTimelineTime: time)
                },
                onSlipClip: { layerID, clipID, delta in
                    project.slipClip(clipID, in: timelineID, layer: layerID, by: delta)
                },
                onTrimPreview: { clip in showTrimPreview(of: clip) },
                onSetTransitionDuration: { layerID, clipID, edge, duration in
                    project.setTransitionDuration(duration, at: edge, of: clipID, in: timelineID, layer: layerID)
                },
                onEditProject: { change in change(&project) },
                showsTransitions: $showsTransitions,
                showsEffects: $showsEffects,
                showsMeter: $showsMeter,
                effectsState: effectsState
            )
        } else {
            ContentUnavailableView("No Timeline Selected", systemImage: "timeline.selection")
        }
    }

    /// Scenes dragged from the browser become ordinary clips, back to back.
    /// Dropped on a layer they go onto it at the drop time, if they fit and
    /// it is the right kind; otherwise, or dropped elsewhere, onto a new
    /// layer at the top, of `kind` or the asset's default kind.
    private func dropScenes(_ payloads: [SceneDragPayload], onLayer layerID: UUID?, at time: CMTime, kind: LayerKind? = nil) -> Bool {
        var firstClip: (layerID: UUID, clipID: UUID)?
        for payload in payloads {
            if let layerID,
               let added = project.addScenes(payload.scenes, ofAsset: payload.assetID, intoLayer: layerID, in: timelineID, at: time) {
                if firstClip == nil, let clipID = added.first { firstClip = (layerID, clipID) }
            } else if let result = project.addScenes(payload.scenes, ofAsset: payload.assetID, intoTimeline: timelineID, at: time, kind: kind),
                      firstClip == nil, let clipID = result.clipIDs.first {
                firstClip = (result.layerID, clipID)
            }
        }
        guard let firstClip else { return false }
        selection = TimelineSelection(timelineID: timelineID, layerID: firstClip.layerID, timelineClipID: firstClip.clipID)
        return true
    }

    // MARK: -

    /// Shows a slipped clip's first and last frames over the viewer, or
    /// stops with nil. Only clips with pictures from a file have frames.
    private func showTrimPreview(of clip: TimelineClip?) {
        guard let clip, let timeline, case .media(let mediaID) = clip.source,
              let media = project.mediaClip(id: mediaID), media.kind == .video, let url = media.url
        else {
            trimPreview.clear()
            return
        }
        let last = CMTimeMaximum(clip.trimStart, CMTimeSubtract(clip.trimEnd, timeline.frameDuration))
        trimPreview.show(
            url: url,
            first: media.fileTime(forSourceTime: clip.trimStart),
            last: media.fileTime(forSourceTime: last),
            labelFirst: clip.trimStart,
            labelLast: last
        )
    }

    /// Scrubbing moves the shared playhead and seeks the player directly —
    /// the player always shows the whole composited timeline (every layer
    /// stacked together), not just one selected clip, so no per-clip time
    /// translation is needed here.
    private func scrub(to time: CMTime) {
        renderer?.noteActivity()
        playheadTime = time
        playback.seek(to: time)
    }

    /// Rebuilds the player item from the current project. Keeps the
    /// position and play state the player has when the build *finishes*,
    /// not when it started, so edits made during playback don't jump back.
    private func rebuildPlayerItem(resetPosition: Bool = false) {
        buildTask?.cancel()
        guard let timeline, timeline.layers.contains(where: { !$0.clips.isEmpty }) else {
            playback.player.replaceCurrentItem(with: nil)
            buildError = nil
            renderer?.update(project: project, timelineID: timelineID, segments: [])
            return
        }
        let project = self.viewedProject
        let isPartial = partialView != nil
        let realProject = self.project
        let tID = timelineID
        let player = playback.player
        let playback = playback
        let frameRate = timeline.frameRate
        let renderer = renderer
        buildTask = Task {
            do {
                let composed = try await CompositionExporter.buildComposedTimeline(
                    for: project, timelineID: tID, forPreview: true, meter: playback.meter, cache: isPartial ? nil : renderer?.cache
                )
                guard !Task.isCancelled else { return }
                // A clip cut short isn't what renders are for.
                renderer?.update(project: realProject, timelineID: tID, segments: isPartial ? [] : composed.segments)
                let item = AVPlayerItem(asset: composed.composition)
                playback.prepare(item, with: composed, frameRate: frameRate)
                if player.timeControlStatus == .paused {
                    // Seeked before it's shown, so the swap doesn't flash
                    // the item's first frame, as when a render finishes.
                    // `PlayerContainerView` covers the gap until it draws.
                    let resumeTime = resetPosition ? playheadTime : player.currentTime()
                    _ = await item.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    guard !Task.isCancelled else { return }
                    player.replaceCurrentItem(with: item)
                } else {
                    let resumeTime = resetPosition ? playheadTime : player.currentTime()
                    player.replaceCurrentItem(with: item)
                    _ = await player.seek(to: resumeTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                }
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
    @State private var isHovering = false

    private var isActive: Bool { isHovering || dragStartHeight != nil }

    var body: some View {
        // A grip rather than a bare line: the seam between the viewer and
        // the timeline is the one divider in the window that moves, so it
        // says so.
        ZStack {
            Design.Surface.raised.color
            Capsule()
                .fill(isActive ? Design.textSecondary : Design.textTertiary.opacity(0.55))
                .frame(width: isActive ? 44 : 28, height: 3)
        }
        .frame(height: 9)
        .overlay(alignment: .top) { Design.hairline.frame(height: 1) }
        .overlay(alignment: .bottom) { Design.hairline.frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .editorAnimation(Design.Motion.select, value: isActive)
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

/// The strip along the effects panel's left edge that resizes it.
struct EffectsPanelResizeHandle: View {
    static let minimumWidth: CGFloat = 480

    @Binding var width: Double
    let maxWidth: CGFloat
    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(max(start - Double(value.translation.width), Double(Self.minimumWidth)), Double(maxWidth))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help("Drag to resize the effects panel")
    }
}
