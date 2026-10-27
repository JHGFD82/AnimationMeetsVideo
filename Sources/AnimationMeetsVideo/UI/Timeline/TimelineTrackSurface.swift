import CoreMedia
import SwiftUI

/// Everything under the timeline's header: the time rail, the areas, and
/// what is drawn across them. A view of its own so that it, and the views
/// it hands the viewport to, are the ones that follow the zoom and the
/// scroll (`TimelineViewportModel`): a step of a scroll, a pinch or a
/// bounce runs their bodies, not `TimelineView`'s.
struct TimelineTrackSurface: View {
    let parent: TimelineView
    let geometry: GeometryProxy

    var body: some View {
        parent.trackSurface(in: geometry)
    }
}

extension TimelineView {
    @ViewBuilder
    func trackSurface(in geometry: GeometryProxy) -> some View {
        let trackWidth = geometry.size.width - labelColumnWidth
        let viewport = viewport(width: trackWidth)
        let scrollbarHeight = viewport.maxScrollX > 0 ? TimelineScrollbar.height : 0
        let shownAreas = areaLayout.shown
        let railHeight = rulerHeight + (areaLayout.showsSections ? SectionLane.height : 0) + separatorHeight
        // Whatever height the timeline is given goes to the areas,
        // split by their shares: a taller timeline shows more
        // layers, it doesn't make them taller.
        let areasAvailable = max(0, geometry.size.height - railHeight - scrollbarHeight
            - CGFloat(shownAreas.count) * AreaTitleBar.height)
        let areaHeights = areaLayout.heights(splitting: areasAvailable)
        let trackHeight = max(railHeight, geometry.size.height - scrollbarHeight)
        // Once for every area's rows, which compare it to skip
        // redrawing; without where this timeline's clips are, which
        // a row's actions read as they act (`liveSnap`, `resolveMove`).
        // Kept until the project is edited.
        let structure = derived.structure(of: project, withoutClipsIn: timelineID)
        // What edges snap to, built once per edit or zoom, not once per
        // area: it walks every clip and beat. The playhead is read as a
        // drag snaps, so moving it doesn't change what the rows compare.
        let snapKey = SnapKey(
            editCount: project.editCount, timelineID: timelineID, snapping: snapping,
            pixelsPerSecond: viewport.pixelsPerSecond, markers: snapping ? drawnBeats(viewport) : []
        )

        VStack(alignment: .leading, spacing: 0) {
            // The time rail: the ruler and the sections under it
            // are one raised assembly, lit along its top, and the
            // only part of the timeline that stands proud of the
            // track area below.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    TimelineColumnHeaderRow(height: rulerHeight)
                        .frame(width: labelColumnWidth, alignment: .leading)
                    TimelineRulerLane(parent: self, width: trackWidth)
                }
                if areaLayout.showsSections {
                    HStack(spacing: 0) {
                        Text("Sections")
                            .font(Design.Typeface.micro)
                            .foregroundStyle(Design.textTertiary)
                            .padding(.leading, Design.Space.step)
                            .frame(width: labelColumnWidth, height: SectionLane.height, alignment: .leading)
                        TimelineSectionLane(parent: self, width: trackWidth)
                    }
                }
            }
            .background(Design.Surface.raised.color)
            .overlay(alignment: .top) { Design.bevelLight.frame(height: 1) }
            Groove()

            // Video, sound and music, top to bottom, each with its
            // own title bar (which resizes it against the area
            // above) and its own vertical scrolling.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shownAreas) { kind in
                    AreaTitleBar(
                        kind: kind,
                        layerCount: areaLayers(kind).count,
                        labelColumnWidth: labelColumnWidth,
                        isResizable: kind != shownAreas.first,
                        onResize: { dy in
                            let start = boundaryDragStart ?? areaHeights
                            boundaryDragStart = start
                            areaLayout.moveBoundary(above: kind, by: dy, from: start, available: areasAvailable)
                        },
                        onResizeEnded: { boundaryDragStart = nil }
                    )
                    area(kind, height: areaHeights[kind] ?? 0, viewport: viewport, structure: structure)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .topLeading) {
                if let newLayerHover {
                    NewLayerZone(hover: newLayerHover)
                        .frame(width: labelColumnWidth)
                        .frame(maxHeight: .infinity)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                var column = frame
                column.size.width = labelColumnWidth
                geometryStore.namesColumn = column
            }
            .overlay {
                if shownAreas.isEmpty {
                    Text("Every area is hidden. Show one in View Options.")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textTertiary)
                }
            }

            // Right under the layers, and only while there is
            // something to scroll to.
            if scrollbarHeight > 0 {
                HStack(spacing: 0) {
                    Color.clear.frame(width: labelColumnWidth)
                    TimelineScrollbarLane(parent: self, width: trackWidth)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            TimelineTrackOverlay(parent: self, width: trackWidth, height: trackHeight)
                .offset(x: labelColumnWidth)
                .allowsHitTesting(false)
        }
        .background(
            TimelineInputMonitor(
                onMagnify: { factor, axis, x, pointer in
                    switch axis {
                    case .horizontal:
                        guard x >= labelColumnWidth else { return }
                        zoom(viewport, by: factor, aboutX: x - labelColumnWidth, pinching: true)
                    case .vertical:
                        zoomLayerHeight(by: factor, at: pointer)
                    }
                },
                onScroll: { deltaX, deltaY, flags, x, phase in
                    guard x >= labelColumnWidth else { return false }
                    if flags.contains(.option) {
                        zoom(viewport, by: exp(deltaY * 0.01), aboutX: x - labelColumnWidth)
                        return true
                    }
                    // Also without movement, so a lift lets go of the edge.
                    scrollTracks(by: deltaX, phase: phase, width: viewport.width)
                    return false
                },
                onMagnifyEnded: {
                    viewportModel.zoomBand.endPinch()
                    viewportModel.layerHeightBand.endPinch()
                },
                onHover: { x in skim(atX: x, viewport: viewport) }
            )
        )
        .background(lassoMonitor(viewport: viewport))
        .overlay { lassoOverlay }
        .onChange(of: geometry.size.width - labelColumnWidth, initial: true) { _, width in viewportModel.trackAreaWidth = width }
        // Here rather than in `TimelineView`'s body, which would follow
        // the zoom to read it.
        .onChange(of: snapKey, initial: true) { _, key in
            liveSnap.targets = key.snapping
                ? derived.snapTargets(
                    of: project, in: timelineID, live: snapPlayhead,
                    markers: key.markers, pixelsPerSecond: key.pixelsPerSecond
                ) : nil
        }
    }
}

