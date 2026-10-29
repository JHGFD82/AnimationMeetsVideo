import CoreMedia
import SwiftUI

/// The motion designer's lanes, on one timeline across: the ruler, the
/// retimed filmstrip, the time graph and the music with its beats. The
/// graph runs up through the run's footage, clip after clip, so the run
/// reads as one line: steep where it plays fast, shallow where slow, and
/// flat over a gap. Clicking the line drops a marker on that frame, and
/// grabbing it drops one, eased with its handles in line, and drags it; a
/// hit's pin runs from its frame down to its beat. A selected eased point
/// shows the handles of its Ease In and Ease Out on its tangent, as the
/// graph editor shows a keyframe's: dragging one along shapes how far it
/// reaches and tilting it sets the speed at the point, the other swinging
/// to stay in line unless Option is held; dragged onto its point, it goes.
/// Each clip's first and last frames show a keyframe too, which stays put:
/// Option-dragging it pulls out its one handle, which only ever reaches
/// into the clip.
struct MotionDesignLanes: View {
    @Bindable var session: MotionDesignSession

    static let rulerHeight: CGFloat = 20
    static let filmHeight: CGFloat = 56
    static let musicHeight: CGFloat = 96
    /// Room above and below the line, so points at its ends stay whole.
    private static let graphInset: CGFloat = 14

    private enum GraphDrag {
        /// Pressed on something, which isn't dragged until the pointer
        /// moves `dragDistance` from where it went down: a click on a
        /// point only selects it, and changes nothing.
        case pressed(Grab)
        case point(UUID, from: Double, added: Bool)
        case handle(UUID, side: TimePoint.Side)
        case edgeHandle(MotionDesignSession.EdgeKey)
        case seek
        /// A drag that does nothing, such as one on an edge keyframe
        /// without Option.
        case inert
    }

    private enum Grab {
        case point(UUID, from: Double)
        case handle(UUID, side: TimePoint.Side)
        case edge(MotionDesignSession.EdgeKey)
        case edgeHandle(MotionDesignSession.EdgeKey)
        /// The line, where a click or a drag drops a marker.
        case line(piece: UUID, time: Double)
    }

    private static let dragDistance: CGFloat = 3

