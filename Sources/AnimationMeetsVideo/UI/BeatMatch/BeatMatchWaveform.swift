import AppKit
import CoreMedia
import SwiftUI

/// The song in the beat match panel: a ruler to scrub, a strip of sections,
/// and the waveform with its beats. Pinch or ⌘= and ⌘- zoom, down to single
/// samples; scrolling pans.
///
/// - Ruler: click or drag to move the playhead.
/// - Section strip: drag on unmarked song to draw a section of the chosen
///   kind, drag an edge to move it, click a section to select it, and
///   double-click a gap to fill it.
/// - Waveform: click a beat to select it and drag it to move it (which pins
///   it); click elsewhere to move the playhead; double-click to add a beat
///   (an anchor, before the section is filled). While drawing sections it
///   works as the strip does: dragging on unmarked song draws, an edge
///   moves, and double-clicking fills the gap, while a click still moves
///   the playhead.
///
/// Drawing and moving edges snap as the timeline does, to section edges,
/// beats, the playhead and the song's ends, with its snap line; a section
/// stops at the ones beside it, and the preview shows where it will land.
struct BeatMatchWaveform: View {
    @Bindable var session: BeatMatchSession

    @State private var drag: Drag?
    /// Where a drag is now, for previews.
    @State private var dragX: CGFloat = 0
    /// The map as the drag in progress would leave it, and the section it
    /// is drawing.
    @State private var preview: BeatMap?
    @State private var previewID: UUID?
    /// Where the drag in progress snapped or stopped, for the snap line.
    @State private var snapX: CGFloat?
    /// Whether Option is held while a beat is dragged, which copies it.
    @State private var isCopying = false

    private enum Drag {
        case scrub
        /// Drawing from `from` (snapped) in the gap around `gapAt`.
        case draw(from: Double, gapAt: Double)
        case edge(UUID, BeatMap.Edge)
        case beat(CMTime, grab: CGFloat)
        /// An Option-drag of a section in the strip, which copies it;
        /// `grab` is how far into it the drag began, in seconds.
        case copySection(UUID, grab: Double)
        /// A press on a section in the strip, which selects it.
        case pressSection(UUID)
        /// A press on unmarked song, which draws if it moves; a click
        /// clears the selection and, on the waveform, moves the playhead.
        case pressGap(seeks: Bool)
        /// A press on the waveform, which scrubs if it moves; a click moves
        /// the playhead and selects the section there (or none).
        case pressWave(section: UUID?)
    }

    static let rulerHeight: CGFloat = 18
    /// The section strip matches the timeline's section lane.
    static let stripHeight: CGFloat = SectionLane.height
    /// How close, on screen, the pointer must be to grab an edge or a beat.
    static let reach: CGFloat = 6
    /// How close, on screen, an edge must come to a target to snap to it:
    /// the timeline's distance.
    static let snapDistance: CGFloat = 8

    /// Squeezed by a zoom out past the whole song, over a darker surround,
    /// so the edge of the song shows; stretched by one in past the closest;
    /// slid along by a scroll past either end.
    private func stretched(size: CGSize) -> some View {
        content(size: size)
            .rubberBand($session.zoomBand)
            .rubberBandScroll(session.scrollBand, length: size.width)
            .rubberBandSettling($session.scrollBand)
    }