/// What the snap targets are built from. The drawn beat markers are in
/// it because choosing another beat layer changes them without an edit.
private struct SnapKey: Equatable {
    var editCount: UInt64
    var timelineID: UUID
    var snapping: Bool
    var pixelsPerSecond: CGFloat
    var markers: [CMTime]
}

/// The ruler, with the render status along its foot. It reads the zoom
/// and the scroll itself, so they redraw it without its parent.
struct TimelineRulerLane: View {
    let parent: TimelineView
    let width: CGFloat

    var body: some View {
        let model = parent.viewportModel
        let viewport = parent.viewport(width: width)
        TimelineRuler(duration: parent.timeline.duration, frameRate: parent.timeline.frameRate, viewport: viewport)
            .frame(width: viewport.width, height: parent.rulerHeight)
            .overlay(alignment: .bottom) { RenderStatusStrip(viewport: viewport) }
            .rubberBandStretch(model.zoomBand)
            .rubberBandScroll(model.scrollBand, length: model.trackAreaWidth)
            .clipped()
            .contentShape(Rectangle())
            .gesture(parent.scrubGesture(in: viewport))
            // To VoiceOver the ruler is the playhead:
            // adjusting it steps a frame.
            .accessibilityHidden(true)
            .overlay {
                PlayheadAccessibilityElement(playhead: parent.playhead, frameRate: parent.timeline.frameRate) {
                    parent.stepPlayhead(byFrames: $0)
                }
            }
    }
}

/// The sections row under the ruler.
struct TimelineSectionLane: View {
    let parent: TimelineView
    let width: CGFloat

    var body: some View {
        let model = parent.viewportModel
        parent.sectionLane(viewport: parent.viewport(width: width))
            .rubberBandStretch(model.zoomBand)
            .rubberBandScroll(model.scrollBand, length: model.trackAreaWidth)
            .clipped()
    }
}

/// What is drawn over every area: the beat markers, the playhead and the
/// skim line.
struct TimelineTrackOverlay: View {
    let parent: TimelineView
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let model = parent.viewportModel
        let viewport = parent.viewport(width: width)
        ZStack(alignment: .topLeading) {
            if !parent.beatMarkers.isEmpty {
                BeatMarkerOverlay(markers: parent.beatMarkers, viewport: viewport, rulerHeight: parent.rulerHeight, height: height)
            }
            // The playhead and the snap line move far more
            // often than anything else here, so they are Core
            // Animation layers rather than SwiftUI shapes.
            PlayheadReader(playhead: parent.playhead) { parked in
                LivePlayheadRail(
                    playback: parent.playback,
                    parked: parked,
                    viewport: viewport,
                    onLeaveView: parent.followsPlayhead && !viewport.isFitted ? { time in parent.page(to: time) } : nil,
                    snapX: model.snapIndicator.map { viewport.x(atSeconds: $0.seconds) },
                    height: height
                )
            }
            TimelineSkimLine(playback: parent.playback, viewport: viewport, height: height)
        }
        .frame(width: viewport.width, height: height, alignment: .topLeading)
        .rubberBandStretch(model.zoomBand)
        .rubberBandScroll(model.scrollBand, length: model.trackAreaWidth)
        .clipped()
    }
}

/// The scrollbar under the areas.
struct TimelineScrollbarLane: View {
    let parent: TimelineView
    let width: CGFloat

    var body: some View {
        let model = parent.viewportModel
        TimelineScrollbar(viewport: parent.viewport(width: width)) { model.scrollX = $0 }
    }
}