    @State private var drag: GraphDrag?
    /// Where the drag snapped, to draw.
    @State private var snapTime: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let graphHeight = max(120, geometry.size.height - Self.rulerHeight - Self.filmHeight - musicHeight)
            VStack(spacing: 0) {
                ruler(width: width)
                RetimedFilmstrip(session: session, width: width, height: Self.filmHeight)
                graph(width: width, height: graphHeight)
                musicLane(width: width)
            }
            .overlay(alignment: .topLeading) {
                markings(width: width, height: geometry.size.height, graphHeight: graphHeight)
            }
            .overlay(alignment: .top) { noticeView }
            // Squeezed by a zoom out past the whole timeline, stretched by
            // one in past the closest, slid along by a scroll past either
            // end; all the lanes together, so they stay lined up.
            .rubberBand($session.zoomBand)
            .rubberBandScroll(session.scrollBand, length: width)
            .rubberBandSettling($session.scrollBand)
            .background(Design.Surface.well.color)
            .onChange(of: width, initial: true) { _, width in session.viewWidth = width }
        }
        .clipped()
        .background(
            TimelineInputMonitor(
                onMagnify: { factor, _, x, _ in session.zoom(by: factor, aboutX: x, pinching: true) },
                onScroll: { deltaX, deltaY, flags, x, phase in
                    if flags.contains(.option) || flags.contains(.command) {
                        session.zoom(by: pow(1.01, Double(deltaY)), aboutX: x)
                    } else {
                        session.scroll(byPoints: abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY, phase: phase)
                    }
                    return true
                },
                onMagnifyEnded: { session.endPinch() },
                onHover: { x in session.skim(atX: x) }
            )
        )
    }

    // MARK: Notice

    /// Why a clip didn't move, just under the footage; any click anywhere
    /// puts it away.
    @ViewBuilder
    private var noticeView: some View {
        ZStack {
            if let notice = session.notice {
                Label(notice, systemImage: "pin.fill")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textPrimary)
                    .padding(.horizontal, Design.Space.rail)
                    .padding(.vertical, Design.Space.step)
                    .floatingSurface(radius: Design.Radius.chip)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Self.rulerHeight + Self.filmHeight + Design.Space.step)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Design.Motion.respecting(Design.Motion.fade), value: session.notice)
        .onClickAnywhere(isActive: session.notice != nil) { session.notice = nil }
    }

    // MARK: Ruler

    private func ruler(width: CGFloat) -> some View {
        Canvas { context, size in
            let spacing = BeatMatchWaveform.labelSpacing(secondsPerPoint: session.secondsPerPoint)
            var seconds = (session.visibleStart / spacing).rounded(.down) * spacing
            while session.x(of: seconds) < size.width {
                let x = session.x(of: seconds)
                context.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(Design.textTertiary.opacity(0.6)))
                context.draw(
                    Text(session.timecode(seconds: seconds))
                        .font(Design.Typeface.numericScale).foregroundStyle(Design.textTertiary),
                    at: CGPoint(x: x + 3, y: 2), anchor: .topLeading
                )
                seconds += spacing
            }
        }
        .frame(width: width, height: Self.rulerHeight)
        .background(Design.Surface.raised.color)
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playhead")
        .accessibilityValue(session.timecode(seconds: session.playhead))
        .accessibilityAdjustableAction { direction in
            let frame = session.timeline.frameDuration.seconds
            session.seek(to: session.playhead + (direction == .increment ? frame : -frame))
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in session.seek(to: session.seconds(atX: drag.location.x)) }
    }

    // MARK: Graph

    /// Where each piece's footage starts up the graph, as a share of all of
    /// it, so the run stacks clip on clip. The footage is the draft's, so a
    /// trim or a held edge resizes its clip's band.
    private struct Stack {
        var offsets: [Double]
        var trimStarts: [Double]
        var total: Double
        var rect: CGRect

        init(_ run: MotionRun, rect: CGRect) {
            var offsets: [Double] = []
            var total = 0.0
            for piece in run.pieces {
                offsets.append(total)
                total += piece.map.trimEnd.seconds - piece.map.trimStart.seconds
            }
            self.offsets = offsets
            trimStarts = run.pieces.map(\.map.trimStart.seconds)
            self.total = max(total, 1e-6)
            self.rect = rect
        }

        func y(piece index: Int, source: CMTime) -> CGFloat {
            y(piece: index, source: source.seconds)
        }

        func y(piece index: Int, source: Double) -> CGFloat {
            let up = offsets[index] + (source - trimStarts[index])
            return rect.maxY - CGFloat(up / total) * rect.height
        }

        /// The source seconds of a piece at `y`, past its footage too.
        func source(piece index: Int, y: CGFloat) -> Double {
            trimStarts[index] + Double((rect.maxY - y) / rect.height) * total - offsets[index]
        }
    }

    private func stack(height: CGFloat, width: CGFloat) -> Stack {
        Stack(session.run, rect: CGRect(x: 0, y: Self.graphInset, width: width, height: height - 2 * Self.graphInset))
    }

    private func graph(width: CGFloat, height: CGFloat) -> some View {
        let stack = stack(height: height, width: width)
        return Canvas { context, size in
            drawGraph(in: &context, size: size, stack: stack)
        }
        .frame(width: width, height: height)
        .background(Design.Surface.sunken.color)
        .contentShape(Rectangle())
        .gesture(graphGesture(stack: stack))
        .onContinuousHover { phase in
            if case .active(let location) = phase {
                let over = point(at: location, stack: stack) != nil || edge(at: location, stack: stack) != nil || line(at: location, stack: stack) != nil
                (over ? NSCursor.pointingHand : NSCursor.arrow).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .contextMenu { pointMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time graph")
        .accessibilityValue(graphSummary)
        .accessibilityChildren {
            ForEach(allPoints, id: \.point.id) { entry in
                pointElement(entry.point, piece: entry.piece)
            }
            ForEach(allEdges, id: \.key) { entry in
                edgeElement(entry.key, piece: entry.piece)
            }
        }
        .accessibilityAction(named: "Add marker at playhead") { session.addMarkerAtPlayhead() }
    }

    private func drawGraph(in context: inout GraphicsContext, size: CGSize, stack: Stack) {
        // A faint band for each clip's footage, up the graph.
        for (index, piece) in session.run.pieces.enumerated() where index % 2 == 1 {
            let top = stack.y(piece: index, source: piece.map.trimEnd)
            let bottom = stack.y(piece: index, source: piece.map.trimStart)
            context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)), with: .color(.white.opacity(0.025)))
        }
        if session.showsBeats { drawBeats(in: &context, height: size.height, strong: 0.32, weak: 0.14) }

        let drafts = session.run.pieces.map { session.drafted($0) }
        // Gaps: flat, since no footage plays.
        for index in drafts.indices.dropLast() {
            let a = drafts[index], b = drafts[index + 1]
            let y = stack.y(piece: index, source: a.trimEnd)
            var gap = Path()
            gap.move(to: CGPoint(x: session.x(of: a.endOffset.seconds), y: y))
            gap.addLine(to: CGPoint(x: session.x(of: b.startOffset.seconds), y: y))
            context.stroke(gap, with: .color(Design.textTertiary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        for (index, clip) in drafts.enumerated() {
            let tone = Design.ClipTone.of(session.project.resolvedInfo(for: clip.source), streams: clip.streams).color
            let x0 = max(0, session.x(of: clip.startOffset.seconds)), x1 = min(size.width, session.x(of: clip.endOffset.seconds))
            guard x1 > x0 else { continue }
            var line = Path()
            var x = x0
            while true {
                let time = CMTime(seconds: session.seconds(atX: x), preferredTimescale: ClipTimeMap.timescale)
                let source = CMTimeClampToRange(clip.sourceTime(atTimelineTime: time), range: CMTimeRange(start: clip.trimStart, end: clip.trimEnd))
                let point = CGPoint(x: x, y: stack.y(piece: index, source: source))
                if line.isEmpty { line.move(to: point) } else { line.addLine(to: point) }
                if x >= x1 { break }
                x = min(x + 2, x1)
            }
            context.stroke(line, with: .color(tone), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            drawSpeeds(of: session.run.pieces[index], clip: clip, index: index, stack: stack, in: &context)
        }
        for handle in easeHandles(stack: stack) {
            var stem = Path()
            stem.move(to: handle.anchor)
            stem.addLine(to: handle.point)
            context.stroke(stem, with: .color(.white.opacity(0.6)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: handle.point.x - 3.5, y: handle.point.y - 3.5, width: 7, height: 7)), with: .color(.white))
        }
        for (index, piece) in session.run.pieces.enumerated() {
            for edge in [MotionRun.Edge.start, .end] {
                guard let at = location(of: edge, piece: index, stack: stack) else { continue }
                drawEdge(MotionDesignSession.EdgeKey(piece: piece.id, edge: edge), map: piece.map, at: at, in: &context)
            }
            for point in piece.map.points {
                drawPoint(point, at: location(of: point, piece: index, stack: stack), in: &context)
            }
        }
    }

    // MARK: Ease handles

    private struct EaseHandle {
        /// What pressing it takes hold of.
        var grab: Grab
        /// The point, and the handle's end on its tangent.
        var anchor: CGPoint
        var point: CGPoint
    }

    /// The selected point's piece, its place there, and the stretch on a
    /// side of it.
    private func stretch(_ side: TimePoint.Side, of id: UUID) -> (piece: Int, stretch: TimeStretch)? {
        guard let (p, i) = session.run.piece(holdingPoint: id) else { return nil }
        let map = session.run.pieces[p].map
        let point = map.points[i]
        let stretch = map.stretches.first { stretch in
            side == .before
                ? stretch.end.source == point.source.seconds && stretch.end.time == point.time.seconds
                : stretch.start.source == point.source.seconds && stretch.start.time == point.time.seconds
        }
        return stretch.map { (p, $0) }
    }

    /// The handles of the selected point's eased sides, on its tangent as a
    /// keyframe's are: reaching their influence of the stretch along the
    /// timeline, tilted to the speed they set at the point.
    private func easeHandles(stack: Stack) -> [EaseHandle] {
        if let key = session.selectedEdge { return edgeHandle(key, stack: stack).map { [$0] } ?? [] }
        guard let id = session.selectedPointID, let (p, i) = session.run.piece(holdingPoint: id) else { return [] }
        let map = session.run.pieces[p].map
        let point = map.points[i]
        let anchor = location(of: point, piece: p, stack: stack)
        var handles: [EaseHandle] = []
        for side in [TimePoint.Side.before, .after] {
            guard let ease = point.ease(side), map.canEase(side, of: i), let (_, stretch) = stretch(side, of: id) else { continue }
            let unit = side == .before ? KeyframeEase.incomingHandle(ease) : KeyframeEase.outgoingHandle(ease)
            let time = stretch.start.time + stretch.duration * Double(unit.x)
            let source = stretch.start.source + stretch.footage * Double(unit.y)
            let at = CGPoint(x: session.x(of: time), y: stack.y(piece: p, source: source))
            handles.append(EaseHandle(grab: .handle(id, side: side), anchor: anchor, point: at))
        }
        return handles
    }

    /// The ease a handle dragged to `location` makes, measured in its
    /// stretch as the graph editor measures a keyframe's handle; nil when
    /// it is dropped on its point, which puts that side back on the
    /// straight line.
    private func ease(dragging side: TimePoint.Side, of id: UUID, to pointer: CGPoint, stack: Stack) -> KeyframeEase?? {
        guard let (p, stretch) = stretch(side, of: id), stretch.duration > 0, stretch.footage > 0,
              let (_, i) = session.run.piece(holdingPoint: id)
        else { return .none }
        let anchor = location(of: session.run.pieces[p].map.points[i], piece: p, stack: stack)
        if hypot(pointer.x - anchor.x, pointer.y - anchor.y) < 6 { return .some(nil) }
        let unit = CGPoint(
            x: (session.seconds(atX: pointer.x) - stretch.start.time) / stretch.duration,
            y: (stack.source(piece: p, y: pointer.y) - stretch.start.source) / stretch.footage
        )
        return .some(side == .before ? KeyframeEase.incoming(handleAt: unit) : KeyframeEase.outgoing(handleAt: unit))
    }

    // MARK: Edge keyframes

    /// Where a piece's edge keyframe sits, at the open end's outer corner;
    /// nil while it shows none.
    private func location(of edge: MotionRun.Edge, piece index: Int, stack: Stack) -> CGPoint? {
        guard let stretch = session.run.pieces[index].map.edgeStretch(edge) else { return nil }
        let corner = edge == .start ? stretch.start : stretch.end
        return CGPoint(x: session.x(of: corner.time), y: stack.y(piece: index, source: corner.source))
    }

    private func edge(at location: CGPoint, stack: Stack) -> MotionDesignSession.EdgeKey? {
        var best: (key: MotionDesignSession.EdgeKey, distance: CGFloat)?
        for (index, piece) in session.run.pieces.enumerated() {
            for edge in [MotionRun.Edge.start, .end] {
                guard let at = self.location(of: edge, piece: index, stack: stack) else { continue }
                let distance = hypot(at.x - location.x, at.y - location.y)
                if distance <= 9, distance < (best?.distance ?? .infinity) { best = (.init(piece: piece.id, edge: edge), distance) }
            }
        }
        return best?.key
    }

    /// The selected edge keyframe's handle, reaching into its open end,
    /// while it has one.
    private func edgeHandle(_ key: MotionDesignSession.EdgeKey, stack: Stack) -> EaseHandle? {
        guard let p = session.run.index(of: key.piece) else { return nil }
        let map = session.run.pieces[p].map
        guard let ease = map.edgeEase(key.edge), let stretch = map.edgeStretch(key.edge),
              let anchor = location(of: key.edge, piece: p, stack: stack)
        else { return nil }
        let unit = key.edge == .start ? KeyframeEase.outgoingHandle(ease) : KeyframeEase.incomingHandle(ease)
        let at = CGPoint(
            x: session.x(of: stretch.start.time + stretch.duration * Double(unit.x)),
            y: stack.y(piece: p, source: stretch.start.source + stretch.footage * Double(unit.y))
        )
        return EaseHandle(grab: .edgeHandle(key), anchor: anchor, point: at)
    }

    /// The ease an edge keyframe's handle dragged to `location` makes, in
    /// its open end, so it never reaches past the clip's edge; nil when it
    /// is on the keyframe, which takes the handle away.
    private func ease(dragging key: MotionDesignSession.EdgeKey, to pointer: CGPoint, stack: Stack) -> KeyframeEase?? {
        guard let p = session.run.index(of: key.piece), let stretch = session.run.pieces[p].map.edgeStretch(key.edge),
              stretch.duration > 0, stretch.footage > 0, let anchor = location(of: key.edge, piece: p, stack: stack)
        else { return .none }
        if hypot(pointer.x - anchor.x, pointer.y - anchor.y) < 6 { return .some(nil) }
        let unit = CGPoint(
            x: (session.seconds(atX: pointer.x) - stretch.start.time) / stretch.duration,
            y: (stack.source(piece: p, y: pointer.y) - stretch.start.source) / stretch.footage
        )
        return .some(key.edge == .start ? KeyframeEase.outgoing(handleAt: unit) : KeyframeEase.incoming(handleAt: unit))
    }

    /// An edge keyframe's mark: smaller and quieter than a point's, as the
    /// clip puts it there, pinched on its inner side once it has a handle.
    private func drawEdge(_ key: MotionDesignSession.EdgeKey, map: ClipTimeMap, at center: CGPoint, in context: inout GraphicsContext) {
        let eased = map.edgeEase(key.edge) != nil
        let size: CGFloat = 9
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let shape = KeyframeMarkShape(easedIn: key.edge == .end && eased, easedOut: key.edge == .start && eased, holds: false).path(in: rect)
        context.fill(shape, with: .color(Design.textTertiary))
        context.stroke(shape, with: .color(.black.opacity(0.5)), lineWidth: 0.5)
        if key == session.selectedEdge {
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(Design.accent), lineWidth: 1.5)
        }
    }

    /// Each stretch's speed, over its middle, where it has room; stretches
    /// either side of a point at one speed share one reading.
    private func drawSpeeds(of piece: MotionRun.Piece, clip: TimelineClip, index: Int, stack: Stack, in context: inout GraphicsContext) {
        let edges = ([clip.startOffset.seconds] + piece.map.points.map(\.time.seconds) + [clip.endOffset.seconds]).sorted()
        func speed(at seconds: Double) -> Double {
            clip.speed(atSource: clip.sourceTime(atTimelineTime: CMTime(seconds: seconds, preferredTimescale: ClipTimeMap.timescale)))
        }
        var stretches: [(start: Double, end: Double)] = []
        for (a, b) in zip(edges, edges.dropFirst()) {
            if let last = stretches.last, abs(speed(at: (last.start + last.end) / 2) - speed(at: (a + b) / 2)) < 0.05 {
                stretches[stretches.count - 1].end = b
            } else {
                stretches.append((a, b))
            }
        }
        for (a, b) in stretches {
            let xa = session.x(of: a), xb = session.x(of: b)
            guard xb - xa > 48 else { continue }
            // A pace marker's tag already says the speed after it.
            if piece.map.points.contains(where: { $0.pace != nil && a <= $0.time.seconds && $0.time.seconds < b }) { continue }
            let middle = (a + b) / 2
            let time = CMTime(seconds: middle, preferredTimescale: ClipTimeMap.timescale)
            let speed = speed(at: middle)
            let y = stack.y(piece: index, source: clip.sourceTime(atTimelineTime: time))
            context.draw(
                Text(Self.speedText(speed)).font(Design.Typeface.numericScale).foregroundStyle(Design.textSecondary),
                at: CGPoint(x: session.x(of: middle), y: y - 8), anchor: .bottom
            )
        }
    }

    static func speedText(_ speed: Double) -> String {
        speed >= 10 ? "\(Int(speed.rounded()))%" : String(format: "%.1f%%", speed)
    }

    /// A point's mark, in the keyframes' language: squared off past a pace
    /// marker, where the speed steps; pinched where it is eased. Hits are
    /// the bright "placed" tone, markers quieter.
    private func drawPoint(_ point: TimePoint, at center: CGPoint, in context: inout GraphicsContext) {
        let isSelected = point.id == session.selectedPointID
        let size: CGFloat = point.isHit ? 13 : 11
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let shape = KeyframeMarkShape(easedIn: point.easeIn != nil, easedOut: point.easeOut != nil, holds: point.pace != nil).path(in: rect)
        context.fill(shape, with: .color(point.isHit ? Design.snap : Design.textSecondary))
        context.stroke(shape, with: .color(.black.opacity(0.5)), lineWidth: 0.5)
        if isSelected {
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(Design.accent), lineWidth: 1.5)
        }
        if let pace = point.pace {
            context.draw(
                Text("→ \(Self.speedText(pace))").font(Design.Typeface.numericTag).foregroundStyle(Design.keyframe),
                at: CGPoint(x: center.x + 9, y: center.y + 6), anchor: .topLeading
            )
        }
    }

    private func location(of point: TimePoint, piece index: Int, stack: Stack) -> CGPoint {
        CGPoint(x: session.x(of: point.time.seconds), y: stack.y(piece: index, source: point.source))
    }

    private func drawBeats(in context: inout GraphicsContext, height: CGFloat, strong: Double, weak: Double) {
        let beats = session.beatsInWindow
        let visibleEnd = session.seconds(atX: session.viewWidth)
        // Thinned as on the timeline: every beat while they are 10 points
        // apart, else only downbeats.
        let spaced = (beats.count > 1) && beats.indices.dropLast().contains { i in
            beats[i].time.seconds >= session.visibleStart
                && session.x(of: beats[i + 1].time.seconds) - session.x(of: beats[i].time.seconds) < 10
        }
        for beat in beats where beat.time.seconds >= session.visibleStart && beat.time.seconds <= visibleEnd {
            let downbeat = beat.position == 1
            if spaced, !downbeat { continue }
            let x = session.x(of: beat.time.seconds)
            context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: height)), with: .color(Design.beat.opacity(downbeat ? strong : weak)))
        }
    }

    // MARK: Hit testing and dragging

    private func point(at location: CGPoint, stack: Stack) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?
        for (index, piece) in session.run.pieces.enumerated() {
            for point in piece.map.points {
                let at = self.location(of: point, piece: index, stack: stack)
                let distance = hypot(at.x - location.x, at.y - location.y)
                if distance <= 9, distance < (best?.distance ?? .infinity) { best = (point.id, distance) }
            }
        }
        return best?.id
    }

    /// The clip whose line passes near `location`, and the time there.
    private func line(at location: CGPoint, stack: Stack) -> (piece: UUID, time: Double)? {
        let seconds = session.seconds(atX: location.x)
        let time = CMTime(seconds: seconds, preferredTimescale: ClipTimeMap.timescale)
        for (index, piece) in session.run.pieces.enumerated() {
            let clip = session.drafted(piece)
            guard clip.startOffset <= time, time <= clip.endOffset else { continue }
            let y = stack.y(piece: index, source: clip.sourceTime(atTimelineTime: time))
            if abs(y - location.y) <= 12 { return (piece.id, seconds) }
        }
        return nil
    }

    /// What a press at `location` takes hold of: a selected point's ease
    /// handle, a point (selecting it), the line, or else the playhead.
    private func grab(at location: CGPoint, stack: Stack) -> GraphDrag {
        if let handle = easeHandles(stack: stack).first(where: { hypot($0.point.x - location.x, $0.point.y - location.y) <= 7 }) {
            return .pressed(handle.grab)
        }
        if let id = point(at: location, stack: stack), let found = session.run.piece(holdingPoint: id) {
            session.select(point: id)
            return .pressed(.point(id, from: session.run.pieces[found.piece].map.points[found.point].time.seconds))
        }
        if let key = edge(at: location, stack: stack) {
            session.select(edge: key)
            return .pressed(.edge(key))
        }
        if let hit = line(at: location, stack: stack) { return .pressed(.line(piece: hit.piece, time: hit.time)) }
        session.select(point: nil)
        return .seek
    }

    /// Starts dragging what was pressed, once the pointer has moved.
    private func startDragging(_ grab: Grab) -> GraphDrag {
        if case .edge(let key) = grab {
            // The edge stays put; Option pulls its handle out of it.
            guard NSEvent.modifierFlags.contains(.option),
                  let p = session.run.index(of: key.piece), session.run.pieces[p].map.canEase(key.edge)
            else {
                session.explainEdgeKeyframe()
                return .inert
            }
            session.beginDrag()
            return .edgeHandle(key)
        }
        session.beginDrag()
        switch grab {
        case .point(let id, let from):
            return .point(id, from: from, added: false)
        case .handle(let id, let side):
            return .handle(id, side: side)
        case .edge(let key), .edgeHandle(let key):
            return .edgeHandle(key)
        case .line(let piece, let time):
            if let id = session.addMarker(toPiece: piece, atTime: time) { return .point(id, from: time, added: true) }
            session.endDrag("Add Marker")
            return .seek
        }
    }

    private func graphGesture(stack: Stack) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if drag == nil { drag = grab(at: gesture.startLocation, stack: stack) }
                if case .pressed(let grab) = drag {
                    guard hypot(gesture.translation.width, gesture.translation.height) >= Self.dragDistance else { return }
                    drag = startDragging(grab)
                }
                switch drag {
                case .point(let id, let from, _):
                    let target = from + Double(gesture.translation.width) * session.secondsPerPoint
                    let piece = session.run.piece(holdingPoint: id).map { session.run.pieces[$0.piece].id }
                    let snapped = session.snapped(target, tolerance: 8 * session.secondsPerPoint, excluding: piece)
                    snapTime = snapped
                    session.dragEdit {
                        $0.movePoint(id, to: CMTime(seconds: snapped ?? target, preferredTimescale: ClipTimeMap.timescale))
                    }
                case .handle(let id, let side):
                    guard let ease = ease(dragging: side, of: id, to: gesture.location, stack: stack) else { break }
                    // Option moves the handle alone, as in the graph editor.
                    let alone = NSEvent.modifierFlags.contains(.option)
                    session.dragEdit { $0.setHandle(side, ofPoint: id, to: ease, alone: alone) }
                case .edgeHandle(let key):
                    guard let ease = ease(dragging: key, to: gesture.location, stack: stack) else { break }
                    session.dragEdit { $0.setEdgeHandle(key.edge, ofPiece: key.piece, to: ease) }
                case .seek:
                    session.seek(to: session.seconds(atX: gesture.location.x))
                case .pressed, .inert, nil:
                    break
                }
            }
            .onEnded { _ in
                switch drag {
                case .point(_, _, let added): session.endDrag(added ? "Add Marker" : "Move Point")
                case .handle(_, let side): session.endDrag(side == .before ? "Shape Ease In" : "Shape Ease Out")
                case .edgeHandle(let key): session.endDrag("Shape \(MotionDesignSession.edgeHandleName(key.edge))")
                // A click on the line drops a marker on that frame, selected,
                // and moves the playhead there to show it.
                case .pressed(.line(let piece, let time)):
                    session.addMarker(toPiece: piece, atTime: time)
                    session.seek(to: time)
                default: break
                }
                drag = nil
                snapTime = nil
            }
    }

    // MARK: Menus and VoiceOver

    @ViewBuilder
    private var pointMenu: some View {
        if let point = session.selectedPoint {
            Button("Make Hit") { session.setKind(.hit, ofPoint: point.id) }
                .disabled(point.isHit)
            Button("Make Marker") { session.setKind(.marker, ofPoint: point.id) }
                .disabled(point.kind == .marker)
            Button("Set Pace…") { session.focusesPace = true }
            Divider()
            // The keyframe menus' eases, checked as the point is.
            let canEase = session.run.canEase(point: point.id)
            ForEach(TimePoint.presets) { preset in
                Toggle(isOn: Binding(get: { point.easePreset == preset }, set: { _ in session.setEase(preset, ofPoint: point.id) })) {
                    Text(preset.name)
                }
                .disabled(preset != .linear && !canEase)
                .help(MotionDesignSidebar.easeDetail(preset))
            }
            Divider()
            Button("Remove Point", role: .destructive) { session.deleteSelected() }
        } else if let key = session.selectedEdge, let map = session.selectedEdgeMap {
            let name = MotionDesignSession.edgeHandleName(key.edge)
            if !map.canEase(key.edge) {
                Text("No Handle Past a Pace Marker")
            } else if session.selectedEdgeEase == nil {
                Button("Add \(name) Handle") { session.setSelectedEdgeHandle(.easy) }
            } else {
                Button("Remove Handle") { session.setSelectedEdgeHandle(nil) }
            }
        } else {
            Button("Add Marker at Playhead") { session.addMarkerAtPlayhead() }
        }
    }

    /// A point's ease for VoiceOver: its preset, and how far each side's
    /// handle reaches into its stretch and the speed it sets at the point.
    private func easeText(_ point: TimePoint, piece index: Int) -> String {
        let map = session.run.pieces[index].map
        guard let i = map.index(of: point.id) else { return point.easePreset.name }
        let sides: [String] = [TimePoint.Side.before, .after].compactMap { side in
            guard let ease = point.ease(side) else { return nil }
            return "\(side == .before ? "Ease In" : "Ease Out") over \(Int((ease.influence * 100).rounded())) percent at \(Self.speedText(map.speed(side, at: i)))"
        }
        return ([point.easePreset.name] + sides).joined(separator: ", ")
    }

    private var allPoints: [(point: TimePoint, piece: Int)] {
        session.run.pieces.enumerated().flatMap { index, piece in piece.map.points.map { ($0, index) } }
    }

    private var allEdges: [(key: MotionDesignSession.EdgeKey, piece: Int)] {
        session.run.pieces.enumerated().flatMap { index, piece in
            [MotionRun.Edge.start, .end].filter { piece.map.hasEdgeKeyframe($0) }.map { (MotionDesignSession.EdgeKey(piece: piece.id, edge: $0), index) }
        }
    }

    private var graphSummary: String {
        let points = allPoints.map(\.point)
        let hits = points.filter(\.isHit).count
        return "\(session.run.pieces.count) \(session.run.pieces.count == 1 ? "clip" : "clips"), \(hits) \(hits == 1 ? "hit" : "hits"), \(points.count - hits) other points"
    }

    private func pointElement(_ point: TimePoint, piece index: Int) -> some View {
        let kind = point.isHit ? "Hit" : point.pace.map { "Pace marker, \(Self.speedText($0))" } ?? "Marker"
        let speed = session.run.pieces[index].map.index(of: point.id).map { session.run.pieces[index].map.speed(after: $0) }
        return Rectangle()
            .accessibilityLabel("\(kind) at \(session.timecode(point.time))")
            .accessibilityValue("Frame \(session.timecode(point.source))\(speed.map { ", then \(Self.speedText($0))" } ?? ""), \(easeText(point, piece: index))")
            .accessibilityAddTraits(point.id == session.selectedPointID ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { session.select(point: point.id) }
            .accessibilityAdjustableAction { direction in
                session.select(point: point.id)
                session.nudgeSelected(byFrames: direction == .increment ? 1 : -1)
            }
            .accessibilityActions {
                Button("Make hit") { session.setKind(.hit, ofPoint: point.id) }
                Button("Make marker") { session.setKind(.marker, ofPoint: point.id) }
                Button("Set pace") { session.select(point: point.id); session.focusesPace = true }
                // The keyframe eases, named as on a keyframe.
                if session.run.canEase(point: point.id) {
                    ForEach(TimePoint.presets.filter { $0 != point.easePreset }) { preset in
                        Button(preset.name) { session.setEase(preset, ofPoint: point.id) }
                    }
                }
                ForEach([TimePoint.Side.before, .after], id: \.self) { side in
                    if point.ease(side) != nil { handleActions(side, of: point) }
                }
                Button("Remove") { session.select(point: point.id); session.deleteSelected() }
            }
    }

    /// An edge keyframe for VoiceOver, with its one handle's actions, as
    /// Option-dragging it and its handle do.
    private func edgeElement(_ key: MotionDesignSession.EdgeKey, piece index: Int) -> some View {
        let map = session.run.pieces[index].map
        let name = MotionDesignSession.edgeHandleName(key.edge)
        let frame = key.edge == .start ? map.trimStart : map.trimEnd
        let ease = map.edgeEase(key.edge).map { "\(name) over \(Int(($0.influence * 100).rounded())) percent at \(Self.speedText(map.speed(at: key.edge)))" }
        let select = { session.select(edge: key) }
        return Rectangle()
            .accessibilityLabel(key.edge == .start ? "Clip's first frame" : "Clip's last frame")
            .accessibilityValue("Frame \(session.timecode(frame)), \(ease ?? "Linear")")
            .accessibilityAddTraits(key == session.selectedEdge ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select() }
            .accessibilityActions {
                if !map.canEase(key.edge) {
                    // Held straight by the pace before it: nothing to do.
                } else if map.edgeEase(key.edge) == nil {
                    Button("Add \(name) handle") { select(); session.setSelectedEdgeHandle(.easy) }
                } else {
                    Button("Longer \(name)") { select(); session.reshapeSelectedEdge(by: 0.1) }
                    Button("Shorter \(name)") { select(); session.reshapeSelectedEdge(by: -0.1) }
                    Button("Faster \(name)") { changeSpeed(of: key, by: 1.25) }
                    Button("Slower \(name)") { changeSpeed(of: key, by: 0.8) }
                    Button("Remove handle") { select(); session.setSelectedEdgeHandle(nil) }
                }
            }
    }

    private func changeSpeed(of key: MotionDesignSession.EdgeKey, by factor: Double) {
        session.select(edge: key)
        guard let map = session.selectedEdgeMap else { return }
        // From a stop, faster starts at a tenth of the straight speed.
        let speed = map.speed(at: key.edge)
        session.setSelectedEdgeSpeed(to: speed > 0 ? speed * factor : (factor > 1 ? map.straightSpeed(of: key.edge) / 10 : 0))
    }

    /// What dragging a handle does, as VoiceOver actions: a tenth of the
    /// stretch longer or shorter, and a quarter faster or slower at the
    /// point.
    @ViewBuilder
    private func handleActions(_ side: TimePoint.Side, of point: TimePoint) -> some View {
        let name = side == .before ? "Ease In" : "Ease Out"
        Button("Longer \(name)") { session.select(point: point.id); session.reshapeSelectedEase(side, by: 0.1) }
        Button("Shorter \(name)") { session.select(point: point.id); session.reshapeSelectedEase(side, by: -0.1) }
        Button("Faster \(name)") { changeSpeed(side, of: point, by: 1.25) }
        Button("Slower \(name)") { changeSpeed(side, of: point, by: 0.8) }
    }

    private func changeSpeed(_ side: TimePoint.Side, of point: TimePoint, by factor: Double) {
        session.select(point: point.id)
        guard let place = session.selectedPlace else { return }
        // From a stop, faster starts at a tenth of the straight speed.
        let speed = place.map.speed(side, at: place.index)
        let floor = place.map.straightSpeed(side, of: place.index) / 10
        session.setSelectedSpeed(side, to: speed > 0 ? speed * factor : (factor > 1 ? floor : 0))
    }

    // MARK: Music

    /// The music area: one lane for a single Music layer, and for several a
    /// lane each, in their order, sharing up to twice that.
    private var musicHeight: CGFloat {
        let count = session.musicLayers.count
        return count <= 1 ? Self.musicHeight : min(CGFloat(count) * 64, 2 * Self.musicHeight)
    }

    private var laneHeight: CGFloat {
        musicHeight / CGFloat(max(1, session.musicLayers.count))
    }

    /// Which lane holds the song in charge at `seconds`, if one does.
    private func lane(at seconds: Double) -> Int? {
        guard let song = session.timeline.song(at: CMTime(seconds: seconds, preferredTimescale: 48_000)) else { return nil }
        return session.musicLayers.firstIndex { layer in layer.clips.contains { $0.id == song.id } }
    }

    private func musicLane(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(session.musicLayers) { layer in
                    layerLane(layer, width: width)
                }
            }
            Canvas { context, size in
                guard session.showsBeats else { return }
                drawBeats(in: &context, height: size.height, strong: 0.9, weak: 0.45)
            }
            .allowsHitTesting(false)
            if session.musicLayers.isEmpty {
                Text("No song under these clips")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: width, height: musicHeight, alignment: .topLeading)
        .clipped()
        .background(Design.Surface.well.color)
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Music")
        .accessibilityValue(musicSummary)
    }

    private var musicSummary: String {
        let layers = session.musicLayers.map { session.project.displayName(of: $0, in: session.timeline) }
        guard !layers.isEmpty else { return "No song" }
        let beats = "\(session.beats.count) beats"
        return layers.count == 1 ? "\(layers[0]), \(beats)" : "\(layers.joined(separator: ", ")), the first with a song at a moment leading; \(beats)"
    }

    /// One Music layer's songs within the window, dimmed where a layer
    /// above has the song.
    private func layerLane(_ layer: TimelineLayer, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layer.clips) { clip in
                songBlock(clip, on: layer, width: width)
            }
            if session.musicLayers.count > 1 {
                Text(session.project.displayName(of: layer, in: session.timeline))
                    .font(Design.Typeface.tag)
                    .foregroundStyle(Design.textSecondary)
                    .padding(.horizontal, Design.Space.tight)
                    .background(Design.Surface.well.color.opacity(0.8), in: RoundedRectangle(cornerRadius: Design.Radius.chip))
                    .padding(Design.Space.tight)
            }
            if layer.id != session.musicLayers.last?.id {
                Design.hairline.frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: width, height: laneHeight, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func songBlock(_ clip: TimelineClip, on layer: TimelineLayer, width: CGFloat) -> some View {
        let window = session.window
        let x0 = session.x(of: max(clip.startOffset.seconds, window.start)), x1 = session.x(of: min(clip.endOffset.seconds, window.end))
        if x1 > x0, x1 > 0, x0 < width, case .media(let id) = clip.source, let media = session.project.mediaClip(id: id) {
            let drawn0 = max(0, x0), drawn1 = min(width, x1)
            let source = clip.sourceTime(atTimelineTime: CMTime(seconds: session.seconds(atX: drawn0), preferredTimescale: 48_000))
            let led = session.timeline.songStretches(of: clip, onLayer: layer.id)
            ZStack(alignment: .topLeading) {
                Design.ClipTone.music.color.opacity(0.18)
                if let url = media.url {
                    // Drawn at the single lane's height, where the waveform
                    // shows in full, then fitted to this one.
                    ClipWaveform(
                        url: url, fileStart: media.fileTime(forSourceTime: source).seconds,
                        secondsPerPoint: session.secondsPerPoint, width: drawn1 - drawn0, height: Self.musicHeight
                    )
                    .scaleEffect(x: 1, y: laneHeight / Self.musicHeight, anchor: .top)
                }
                // Where a layer above has the song, this one only waits.
                Canvas { context, size in
                    var from = drawn0
                    for stretch in led + [CMTimeRange(start: clip.endOffset, duration: .zero)] {
                        let to = min(drawn1, session.x(of: stretch.start.seconds))
                        if to > from {
                            context.fill(Path(CGRect(x: from - drawn0, y: 0, width: to - from, height: size.height)), with: .color(Design.Surface.well.color.opacity(0.5)))
                        }
                        from = max(from, session.x(of: stretch.end.seconds))
                    }
                }
            }
            .frame(width: drawn1 - drawn0, height: laneHeight, alignment: .topLeading)
            .offset(x: drawn0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Over every lane

    /// Each hit's pin from its frame to its beat, the playhead, and where a
    /// drag snapped, drawn over the lanes.
    private func markings(width: CGFloat, height: CGFloat, graphHeight: CGFloat) -> some View {
        let stack = stack(height: graphHeight, width: width)
        let graphTop = Self.rulerHeight + Self.filmHeight
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                for (index, piece) in session.run.pieces.enumerated() {
                    for point in piece.map.points where point.isHit {
                        let at = location(of: point, piece: index, stack: stack)
                        var pin = Path()
                        pin.move(to: CGPoint(x: at.x, y: Self.rulerHeight))
                        pin.addLine(to: CGPoint(x: at.x, y: graphTop + at.y - 8))
                        pin.move(to: CGPoint(x: at.x, y: graphTop + at.y + 8))
                        pin.addLine(to: CGPoint(x: at.x, y: size.height))
                        context.stroke(pin, with: .color(Design.snap.opacity(0.7)), lineWidth: 1)
                        // On the lane of the song in charge there.
                        let lane = CGFloat(lane(at: point.time.seconds) ?? 0)
                        let y = size.height - musicHeight + (lane + 0.5) * laneHeight
                        context.fill(Path(ellipseIn: CGRect(x: at.x - 3, y: y - 3, width: 6, height: 6)), with: .color(Design.snap))
                    }
                }
            }
            // The timeline's own playhead, its head at the top of the
            // ruler, and its snap line; while playing it runs on the
            // player's clock.
            let x = session.x(of: session.playhead)
            PlayheadRail(
                playheadX: x,
                isPlayheadVisible: (-1...(width + 1)).contains(x),
                snapX: (snapTime ?? session.dragSnapTime).map { session.x(of: $0) },
                height: height,
                following: session.isPlaying
                    ? PlayheadRail.Following(
                        player: session.playback.player,
                        pixelsPerSecond: CGFloat(1 / session.secondsPerPoint),
                        originX: session.x(of: 0),
                        seconds: session.window.end,
                        generation: session.playback.itemSwaps
                    )
                    : nil
            )
            .frame(width: width, height: height)
            MotionSkimLine(session: session, height: height)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where the pointer skims the lanes, drawn as the timeline's skimmer
/// (`TimelineSkimLine`): a red hairline without a head. It reads the skim
/// itself, so following the pointer redraws only this line.
private struct MotionSkimLine: View {
    let session: MotionDesignSession
    let height: CGFloat

    var body: some View {
        if let time = session.playback.skimTime {
            Rectangle()
                .fill(Design.skim.opacity(0.7))
                .frame(width: 1, height: height)
                .offset(x: session.x(of: time.seconds).rounded() - 0.5)
        }
    }
}