    var body: some View {
        GeometryReader { geometry in
            stretched(size: geometry.size)
            .background(Design.Surface.well.color)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(height: geometry.size.height))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                doubleClick(at: value.location)
            })
            // A resize arrow over what a drag moves sideways (a section's
            // edge, or a beat; a section itself doesn't move as a whole),
            // and a crosshair where a drag draws a section.
            .onContinuousHover { phase in
                switch phase {
                case .active(let point) where drag == nil:
                    cursor(at: point).set()
                case .active:
                    break
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .background(
                TimelineInputMonitor(
                    onMagnify: { factor, _, x, _ in session.zoom(by: factor, aboutX: x, pinching: true) },
                    onScroll: { deltaX, deltaY, _, _, phase in
                        session.scroll(byPoints: abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY, phase: phase)
                        return true
                    },
                    onMagnifyEnded: { session.endPinch() }
                )
            )
            .onChange(of: geometry.size.width, initial: true) { _, width in session.viewWidth = width }
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform of \(session.assetName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAction(named: "Play or pause") { session.togglePlayback() }
        .accessibilityAction(named: "Add a beat at the playhead") { session.addBeatAtPlayhead() }
        .accessibilityAction(named: "Fill the gap at the playhead") { session.fillGap(at: session.livePlayhead) }
        .accessibilityAction(named: "Select the next beat") { session.selectBeat(step: 1) }
        .accessibilityAction(named: "Select the previous beat") { session.selectBeat(step: -1) }
        .accessibilityAction(named: "Move the selected beat 1 millisecond later") { session.nudgeSelected(by: 0.001) }
        .accessibilityAction(named: "Move the selected beat 1 millisecond earlier") { session.nudgeSelected(by: -0.001) }
        .accessibilityAction(named: "Delete the selected beat") { session.deleteSelectedBeat() }
    }

    /// The ruler, the strip and the waveform, with the playhead over them.
    private func content(size: CGSize) -> some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .background(alignment: .top) {
            if let audio = session.audio {
                let top = Self.rulerHeight + Self.stripHeight
                WaveLayer(audio: audio, start: session.visibleStart, secondsPerPoint: session.secondsPerPoint)
                    .frame(height: max(0, size.height - top))
                    .offset(y: top)
            }
        }
        .background(Design.Surface.sunken.color)
        .overlay(alignment: .topLeading) { sectionStrip(width: size.width) }
        .overlay { playheadRail(size: size) }
    }

    private var accessibilityValue: String {
        var parts = ["Playhead at \(Self.timeText(session.playhead))"]
        if let beat = session.selectedMappedBeat {
            parts.append("beat \(beat.position) selected at \(Self.timeText(beat.time.seconds))\(beat.isPinned ? ", pinned" : "")")
        }
        parts.append("\(session.map.sections.count) sections")
        return parts.joined(separator: ", ")
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let waveTop = Self.rulerHeight + Self.stripHeight
        let waveRect = CGRect(x: 0, y: waveTop, width: size.width, height: max(0, size.height - waveTop))
        drawRuler(in: &context, width: size.width)
        if let loop = session.loopRange {
            let x0 = session.x(of: loop.lowerBound), x1 = session.x(of: loop.upperBound)
            context.fill(Path(CGRect(x: x0, y: waveTop, width: x1 - x0, height: waveRect.height)), with: .color(Design.accent.opacity(0.08)))
        }
        // Each section's colour behind its stretch of the waveform, so the
        // sections read on the waveform that draws them.
        for section in shownMap.sections {
            let x0 = session.x(of: section.start.seconds), x1 = session.x(of: section.end.seconds)
            guard x1 > 0, x0 < size.width else { continue }
            let opacity = session.selectedSectionID == section.id || previewID == section.id ? 0.14 : 0.07
            context.fill(Path(CGRect(x: x0, y: waveTop, width: x1 - x0, height: waveRect.height)), with: .color(section.kind.tone.opacity(opacity)))
        }
        // Each layer is held to its own area, whatever the samples say.
        context.drawLayer { layer in
            layer.clip(to: Path(waveRect))
            drawBeats(in: &layer, rect: waveRect)
        }
    }

    /// The playhead, as Core Animation layers that follow the player on each
    /// display frame while it plays, so playing redraws nothing else and
    /// the line keeps up with what is heard.
    private func playheadRail(size: CGSize) -> some View {
        SwiftUI.TimelineView(.animation(paused: !session.isPlaying)) { context in
            let x = session.x(of: session.playhead(at: context.date))
            PlayheadRail(playheadX: x, isPlayheadVisible: (-1...(size.width + 1)).contains(x), snapX: snapX, height: size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawRuler(in context: inout GraphicsContext, width: CGFloat) {
        context.fill(Path(CGRect(x: 0, y: 0, width: width, height: Self.rulerHeight)), with: .color(Design.Surface.raised.color))
        let spacing = Self.labelSpacing(secondsPerPoint: session.secondsPerPoint)
        let first = (session.visibleStart / spacing).rounded(.down) * spacing
        var seconds = first
        var ticks = Path()
        while session.x(of: seconds) < width {
            let x = session.x(of: seconds)
            ticks.move(to: CGPoint(x: x, y: Self.rulerHeight - 5))
            ticks.addLine(to: CGPoint(x: x, y: Self.rulerHeight))
            if seconds >= 0 {
                context.draw(
                    Text(Self.timeText(seconds, spacing: spacing)).font(Design.Typeface.numericMicro).foregroundStyle(Design.textSecondary),
                    at: CGPoint(x: x + 3, y: 2), anchor: .topLeading
                )
            }
            seconds += spacing
        }
        context.stroke(ticks, with: .color(Design.textTertiary), lineWidth: 1)
    }

    /// The map as drawn: the preview while a drag changes it.
    private var shownMap: BeatMap { preview ?? session.map }

    /// The sections, drawn as the timeline's section lane draws its own:
    /// chips coloured by kind, with the kind (and measure and tempo, once
    /// known) for a name. Drawn only; the waveform's drag does the editing.
    private func sectionStrip(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22)
            ForEach(shownMap.sections) { section in
                let x0 = session.x(of: section.start.seconds), x1 = session.x(of: section.end.seconds)
                if x1 > 0, x0 < width {
                    sectionChip(section, x0: x0, width: max(2, x1 - x0))
                        .offset(x: x0, y: 2)
                }
            }
        }
        .frame(width: width, height: Self.stripHeight, alignment: .topLeading)
        .clipped()
        .offset(y: Self.rulerHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A section's chip, `width` wide at `x0`. A section that starts left of
    /// the view keeps its name at the view's left edge, over what can be
    /// seen of it.
    private func sectionChip(_ section: BeatSection, x0: CGFloat, width: CGFloat) -> some View {
        let isSelected = session.selectedSectionID == section.id
        let isDrawn = previewID == section.id
        let tone = section.kind.tone
        return RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
            .fill(Design.clipFill(tone, selected: isSelected))
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(
                        isSelected || isDrawn ? Design.textOnColor.opacity(0.95) : tone.opacity(0.85),
                        style: StrokeStyle(lineWidth: isSelected || isDrawn ? 1.5 : 1, dash: isDrawn ? [4, 3] : [])
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Design.bevelEdge, lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Text(label(of: section))
                    .font(Design.Typeface.label.weight(.medium))
                    .foregroundStyle(Design.textOnColor)
                    .lineLimit(1)
                    .padding(.leading, max(0, -x0) + Design.Space.tight)
                    .padding(.trailing, Design.Space.tight)
            }
            .opacity(section.kind == .none ? 0.75 : 1)
            .frame(width: width, height: Self.stripHeight - 4)
            .clipped()
    }

    private func label(of section: BeatSection) -> String {
        var parts = [section.kind.name]
        if section.kind != .none {
            if section.isMeasureSet { parts.append("\(section.beatsPerMeasure) beats a measure") }
            if section.isConfirmed, let gap = BeatFitting.medianGap(of: section.beats.map(\.time.seconds)) {
                parts.append(String(format: "%.2f BPM", 60 / gap))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The tag at the top of a beat's line, with its place in the measure.
    static let tagSize = CGSize(width: 15, height: 14)

    /// Each beat as a line down the waveform under a tag with its number in
    /// the measure. Tags need room: when the beats are too close for every
    /// tag, only downbeats keep theirs, and closer still none do, though a
    /// pinned beat keeps a small handle. The selected beat always has its tag.
    private func drawBeats(in context: inout GraphicsContext, rect: CGRect) {
        let visible = session.visibleStart...session.seconds(atX: rect.width)
        let room = Self.tagSize.width + 3
        let lineTop = rect.minY + Self.tagSize.height
        var beats = Path(), downbeats = Path(), anchors = Path(), handles = Path()
        var selected: CGFloat?
        var tags: [(x: CGFloat, beat: MappedBeat, tone: Color, isSelected: Bool)] = []
        for section in session.map.sections where section.kind != .none {
            // Points between beats here, on average.
            let spacing = section.beats.count > 1
                ? CGFloat((section.beats.last!.time.seconds - section.beats.first!.time.seconds) / Double(section.beats.count - 1) / session.secondsPerPoint)
                : .infinity
            let tagsAll = !section.isConfirmed || spacing >= room
            let tagsDownbeats = spacing * CGFloat(section.beatsPerMeasure) >= room
            for beat in section.beats {
                var seconds = beat.time.seconds
                // Moved, unless Option copies it: then it stays.
                if case .beat(let time, let grab) = drag, time == beat.time, !isCopying { seconds = session.seconds(atX: dragX - grab) }
                guard visible.contains(seconds) else { continue }
                let x = session.x(of: seconds)
                var line = Path()
                line.move(to: CGPoint(x: x, y: lineTop))
                line.addLine(to: CGPoint(x: x, y: rect.maxY))
                let isSelected = session.selectedBeat == beat.time
                if isSelected {
                    selected = x
                } else if !section.isConfirmed {
                    anchors.addPath(line)
                } else if beat.isDownbeat {
                    downbeats.addPath(line)
                } else {
                    beats.addPath(line)
                }
                if isSelected || tagsAll || (tagsDownbeats && beat.isDownbeat) {
                    let tone = isSelected ? Design.accent
                        : beat.isPinned || !section.isConfirmed ? Design.keyframe
                        : beat.isDownbeat ? Design.beat : Design.beat.opacity(0.7)
                    tags.append((x, beat, tone, isSelected))
                } else if beat.isPinned {
                    handles.addPath(Path { path in
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x + 4, y: rect.minY + 5))
                        path.addLine(to: CGPoint(x: x, y: rect.minY + 10))
                        path.addLine(to: CGPoint(x: x - 4, y: rect.minY + 5))
                        path.closeSubpath()
                    })
                }
            }
        }
        context.stroke(beats, with: .color(Design.beat.opacity(0.55)), lineWidth: 1)
        context.stroke(downbeats, with: .color(Design.beat), lineWidth: 2)
        context.stroke(anchors, with: .color(Design.keyframe), lineWidth: 1.5)
        context.fill(handles, with: .color(Design.keyframe))
        if let selected {
            var line = Path()
            line.move(to: CGPoint(x: selected, y: lineTop))
            line.addLine(to: CGPoint(x: selected, y: rect.maxY))
            context.stroke(line, with: .color(Design.accent), lineWidth: 2)
        }
        // An Option-dragged beat's copy, where it will land: dashed, with
        // the drop line's ring at its top.
        if isCopying, case .beat(_, let grab) = drag {
            let x = dragX - grab
            var line = Path()
            line.move(to: CGPoint(x: x, y: lineTop))
            line.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(line, with: .color(Design.accent), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            let ring = CGRect(x: x - 3.5, y: lineTop - 7, width: 7, height: 7)
            context.stroke(Path(ellipseIn: ring.insetBy(dx: 1, dy: 1)), with: .color(Design.accent), lineWidth: 2)
        }
        // Each number is laid out once a draw, in the tag's ink.
        var numbers: [String: GraphicsContext.ResolvedText] = [:]
        for tag in tags {
            let frame = CGRect(x: tag.x - Self.tagSize.width / 2, y: rect.minY, width: Self.tagSize.width, height: Self.tagSize.height)
            context.fill(Self.tagPath(in: frame), with: .color(tag.tone))
            let key = "\(tag.beat.position)\(tag.isSelected ? "s" : "")"
            let number = numbers[key] ?? context.resolve(
                Text("\(tag.beat.position)")
                    .font(tag.beat.position > 9 ? Design.Typeface.numericTagCompact : Design.Typeface.numericTag)
                    .foregroundStyle(tag.isSelected ? Design.textOnColor : Design.Surface.well.color)
            )
            numbers[key] = number
            context.draw(number, at: CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.36), anchor: .center)
        }
    }

    /// A downward-pointing tag, as the playhead's head: square shoulders
    /// over a point on the beat.
    private static func tagPath(in frame: CGRect) -> Path {
        let shoulder = frame.minY + frame.height * 0.62
        return Path { path in
            path.move(to: CGPoint(x: frame.minX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: shoulder))
            path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: shoulder))
            path.closeSubpath()
        }
    }

    // MARK: Pointer

    private func dragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragX = value.location.x
                if drag == nil { drag = begin(at: value.startLocation) }
                let moved = abs(value.translation.width) > 3
                // Option copies a beat or a section instead of moving it.
                if case .pressSection(let id) = drag, moved, NSEvent.modifierFlags.contains(.option),
                   let section = session.map.section(id: id) {
                    drag = .copySection(id, grab: session.seconds(atX: value.startLocation.x) - section.start.seconds)
                }
                if case .beat = drag, moved { isCopying = CopyDragCursor.update() }
                if case .copySection = drag { CopyDragCursor.update() }
                switch drag {
                case .scrub:
                    session.seek(to: session.seconds(atX: value.location.x))
                case .pressGap where moved:
                    let start = session.seconds(atX: value.startLocation.x)
                    drag = .draw(from: snapped(start, excluding: nil) ?? start, gapAt: start)
                    showDrawing()
                case .pressWave where moved:
                    drag = .scrub
                    session.seek(to: session.seconds(atX: value.location.x))
                case .draw:
                    showDrawing()
                case .edge(let id, let edge):
                    let proposed = session.seconds(atX: value.location.x)
                    let target = snapped(proposed, excluding: id)
                    let moved = session.edgePreview(edge, of: id, to: target ?? proposed)
                    preview = moved
                    let landed = moved.section(id: id).map { (edge == .start ? $0.start : $0.end).seconds }
                    showSnap(target: target, landed: landed, proposed: proposed)
                case .copySection(let id, let grab):
                    showCopy(of: id, grab: grab)
                default:
                    break
                }
            }
            .onEnded { value in
                defer {
                    drag = nil
                    preview = nil
                    previewID = nil
                    snapX = nil
                    isCopying = false
                    CopyDragCursor.end()
                }
                let seconds = session.seconds(atX: value.location.x)
                switch drag {
                case .draw(let from, let gapAt):
                    session.drawSection(from: from, to: snapped(seconds, excluding: nil) ?? seconds, in: gapAt, snap: 0)
                case .edge(let id, let edge):
                    session.moveEdge(edge, of: id, to: snapped(seconds, excluding: id) ?? seconds, snap: 0)
                case .beat(let time, let grab):
                    if abs(value.translation.width) > 1 {
                        let target = session.seconds(atX: value.location.x - grab)
                        if isCopying {
                            session.copyBeat(at: time, to: target)
                        } else {
                            session.moveBeat(at: time, to: target)
                        }
                    }
                case .copySection(let id, let grab):
                    if let start = copyStart(grab: grab) { session.copySection(id, toStart: start) }
                case .pressSection(let id):
                    session.selectedSectionID = id
                case .pressGap(let seeks):
                    session.selectedSectionID = nil
                    if seeks {
                        session.selectedBeat = nil
                        session.seek(to: seconds)
                    }
                case .pressWave(let section):
                    session.selectedBeat = nil
                    if session.step == .drawSections { session.selectedSectionID = section }
                    session.seek(to: seconds)
                case .scrub, nil:
                    break
                }
            }
    }

    /// Where an Option-dragged section's copy would start: under the
    /// pointer as far into it as the drag began, its start snapped.
    private func copyStart(grab: Double) -> Double? {
        let proposed = session.seconds(atX: dragX) - grab
        return snapped(proposed, excluding: nil) ?? proposed
    }

    /// Shows an Option-dragged section's copy where it will land, as a
    /// section being drawn is shown, and the line where it starts.
    private func showCopy(of id: UUID, grab: Double) {
        guard let start = copyStart(grab: grab), let (map, copyID) = session.copyPreview(of: id, toStart: start) else {
            preview = nil
            previewID = nil
            snapX = nil
            return
        }
        preview = map
        previewID = copyID
        snapX = map.section(id: copyID).map { session.x(of: $0.start.seconds) }
    }

    /// Shows the section being drawn where it will land, and the snap line
    /// where its moving end snapped or stopped.
    private func showDrawing() {
        guard case .draw(let from, let gapAt) = drag else { return }
        let proposed = session.seconds(atX: dragX)
        let target = snapped(proposed, excluding: nil)
        guard let (map, id) = session.drawingPreview(from: from, to: target ?? proposed, in: gapAt) else {
            preview = nil
            previewID = nil
            snapX = nil
            return
        }
        preview = map
        previewID = id
        let landed = map.section(id: id).map { proposed < from ? $0.start.seconds : $0.end.seconds }
        showSnap(target: target, landed: landed, proposed: proposed)
    }

    /// The snap line goes where the edge snapped, or where it stopped short
    /// of where it was dragged, against a neighbour or the song's end.
    private func showSnap(target: Double?, landed: Double?, proposed: Double) {
        if let target {
            snapX = session.x(of: target)
        } else if let landed, abs(session.x(of: landed) - session.x(of: proposed)) > 1 {
            snapX = session.x(of: landed)
        } else {
            snapX = nil
        }
    }

    /// The snap target within `snapDistance` of `seconds`, leaving out the
    /// edges of section `owner`: the timeline's snapping, over the song's
    /// ends, the playhead, every section's edges and every beat.
    private func snapped(_ seconds: Double, excluding owner: UUID?) -> Double? {
        let time = { (seconds: Double) in CMTime(seconds: seconds, preferredTimescale: 48_000) }
        var targets = [
            SnapTargets.Target(time: .zero), SnapTargets.Target(time: session.duration),
            SnapTargets.Target(time: time(session.livePlayhead)),
        ]
        for section in session.map.sections {
            targets.append(SnapTargets.Target(time: section.start, ownerID: section.id))
            targets.append(SnapTargets.Target(time: section.end, ownerID: section.id))
            targets += section.beats.map { SnapTargets.Target(time: $0.time) }
        }
        let tolerance = time(Double(Self.snapDistance) * session.secondsPerPoint)
        return SnapTargets(targets: targets).nearest(to: time(seconds), within: tolerance, excluding: owner)?.seconds
    }

    /// Whether a point is where sections are drawn and edited: the strip,
    /// and the waveform while drawing sections.
    private func editsSections(at point: CGPoint) -> Bool {
        point.y >= Self.rulerHeight && (point.y < Self.rulerHeight + Self.stripHeight || session.step == .drawSections)
    }

    /// The section edge within reach of `x`, nearest first.
    private func edge(nearX x: CGFloat) -> (UUID, BeatMap.Edge)? {
        var best: (id: UUID, edge: BeatMap.Edge, distance: CGFloat)?
        for section in session.map.sections {
            for (edge, time) in [(BeatMap.Edge.start, section.start), (.end, section.end)] {
                let distance = abs(session.x(of: time.seconds) - x)
                if distance <= Self.reach, distance < (best?.distance ?? .infinity) { best = (section.id, edge, distance) }
            }
        }
        return best.map { ($0.id, $0.edge) }
    }

    private func beat(nearX x: CGFloat) -> MappedBeat? {
        let reach = CMTime(seconds: Double(Self.reach) * session.secondsPerPoint, preferredTimescale: 192_000)
        return session.map.nearestBeat(to: BeatFitting.time(session.seconds(atX: x), sampleRate: 192_000), within: reach)
    }

    private func isInGap(atX x: CGFloat) -> Bool {
        session.map.sectionIndex(containing: BeatFitting.time(session.seconds(atX: x), sampleRate: 48_000)) == nil
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        guard point.y >= Self.rulerHeight else { return .arrow }
        let inStrip = point.y < Self.rulerHeight + Self.stripHeight
        if editsSections(at: point) {
            if edge(nearX: point.x) != nil { return .resizeLeftRight }
            if !inStrip, beat(nearX: point.x) != nil { return .resizeLeftRight }
            return isInGap(atX: point.x) ? .crosshair : .arrow
        }
        return !inStrip && beat(nearX: point.x) != nil ? .resizeLeftRight : .arrow
    }

    /// What a press at `point` starts.
    private func begin(at point: CGPoint) -> Drag {
        if point.y < Self.rulerHeight {
            session.seek(to: session.seconds(atX: point.x))
            return .scrub
        }
        let seconds = session.seconds(atX: point.x)
        let inStrip = point.y < Self.rulerHeight + Self.stripHeight
        let containing = session.map.sectionIndex(containing: BeatFitting.time(seconds, sampleRate: 48_000)).map { session.map.sections[$0].id }
        if editsSections(at: point), let (id, edge) = edge(nearX: point.x) {
            session.selectedSectionID = id
            return .edge(id, edge)
        }
        if inStrip {
            return containing.map { .pressSection($0) } ?? .pressGap(seeks: false)
        }
        if let beat = beat(nearX: point.x) {
            session.selectedBeat = beat.time
            if let index = session.map.sectionIndex(containing: beat.time) {
                session.selectedSectionID = session.map.sections[index].id
            }
            return .beat(beat.time, grab: point.x - session.x(of: beat.time.seconds))
        }
        if session.step == .drawSections, containing == nil { return .pressGap(seeks: true) }
        return .pressWave(section: containing)
    }

    private func doubleClick(at point: CGPoint) {
        guard point.y >= Self.rulerHeight else { return }
        let seconds = session.seconds(atX: point.x)
        if editsSections(at: point) {
            session.fillGap(at: seconds)
        } else {
            session.addBeat(at: seconds)
        }
    }

    // MARK: Text

    /// Ruler labels at least 70 points apart, on round steps.
    static func labelSpacing(secondsPerPoint: Double) -> Double {
        let wanted = secondsPerPoint * 70
        let steps = [0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return steps.first { $0 >= wanted } ?? 600
    }

    /// Minutes, seconds and as many decimals as `spacing` needs.
    static func timeText(_ seconds: Double, spacing: Double = 0.001) -> String {
        let decimals = spacing >= 1 ? 0 : min(4, Int((-log10(spacing)).rounded(.up)))
        let minutes = Int(seconds / 60)
        let rest = seconds - Double(minutes) * 60
        let secondsText = String(format: "%0\(decimals == 0 ? 2 : decimals + 3).\(decimals)f", rest)
        return "\(minutes):\(secondsText)"
    }
}

/// The song's samples, drawn on their own so that only zooming and
/// scrolling redraw them, not a drag over them or the playhead moving.
private struct WaveLayer: View {
    let audio: BeatMatchAudio
    /// The left edge, in seconds, and the zoom.
    let start: Double
    let secondsPerPoint: Double

    var body: some View {
        Canvas { context, size in
            draw(in: &context, rect: CGRect(origin: .zero, size: size))
        }
        .allowsHitTesting(false)
    }

    private func x(of seconds: Double) -> CGFloat { CGFloat((seconds - start) / secondsPerPoint) }
    private func seconds(atX x: CGFloat) -> Double { start + Double(x) * secondsPerPoint }

    private func draw(in context: inout GraphicsContext, rect: CGRect) {
        guard rect.height > 0 else { return }
        // Scaled to the song's loudest sample, so it fills the area and
        // never runs past it.
        let middle = rect.midY, half = rect.height / 2 * 0.92 / CGFloat(audio.peak)
        let samplesPerPoint = secondsPerPoint * audio.sampleRate
        let color = Design.ClipTone.music.color
        if let level = audio.level(forSamplesPerPoint: samplesPerPoint) {
            var shape = Path()
            for column in 0..<Int(rect.width) {
                let from = audio.sample(atSeconds: seconds(atX: CGFloat(column)))
                let to = from + samplesPerPoint
                let low = max(0, Int(from) / level.samplesPerBucket), high = min(level.high.count, Int(to.rounded(.up)) / level.samplesPerBucket + 1)
                guard low < high else { continue }
                let top = level.high[low..<high].max() ?? 0, bottom = level.low[low..<high].min() ?? 0
                shape.addRect(CGRect(x: CGFloat(column), y: middle - CGFloat(top) * half, width: 1, height: max(1, CGFloat(top - bottom) * half)))
            }
            context.fill(shape, with: .color(color))
        } else {
            // Close in: the samples themselves, joined, with dots once they
            // are a few points apart.
            let first = max(0, Int(audio.sample(atSeconds: start)) - 1)
            let last = min(audio.samples.count - 1, Int(audio.sample(atSeconds: seconds(atX: rect.width))) + 1)
            guard first <= last else { return }
            var line = Path(), dots = Path()
            for index in first...last {
                let point = CGPoint(x: x(of: audio.seconds(atSample: index)), y: middle - CGFloat(audio.samples[index]) * half)
                if index == first { line.move(to: point) } else { line.addLine(to: point) }
                if samplesPerPoint < 0.34 { dots.addEllipse(in: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)) }
            }
            context.stroke(line, with: .color(color), lineWidth: 1)
            context.fill(dots, with: .color(color))
        }
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: middle))
        axis.addLine(to: CGPoint(x: rect.width, y: middle))
        context.stroke(axis, with: .color(Design.textTertiary.opacity(0.4)), lineWidth: 1)
    }
}
