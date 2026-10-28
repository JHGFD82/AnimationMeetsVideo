import AppKit
import CoreMedia
import SwiftUI

/// The timeline's areas: how tall each layer's rows are, and each area's
/// layer headers beside their tracks, scrolling up and down on its own.
extension TimelineView {
    // MARK: - Heights

    /// The joining transition whose footage is open on this layer.
    private func shownJoint(in layer: TimelineLayer) -> TransitionJoint? {
        guard let id = expandedJoint, layer.clips.contains(where: { $0.id == id }) else { return nil }
        return project.joint(at: id, in: timelineID, layer: layer.id)
    }

    /// Whether an open joint has a sound lane, to choose how the sound
    /// crossfades: either clip's sound is still attached to its picture. A
    /// transition of sound has its kind's shape, and no lane.
    private func jointHasSound(_ joint: TransitionJoint) -> Bool {
        !joint.transition.kind.isAudio && (project.playsAudio(joint.outgoing) || project.playsAudio(joint.incoming))
    }

    /// The height of what an expanded transition opens under its layer:
    /// its footage, and its sound when it has some.
    private func expandedJointHeight(of layer: TimelineLayer) -> CGFloat {
        guard let joint = shownJoint(in: layer) else { return 0 }
        return TransitionFootageLane.height + (jointHasSound(joint) ? TransitionSoundLane.height : 0)
    }

    /// Everything one layer shows, top to bottom. The header column and the
    /// track area lay out the same rows, so this is each layer's height in
    /// both.
    func blockHeight(of layer: TimelineLayer) -> CGFloat {
        clipRowHeight(of: layer)
            + expandedJointHeight(of: layer)
            + (showsLinkedAudio(of: layer) ? audioLaneHeight(of: layer) : 0)
            + (showsVolume(of: layer) ? VolumeLane.height : 0)
            + separatorHeight
    }

    /// The layers an area shows, top to bottom.
    func areaLayers(_ kind: LayerKind) -> [TimelineLayer] {
        timeline.layers.filter { $0.kind == kind }
    }

    /// Where each of `layers` starts, from the top of its area.
    func tops(of layers: [TimelineLayer]) -> [CGFloat] {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for layer in layers {
            tops.append(y)
            y += blockHeight(of: layer)
        }
        return tops
    }

    /// Linked audio is shown under video, at a little over half its height,
    /// or tall enough for two channels when they're shown apart.
    private func audioLaneHeight(of layer: TimelineLayer) -> CGFloat {
        let lane = max(22, (shownAreaLayout.height(of: layer.id, kind: layer.kind) * 0.6).rounded())
        return showsChannels(of: layer) ? max(lane, Self.channelBandHeight) * 2 : lane
    }

    private func showsLinkedAudio(of layer: TimelineLayer) -> Bool {
        audioRevealed.contains(layer.id) && project.layerHasLinkedAudio(layer)
    }

    /// The shortest band one channel gets when a layer shows them apart.
    private static let channelBandHeight: CGFloat = 32

    /// Whether the layer's sound has channels to show apart: sound layers
    /// always, video layers while their linked audio is shown.
    private func canShowChannels(of layer: TimelineLayer) -> Bool {
        layer.kind == .video ? showsLinkedAudio(of: layer) : true
    }

    private func showsChannels(of layer: TimelineLayer) -> Bool {
        channelsRevealed.contains(layer.id) && canShowChannels(of: layer)
    }

    /// Adjustment layers' one fixed height: their clips have no picture or
    /// sound to show, only a name, so they aren't resized.
    static let adjustmentRowHeight: CGFloat = 28

    /// The clips' row: the layer's height, doubled (with a floor) on sound
    /// layers showing their channels, so each gets a band. Adjustment
    /// layers are always `adjustmentRowHeight`.
    func clipRowHeight(of layer: TimelineLayer) -> CGFloat {
        if layer.isAdjustment { return Self.adjustmentRowHeight }
        let height = shownAreaLayout.height(of: layer.id, kind: layer.kind)
        guard layer.kind != .video, showsChannels(of: layer) else { return height }
        return max(height, Self.channelBandHeight) * 2
    }

    /// Wider while a volume row is showing, to fit its values.
    var labelColumnWidth: CGFloat {
        timeline.layers.contains { showsVolume(of: $0) } ? 300 : 150
    }

    func showsVolume(of layer: TimelineLayer) -> Bool {
        volumeRevealed.contains(layer.id) && hasProperties(layer)
    }

    /// Whether the layer's clips draw their volume across them: while L is
    /// on, for every layer with sound.
    private func showsVolumeLines(of layer: TimelineLayer) -> Bool {
        volumeRevealed.contains(layer.id) && project.layerPlaysAudio(layer)
    }

    /// Whether the layer has a volume row to show: Sound and Music layers
    /// have a layer volume, video layers only their clips'.
    private func hasProperties(_ layer: TimelineLayer) -> Bool {
        layer.kind.isAudio && project.layerPlaysAudio(layer)
    }

    // MARK: - Actions

    // The host's actions as the closures the rows take, typed, so the
    // rows' long initializers don't have to infer them.

    private var scrubAction: (CMTime) -> Void {
        { [host] time in host.dispatch(.scrub(time)) }
    }

    private var openTimelineAction: (UUID) -> Void {
        { [host] id in host.dispatch(.openTimeline(id)) }
    }

    private var sceneTracksAction: () -> [UUID: ChangeScoreTrack] {
        { [host] in host.sceneTracks() }
    }

    private var trimPreviewAction: (TimelineClip?, TrimPreviewFrames) -> Void {
        { [host] clip, frames in host.dispatch(.trimPreview(clip, frames)) }
    }

    // MARK: - Areas

    /// One area: its layers' names beside their tracks, scrolling up and
    /// down on its own.
    func area(
        _ kind: LayerKind, height: CGFloat, viewport: TimelineViewport, structure: EditingProject
    ) -> some View {
        ScrollViewReader { scroller in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    layerHeaders(kind)
                        .frame(width: labelColumnWidth, alignment: .topLeading)
                        .frame(minHeight: height, alignment: .top)
                        .grooved(.trailing)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            geometryStore.headerColumns[kind] = frame
                        }
                        // Media from the library dropped on the names goes on
                        // a new layer of the kind under the pointer.
                        .onDrop(of: [.text], delegate: NewLayerDropDelegate(
                            column: { geometryStore.namesColumn },
                            viewFrame: { geometryStore.headerColumns[kind] ?? .zero },
                            isAudio: { project.mediaClip(id: $0)?.kind == .audio },
                            onHover: { hover in if hover != newLayerHover { newLayerHover = hover } },
                            onDrop: { payloads, kind in _ = host.dropScenes(payloads, onLayer: nil, at: playheadTime, kind: kind) }
                        ))
                    layerTracks(kind, areaHeight: height, viewport: viewport, structure: structure)
                        .overlay(alignment: .topLeading) { focusHighlight(kind, pixelsPerSecond: viewport.pixelsPerSecond) }
                        .offset(x: -viewport.scrollX)
                        .frame(width: viewport.width, alignment: .topLeading)
                        .rubberBandStretch(viewportModel.zoomBand)
                        .rubberBandScroll(viewportModel.scrollBand, length: viewportModel.trackAreaWidth)
                        .clipped()
                        // Clipping hides what is scrolled out of sight but
                        // still lets it take clicks, and to the left that is
                        // over the names: a transition's footage lane, as
                        // wide as the timeline, hid the Done beside it.
                        .contentShape(Rectangle())
                }
                .overlay(alignment: .topLeading) { layerDropIndicator(kind) }
                .edgeAutoScroll(areaScroller(kind))
            }
            // A clip focused from Find All comes to the middle of its area,
            // once its highlight is laid out to scroll to. Only the area
            // holding it has the ID.
            .onChange(of: highlightedFocus?.id) { _, id in
                guard let id else { return }
                Task { scroller.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: height)
        // A vertical pinch past the layer heights stretches this area.
        .rubberBandStretch(
            viewportModel.layerHeightBandKind == kind ? viewportModel.layerHeightBand : RubberBandZoom(), axis: .vertical
        )
        .clipped()
        .sunken(.sunken)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            geometryStore.areas[kind] = frame
        }
    }

    private func layerHeaders(_ kind: LayerKind) -> some View {
        let layers = areaLayers(kind)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                let isDragged = layerDrag?.id == layer.id
                VStack(alignment: .leading, spacing: 0) {
                    LayerHeaderRow(
                        number: index + 1,
                        layer: layer,
                        displayName: project.displayName(of: layer, in: timeline),
                        height: clipRowHeight(of: layer),
                        canMoveUp: index > 0,
                        canMoveDown: index < layers.count - 1,
                        isExpanded: hasProperties(layer) ? showsVolume(of: layer) : nil,
                        onToggleExpanded: { toggleExpanded(layer) },
                        isAudioExpanded: project.layerHasLinkedAudio(layer) ? showsLinkedAudio(of: layer) : nil,
                        onToggleAudio: { toggleLinkedAudio(layer) },
                        onDetachAudio: { host.dispatch(TimelineAction.detachAudio(layer: layer.id, clips: nil)) },
                        isChannelsExpanded: canShowChannels(of: layer) ? showsChannels(of: layer) : nil,
                        onToggleChannels: { toggleChannels(layer) },
                        onRename: { name in host.dispatch(TimelineAction.renameLayer(layer.id, name)) },
                        onMove: { offset in host.dispatch(TimelineAction.moveLayer(layer.id, offset)) },
                        onDragChanged: { dy in dragLayer(layer, by: dy) },
                        onDragEnded: { dy in endLayerDrag(layer.id, dy: dy + areaScroller(layer.kind).scrolled) },
                        isSelected: selectedLayerID == layer.id,
                        onSelect: {
                            selectedLayerID = layer.id
                            selectedSectionID = nil
                            groupSelection = []
                            host.dispatch(TimelineAction.selectLayer)
                        },
                        onDelete: { deleteLayer(layer.id) }
                    )
                    .equatable()
                    if let joint = shownJoint(in: layer) {
                        jointHeader(joint, on: layer)
                    }
                    if showsLinkedAudio(of: layer) {
                        Label("Linked audio", systemImage: "waveform")
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.textSecondary)
                            .padding(.leading, 30)
                            .frame(height: audioLaneHeight(of: layer), alignment: .leading)
                            .contextMenu {
                                Button("Detach Audio") { host.dispatch(TimelineAction.detachAudio(layer: layer.id, clips: nil)) }
                            }
                    }
                    if showsVolume(of: layer) {
                        volumeHeader(of: layer)
                    }
                    separator
                }
                .overlay(alignment: .bottom) {
                    // Adjustment layers keep one height.
                    if !layer.isAdjustment {
                        LayerResizeDivider(
                            onChanged: { dy, flags in resizeLayer(layer, by: dy, flags: flags) },
                            onEnded: { layerResize = nil },
                            onStep: { step in
                                areaLayout.setHeight(areaLayout.height(of: layer.id, kind: layer.kind) + step, of: layer.id, kind: layer.kind)
                            }
                        )
                        .offset(y: LayerResizeDivider.hitHeight / 2)
                    }
                }
                // Alternating tone, faint enough to read as banding rather
                // than as two kinds of layer. With the grooves it is what
                // keeps a tall stack of layers legible at a glance.
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.018))
                .background(Design.Surface.base.color)
                .background(isDragged ? Design.accent.opacity(0.18) : .clear)
                .shadow(color: .black.opacity(isDragged ? 0.45 : 0), radius: 6, y: 2)
                .offset(y: isDragged ? layerDrag?.dy ?? 0 : 0)
                .zIndex(isDragged ? 1 : 0)
            }
            Color.clear.frame(height: newLayerRowHeight)
        }
    }

    /// What an open joint shows beside its footage, and its sound when it
    /// has some: what they are, and the sound's crossfade.
    @ViewBuilder
    private func jointHeader(_ joint: TransitionJoint, on layer: TimelineLayer) -> some View {
        HStack {
            Label(joint.transition.kind.isAudio ? "Transition audio" : "Transition video", systemImage: "square.on.square.dashed")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
            Spacer()
            Button("Done") { expandedJoint = nil }
                .controlSize(.small)
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .frame(height: TransitionFootageLane.height)
        if jointHasSound(joint) {
            HStack {
                Label("Transition audio", systemImage: "waveform")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                Spacer()
                Menu(joint.transition.audioCrossfade?.name ?? "Project (\(project.jointAudioCrossfade.name))") {
                    TransitionSoundLane.choices(
                        selected: joint.transition.audioCrossfade, project: project.jointAudioCrossfade,
                        onSet: { host.dispatch(TimelineAction.applyJointEdit(layer: layer.id, clip: joint.incoming.id, JointEdit.soundCrossfade($0))) }
                    )
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("The shape the two clips' sound crossfades with. Its timing follows the transition.")
                .accessibilityLabel("Sound crossfade shape")
            }
            .padding(.leading, 30)
            .padding(.trailing, 8)
            .frame(height: TransitionSoundLane.height)
        }
    }

    /// The layer volume's row in the names column.
    private func volumeHeader(of layer: TimelineLayer) -> some View {
        AudioPropertyRow(
            value: layer.volume,
            playhead: PlayheadTime(playhead) { timeline.snappedToFrame($0) },
            // The host applies the change before `dispatch` returns, so
            // the action needn't keep it.
            onEdit: { change in
                withoutActuallyEscaping(change) { host.dispatch(TimelineAction.editVolume(layer: layer.id, $0)) }
            },
            onSeek: scrubAction,
            onShowGraph: graphs.map { graphs in
                { graphs.show(ParameterKey(timelineID: timelineID, parameter: .layerVolume(layerID: layer.id))) }
            },
            held: { projectState?.held?.timeline(id: timelineID)?.layer(id: layer.id)?.volume }
        )
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .frame(height: VolumeLane.height)
    }

    /// Resizes a layer from its names-column divider, `dy` from where the
    /// drag began: the layer alone, with Option every layer of its area,
    /// with Option-Shift every shown layer, all to the same height.
    private func resizeLayer(_ layer: TimelineLayer, by dy: CGFloat, flags: NSEvent.ModifierFlags) {
        if layerResize?.id != layer.id {
            layerResize = (layer.id, areaLayout.height(of: layer.id, kind: layer.kind))
        }
        guard let start = layerResize?.startHeight else { return }
        // A layer showing its channels draws its row twice as tall.
        let height = start + dy / (layer.kind != .video && showsChannels(of: layer) ? 2 : 1)
        if flags.contains(.option), flags.contains(.shift) {
            areaLayout.setHeightOfAllShown(height, layers: timeline.layers.map(\.id))
        } else if flags.contains(.option) {
            areaLayout.setHeightOfAll(height, kind: layer.kind, layers: areaLayers(layer.kind).map(\.id))
        } else {
            areaLayout.setHeight(height, of: layer.id, kind: layer.kind)
        }
    }

    /// A box under each adjustment clip, spanning its time and reaching
    /// down over the layers it adjusts (those in the same area), so what an
    /// adjustment affects can be read off the timeline. Brighter while the
    /// clip is selected; dashed around the clip alone when the layer it
    /// reaches down to is above it.
    private func reachBoxes(of layers: [TimelineLayer], pixelsPerSecond: CGFloat) -> some View {
        let tops = tops(of: layers)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                if layer.isAdjustment {
                    ForEach(layer.clips) { clip in
                        let reached = project.reachedLayers(of: clip, on: layer, in: timeline)
                        let bottom = reached.compactMap { target in layers.firstIndex(id: target.id) }.max() ?? index
                        let isSelected = selection?.timelineClipID == clip.id
                        let tone = Design.ClipTone.adjustment.color
                        let shape = RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        let y0 = tops[index]
                        let y1 = tops[bottom] + blockHeight(of: layers[bottom]) - separatorHeight
                        shape
                            .fill(tone.opacity(reached.isEmpty ? 0 : isSelected ? 0.12 : 0.06))
                            .overlay {
                                shape.strokeBorder(
                                    tone.opacity(reached.isEmpty ? 0.4 : isSelected ? 0.95 : 0.55),
                                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: reached.isEmpty ? [4, 3] : [])
                                )
                            }
                            .frame(
                                width: max(2, CGFloat(CMTimeSubtract(clip.endOffset, clip.startOffset).seconds) * pixelsPerSecond),
                                height: max(4, y1 - y0)
                            )
                            .offset(x: clip.startOffset.seconds * pixelsPerSecond, y: y0)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Carries out `edit` of a clip and says whether it was made: whether
    /// the clip, or the layer it is on, is different afterwards. The host
    /// applies an edit before `dispatch` returns, so the project read back
    /// has it; one it refused leaves the clip as it was.
    func clipEdit(_ clipID: UUID, _ edit: () -> Void) -> Bool {
        let before = host.readProject().clipAndLayer(clipID, in: timelineID)
        edit()
        let after = host.readProject().clipAndLayer(clipID, in: timelineID)
        return before?.clip != after?.clip || before?.layer.id != after?.layer.id
    }

    /// A fixed-height groove between layers, so the two columns line up and
    /// layer positions can be worked out for dragging.
    private var separator: some View {
        Groove(subtle: true)
            .frame(height: separatorHeight)
    }

    /// Every layer's clips and keyframe lanes, laid out across the whole
    /// span in unscrolled coordinates; the caller shifts them into view.
    private func layersHeight(_ kind: LayerKind) -> CGFloat {
        areaLayers(kind).reduce(0) { $0 + blockHeight(of: $1) }
    }

    /// `structure` is `project.structure`, which the rows compare.
    private func layerTracks(
        _ kind: LayerKind, areaHeight: CGFloat, viewport: TimelineViewport, structure: EditingProject
    ) -> some View {
        let pixelsPerSecond = viewport.pixelsPerSecond
        let contentWidth = viewport.contentWidth
        let snapTolerance = snapTolerance(viewport)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(areaLayers(kind).enumerated()), id: \.element.id) { index, layer in
                VStack(spacing: 0) {
                    LayerClipRow(
                        layer: layer,
                        name: project.displayName(of: layer, in: timeline),
                        frameRate: timeline.frameRate,
                        project: project,
                        structure: structure,
                        timelineID: timelineID,
                        selection: selection,
                        groupSelected: groupSelection.isEmpty ? [] : groupSelection.intersection(layer.clips.map(\.id)),
                        onToggleGroup: { toggleInGroup($0) },
                        onOpenTimeline: openTimelineAction,
                        pixelsPerSecond: pixelsPerSecond,
                        width: contentWidth,
                        height: clipRowHeight(of: layer),
                        showsChannels: layer.kind != .video && showsChannels(of: layer),
                        visibleX: viewport.visibleContentX,
                        expandedJoint: expandedJoint,
                        onSelectClip: { clip in host.dispatch(TimelineAction.selectClip(layer: layer.id, clip: clip)) },
                        resolveMove: { clip, pointer, start in resolveMove(clip, from: layer.id, pointer: pointer, to: start) },
                        onMoveClip: { clipID, target, newStart in
                            clipEdit(clipID) { host.dispatch(TimelineAction.moveClip(layer: layer.id, clip: clipID, toLayer: target, start: newStart)) }
                        },
                        onMoveClipToNewLayer: { clipID, kind, start in
                            newLayerHover = nil
                            return clipEdit(clipID) {
                                host.dispatch(TimelineAction.moveClipToNewLayer(layer: layer.id, clip: clipID, kind: kind, start: start))
                            }
                        },
                        onDraggingClip: { dragging in draggingClipLayerID = dragging ? layer.id : nil },
                        pushed: pushedClips.flatMap { $0.layerID == layer.id ? $0.clips : nil } ?? [:],
                        onMovePreview: { preview in showMovePreview(preview, from: layer.id) },
                        onDropScenes: { payloads, time in host.dropScenes(payloads, onLayer: layer.id, at: time, kind: nil) },
                        onEditJoint: { clipID in
                            expandedJoint = clipID
                            if let clip = layer.clips.first(id: clipID) {
                                host.dispatch(TimelineAction.selectTransition(layer: layer.id, clip: clip, .leading))
                            }
                        },
                        onTrimClipStart: { clipID, newStart in
                            clipEdit(clipID) { host.dispatch(TimelineAction.trimClipStart(layer: layer.id, clip: clipID, newStart)) }
                        },
                        onTrimClipEnd: { clipID, newEnd in
                            clipEdit(clipID) { host.dispatch(TimelineAction.trimClipEnd(layer: layer.id, clip: clipID, newEnd)) }
                        },
                        sceneTracks: sceneTracksAction,
                        onSetTransition: { clipID, kind, edge in host.dispatch(TimelineAction.setTransition(layer: layer.id, clip: clipID, kind, edge)) },
                        onRemoveTransition: { clipID, edge in host.dispatch(TimelineAction.removeTransition(layer: layer.id, clip: clipID, edge)) },
                        onSelectTransition: { clip, edge in host.dispatch(TimelineAction.selectTransition(layer: layer.id, clip: clip, edge)) },
                        onSetTransitionCurve: { clipID, edge, curve in host.dispatch(TimelineAction.setTransitionCurve(layer: layer.id, clip: clipID, edge, curve)) },
                        onDetachAudio: { clipID in host.dispatch(TimelineAction.detachAudio(layer: layer.id, clips: [clipID])) },
                        tool: tool,
                        snap: { timeline.snappedToFrame($0) },
                        onBlade: { clipID, time in host.dispatch(TimelineAction.bladeClip(layer: layer.id, clip: clipID, at: time)) },
                        onSlip: { clipID, delta in
                            clipEdit(clipID) { host.dispatch(TimelineAction.slipClip(layer: layer.id, clip: clipID, by: delta)) }
                        },
                        liveSnap: liveSnap,
                        snapTolerance: snapTolerance,
                        onSnapIndicator: { viewportModel.snapIndicator = $0 },
                        onTrimPreview: trimPreviewAction,
                        onApplyJointEdit: { clipID, edit in host.dispatch(TimelineAction.applyJointEdit(layer: layer.id, clip: clipID, edit)) },
                        onSetTransitionDuration: { clipID, edge, duration in host.dispatch(TimelineAction.setTransitionDuration(layer: layer.id, clip: clipID, edge, duration)) },
                        onAddEffect: { clipID, kind in
                            host.dispatch(TimelineAction.editProject { $0.addEffect(kind, toClip: clipID, in: timelineID) })
                        },
                        onApplyPreset: { clipID, presetID in
                            guard let preset = try? PresetStore.read(PresetStore.fileURL(presetID)) else { return }
                            host.dispatch(TimelineAction.editProject { $0.paste(preset.bundle, ontoClip: clipID, in: timelineID) })
                        },
                        onPasteEffects: { clipID in
                            let clipboard = EditorClipboard.shared
                            host.dispatch(TimelineAction.editProject { project in
                                // Effects are added to what the clip has; its
                                // time and shutter are replaced if different.
                                if let bundle = clipboard.effects { project.paste(bundle, ontoClip: clipID, in: timelineID) }
                                if let source = clipboard.clip?.clip { project.pasteTimeAndShutter(of: source, ontoClip: clipID, in: timelineID) }
                            })
                        },
                        onClipboard: { clipID, command in clipboard(command, layerID: layer.id, clipID: clipID) },
                        onCopyClip: { clipID, start, target, kind in copyClip(clipID, from: layer.id, to: start, onto: target, newLayer: kind) },
                        onDropFiles: { urls, time in host.dropFiles(urls, onLayer: layer.id, at: time, kind: layer.kind) },
                        onDropGenerator: { kind, time in addGenerator(kind, above: layer.id, at: time) },
                        onSetPassThrough: { clipID, value in
                            host.dispatch(TimelineAction.editProject { $0.editClip(clipID, in: timelineID) { $0.passThrough = value } })
                        },
                        showsVolumeLines: showsVolumeLines(of: layer),
                        // The host applies an edit before `dispatch`
                        // returns, so it needn't keep `change`.
                        onEditTime: { clipID, change in
                            withoutActuallyEscaping(change) { change in
                                host.dispatch(TimelineAction.editProject { $0.editTime(ofClip: clipID, in: timelineID, layer: layer.id, change) })
                            }
                        },
                        onEditClip: { clipID, change in
                            withoutActuallyEscaping(change) { change in
                                host.dispatch(TimelineAction.editProject { $0.editClip(clipID, in: timelineID, change) })
                            }
                        },
                        onSetReach: { clipID, bottom in
                            host.dispatch(TimelineAction.editProject { $0.setReach(ofClip: clipID, in: timelineID, toLayer: bottom) })
                        },
                        onAttachToMusic: { clipID, at in
                            let time = at ?? livePlayheadTime
                            host.dispatch(TimelineAction.editProject { $0.attachToMusic(clipID, in: timelineID, at: time) })
                        },
                        musicMarks: layer.kind == .music ? selectedMusicMarks : [:],
                        onMotionDesign: { clipID in
                            let ids = groupSelection.contains(clipID) ? groupSelection : [clipID]
                            motionDesign?.open(clips: ids, in: timelineID, of: project)
                        },
                        onConformTimeline: { clip in conformTimeline(to: clip) }
                    )
                    // Rows that would draw the same aren't redrawn, so
                    // dragging one clip's value redraws only its layer.
                    .equatable()
                    // Recorded for drags that cross areas; see
                    // `TimelineGeometryStore`.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        geometryStore.layerRows[layer.id] = frame
                    }
                    if let joint = shownJoint(in: layer) {
                        TransitionFootageLane(
                            joint: joint,
                            frameRate: timeline.frameRate,
                            outgoingName: project.resolvedInfo(for: joint.outgoing.source)?.name ?? "Clip",
                            incomingName: project.resolvedInfo(for: joint.incoming.source)?.name ?? "Clip",
                            pixelsPerSecond: pixelsPerSecond,
                            width: contentWidth,
                            visibleX: viewport.visibleContentX,
                            preview: { edit in
                                var copy = project
                                copy.applyJointEdit(edit, at: joint.incoming.id, in: timelineID, layer: layer.id)
                                return copy.joint(at: joint.incoming.id, in: timelineID, layer: layer.id)
                            },
                            onCommit: { edit in host.dispatch(TimelineAction.applyJointEdit(layer: layer.id, clip: joint.incoming.id, edit)) },
                            tool: tool,
                            onTrimPreview: trimPreviewAction
                        )
                        if jointHasSound(joint) {
                            TransitionSoundLane(
                                joint: joint,
                                projectCrossfade: project.jointAudioCrossfade,
                                pixelsPerSecond: pixelsPerSecond,
                                width: contentWidth,
                                onSetCrossfade: { host.dispatch(TimelineAction.applyJointEdit(layer: layer.id, clip: joint.incoming.id, JointEdit.soundCrossfade($0))) }
                            )
                        }
                    }
                    if showsLinkedAudio(of: layer) {
                        LinkedAudioLane(
                            layer: layer,
                            project: project,
                            pixelsPerSecond: pixelsPerSecond,
                            width: contentWidth,
                            height: audioLaneHeight(of: layer),
                            showsChannels: showsChannels(of: layer),
                            visibleX: viewport.visibleContentX,
                            onSelectClip: { clip in host.dispatch(TimelineAction.selectClip(layer: layer.id, clip: clip)) },
                            onDetachAudio: { clipID in host.dispatch(TimelineAction.detachAudio(layer: layer.id, clips: [clipID])) }
                        )
                    }
                    if showsVolume(of: layer) {
                        PlayheadReader(playhead: playhead) { parked in
                            VolumeLane(
                                volume: layer.volume,
                                currentTime: timeline.snappedToFrame(parked),
                                pixelsPerSecond: pixelsPerSecond,
                                width: contentWidth,
                                visibleX: viewport.visibleContentX,
                                snap: { timeline.snappedToFrame($0) },
                                onSeek: scrubAction,
                                onMove: { from, to, copy in host.dispatch(TimelineAction.editVolume(layer: layer.id) { $0.moveKeyframe(at: from, to: to, copying: copy) }) },
                                onDelete: { time in host.dispatch(TimelineAction.editVolume(layer: layer.id) { $0.removeKeyframe(at: time) }) },
                                onEase: { time, preset in host.dispatch(TimelineAction.editVolume(layer: layer.id) { $0.applyEase(preset, at: time) }) }
                            )
                        }
                    }
                    separator
                }
                // The same banding as the header column, so a layer reads
                // as one band all the way across the window.
                .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.018))
                .zIndex(draggingClipLayerID == layer.id ? 1 : 0)
            }
            // Fills the rest of the area, so media dropped anywhere below the
            // layers (or in an empty area) gets a new layer of its kind.
            NewLayerDropRow(height: max(newLayerRowHeight, areaHeight - layersHeight(kind)), kind: kind) { payloads, x in
                host.dropScenes(payloads, onLayer: nil, at: CMTime(seconds: max(0, Double(x / pixelsPerSecond)), preferredTimescale: 600), kind: kind)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .overlay(alignment: .topLeading) { reachBoxes(of: areaLayers(kind), pixelsPerSecond: pixelsPerSecond) }
        // A generator (text or a shape) from the browser dropped on the
        // video area, but not on a clip (which handles it itself), makes a
        // clip where it lands: on the layer under it, or on a new layer at
        // the top below the layers. Browser generators travel as URLs,
        // media as text, so this doesn't catch media.
        .dropDestination(for: ClipDropPayload.self) { payloads, location in
            let time = CMTime(seconds: max(0, Double(location.x / pixelsPerSecond)), preferredTimescale: 600)
            let files = payloads.compactMap(\.file)
            if !files.isEmpty {
                host.dropFiles(files, onLayer: nil, at: time, kind: kind)
                return true
            }
            guard kind == .video, let generator = payloads.first?.generator?.kind else { return false }
            let layers = areaLayers(kind)
            let under = zip(layers, tops(of: layers)).first { layer, top in
                location.y >= top && location.y < top + blockHeight(of: layer)
            }
            addGenerator(generator, onLayer: under?.0.id, at: time)
            return true
        }
    }
}
