import CoreMedia
import SwiftUI

/// The footage, time graph and music on one timeline. Every clip is a
/// chain of markers: clicking toggles a lock, dragging retimes, and
/// Option-dragging pulls out a handle. Locked markers have a pin through
/// the lanes and stay while the other picked markers move. Handles shape
/// the line as keyframe handles do in the graph editor.
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
        /// marker selects it and toggles its lock.
        case pressed(Grab)
        /// Points moving together as `dragged` is dragged, from where each
        /// was, in seconds.
        case points(dragged: UUID, from: [UUID: Double], added: Bool)
        /// A lasso from a point in the graph, adding to `kept`.
        case lasso(from: CGPoint, kept: Set<UUID>, click: SelectClick)
        case handle(UUID, side: TimePoint.Side)
        case seek
        /// A drag on a single locked marker.
        case inert
    }

    private enum Grab {
        case point(UUID, from: Double, click: SelectClick)
        case handle(UUID, side: TimePoint.Side)
        /// The line, where a click or a drag drops a marker.
        case line(piece: UUID, time: Double)
    }

    private static let dragDistance: CGFloat = 3

    @State private var drag: GraphDrag?
    /// The press the graph's drag follows, which a sheet can cut short.
    @State private var press = DragPress()
    /// The lasso being dragged across the graph.
    @State private var lassoRect: CGRect?
    /// Where the drag snapped, to draw.
    @State private var snapTime: Double?
    @State private var graphModifiers: NSEvent.ModifierFlags = []

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
        // A sheet over the panel (Cancel's question, or a conflict to
        // agree to) takes the drag's release: it lets go now.
        .onDraftPanelSheet { abandonDrag() }
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
        .overlay(alignment: .topLeading) { lassoOverlay }
        .onContinuousHover { phase in
            if case .active(let location) = phase {
                let over = point(at: location, stack: stack) != nil || line(at: location, stack: stack) != nil
                (over ? NSCursor.pointingHand : NSCursor.arrow).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        // A right-click picks the point or edge under it first, so its
        // menu acts on what was clicked rather than on what was picked.
        .background(SecondaryClickMonitor(
            onSecondaryDown: { location in pickForMenu(at: location, stack: stack) },
            onModifiers: { graphModifiers = $0 }
        ))
        .contextMenu { pointMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Time graph")
        .accessibilityValue(graphSummary)
        .accessibilityChildren {
            ForEach(allPoints, id: \.point.id) { entry in
                pointElement(entry.point, piece: entry.piece)
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

    /// Each stretch's speed, over its middle, where it has room; stretches
    /// either side of a point at one speed share one reading.
    private func drawSpeeds(of piece: MotionRun.Piece, clip: TimelineClip, index: Int, stack: Stack, in context: inout GraphicsContext) {
        let edges = piece.map.points.map(\.time.seconds)
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

    /// Locked markers are larger and brighter; eased sides pinch in.
    private func drawPoint(_ point: TimePoint, at center: CGPoint, in context: inout GraphicsContext) {
        let isSelected = session.pickedPoints.contains(point.id)
        let size: CGFloat = point.locked ? 13 : 11
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let shape = KeyframeMarkShape(easedIn: point.easeIn != nil, easedOut: point.easeOut != nil, holds: false).path(in: rect)
        context.fill(shape, with: .color(point.locked ? Design.snap : Design.textSecondary))
        context.stroke(shape, with: .color(.black.opacity(0.5)), lineWidth: 0.5)
        if isSelected {
            context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)), with: .color(Design.accent), lineWidth: 1.5)
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

    /// The clip whose line passes near `location`, and the time of its
    /// nearest spot. Near is measured to the line as drawn, not straight up
    /// or down: zoomed out, a line climbs steeply, and the height under the
    /// pointer changes by more than the reach from one point across to the
    /// next.
    private func line(at location: CGPoint, stack: Stack) -> (piece: UUID, time: Double)? {
        let reach: CGFloat = 12
        var best: (piece: UUID, x: CGFloat, distance: CGFloat)?
        for (index, piece) in session.run.pieces.enumerated() {
            let clip = session.drafted(piece)
            let start = max(session.x(of: clip.startOffset.seconds), location.x - reach)
            let end = min(session.x(of: clip.endOffset.seconds), location.x + reach)
            guard end >= start else { continue }
            func spot(_ x: CGFloat) -> CGPoint {
                let time = CMTime(seconds: session.seconds(atX: x), preferredTimescale: ClipTimeMap.timescale)
                let source = CMTimeClampToRange(clip.sourceTime(atTimelineTime: time), range: CMTimeRange(start: clip.trimStart, end: clip.trimEnd))
                return CGPoint(x: x, y: stack.y(piece: index, source: source))
            }
            var a = spot(start)
            var x = start
            repeat {
                x = min(x + 1, end)
                let b = spot(x)
                // The nearest place on the segment from a to b.
                let dx = b.x - a.x, dy = b.y - a.y
                let along = dx == 0 && dy == 0 ? 0 : (((location.x - a.x) * dx + (location.y - a.y) * dy) / (dx * dx + dy * dy)).clamped(between: 0, and: 1)
                let near = CGPoint(x: a.x + along * dx, y: a.y + along * dy)
                let distance = hypot(near.x - location.x, near.y - location.y)
                if distance <= reach, distance < (best?.distance ?? .infinity) { best = (piece.id, near.x, distance) }
                a = b
            } while x < end
        }
        return best.map { ($0.piece, session.seconds(atX: $0.x)) }
    }

    /// What a press at `location` takes hold of: a selected point's ease
    /// handle, a point (a plain press on one not picked picks it alone; one
    /// picked keeps the rest, for a drag to move them all), the line, or
    /// else empty space, where a drag draws a lasso.
    private func grab(at location: CGPoint, stack: Stack) -> GraphDrag {
        if let handle = easeHandles(stack: stack).first(where: { hypot($0.point.x - location.x, $0.point.y - location.y) <= 7 }) {
            return .pressed(handle.grab)
        }
        let click = SelectClick(graphModifiers)
        if let id = point(at: location, stack: stack), let found = session.run.piece(holdingPoint: id) {
            if click == .only, !session.pickedPoints.contains(id) { session.select(point: id) }
            return .pressed(.point(id, from: session.run.pieces[found.piece].map.points[found.point].time.seconds, click: click))
        }
        if let hit = line(at: location, stack: stack) { return .pressed(.line(piece: hit.piece, time: hit.time)) }
        return .lasso(from: location, kept: SelectClick.lassoAdds(graphModifiers) ? session.pickedPoints.items : [], click: click)
    }

    /// The points inside `rect`.
    private func points(in rect: CGRect, stack: Stack) -> Set<UUID> {
        var ids: Set<UUID> = []
        for (index, piece) in session.run.pieces.enumerated() {
            for point in piece.map.points where rect.contains(location(of: point, piece: index, stack: stack)) { ids.insert(point.id) }
        }
        return ids
    }

    /// Where each picked point is, in seconds.
    private var pickedTimes: [UUID: Double] {
        var from: [UUID: Double] = [:]
        for id in session.pickedPointIDs {
            if let (p, i) = session.run.piece(holdingPoint: id) { from[id] = session.run.pieces[p].map.points[i].time.seconds }
        }
        return from
    }

    @ViewBuilder
    private var lassoOverlay: some View {
        if let lassoRect {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Design.accent.opacity(0.12))
                .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Design.accent.opacity(0.9), lineWidth: 1) }
                .frame(width: lassoRect.width, height: lassoRect.height)
                .offset(x: lassoRect.minX, y: lassoRect.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Starts dragging what was pressed, once the pointer has moved.
    private func startDragging(_ grab: Grab, translation: CGSize) -> GraphDrag {
        session.beginDrag()
        switch grab {
        case .point(let id, let from, let click):
            if graphModifiers.contains(.option), let (p, i) = session.run.piece(holdingPoint: id) {
                let map = session.run.pieces[p].map
                let side: TimePoint.Side = i == 0 ? .after : i == map.points.count - 1 ? .before : translation.width < 0 ? .before : .after
                session.select(point: id)
                return .handle(id, side: side)
            }
            if let (p, i) = session.run.piece(holdingPoint: id), session.run.pieces[p].map.points[i].locked {
                session.explainLockedMarker()
                if session.pickedPointIDs.count <= 1 { return .inert }
            }
            // A point Command- or Shift-dragged joins those picked.
            if !session.pickedPoints.contains(id) { session.pickedPoints.press(id, click) }
            var times = pickedTimes
            times[id] = from
            return .points(dragged: id, from: times, added: false)
        case .handle(let id, let side):
            return .handle(id, side: side)
        case .line(let piece, let time):
            if let id = session.addMarker(toPiece: piece, atTime: time) { return .points(dragged: id, from: [id: time], added: true) }
            session.endDrag("Add Marker")
            return .seek
        }
    }

    private func graphGesture(stack: Stack) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                // What was left of a press whose release a sheet took goes.
                if press.begins(gesture), drag != nil {
                    session.cancelDrag()
                    resetDrag()
                }
                guard !press.isAbandoned else { return }
                let translation = press.translation(gesture)
                if drag == nil { drag = grab(at: press.origin, stack: stack) }
                if case .pressed(let grab) = drag {
                    guard hypot(translation.width, translation.height) >= Self.dragDistance else { return }
                    drag = startDragging(grab, translation: translation)
                }
                switch drag {
                case .points(let id, let from, _):
                    guard let start = from[id] else { break }
                    let target = start + Double(translation.width) * session.secondsPerPoint
                    let piece = session.run.piece(holdingPoint: id).map { session.run.pieces[$0.piece].id }
                    let snapped = session.snapped(target, tolerance: 8 * session.secondsPerPoint, excluding: piece)
                    snapTime = snapped
                    session.dragEdit { MotionDesignSession.movePoints(from, by: (snapped ?? target) - start, in: &$0) }
                case .lasso(let from, let kept, _):
                    guard hypot(translation.width, translation.height) >= Self.dragDistance else { break }
                    let rect = CGRect(
                        x: min(from.x, gesture.location.x), y: min(from.y, gesture.location.y),
                        width: abs(translation.width), height: abs(translation.height)
                    )
                    lassoRect = rect
                    session.lasso(points: points(in: rect, stack: stack), keeping: kept)
                case .handle(let id, let side):
                    guard let ease = ease(dragging: side, of: id, to: gesture.location, stack: stack) else { break }
                    // Option moves the handle alone, as in the graph editor.
                    let alone = graphModifiers.contains(.option)
                    session.dragEdit { $0.setHandle(side, ofPoint: id, to: ease, alone: alone) }
                case .seek:
                    session.seek(to: session.seconds(atX: gesture.location.x))
                case .pressed, .inert, nil:
                    break
                }
            }
            .onEnded { gesture in
                let abandoned = press.isAbandoned
                press.end()
                guard !abandoned else { return resetDrag() }
                switch drag {
                case .points(_, let from, let added): session.endDrag(added ? "Add Marker" : from.count > 1 ? "Move Points" : "Move Point")
                // A click on a point picks it as the keys held say.
                case .pressed(.point(let id, _, let click)):
                    session.click(point: id, click)
                // A click in empty space moves the playhead there and,
                // without Shift or Command, picks nothing.
                case .lasso(_, _, let click) where lassoRect == nil:
                    session.seek(to: session.seconds(atX: gesture.location.x))
                    if click == .only {
                        session.select(point: nil)
                    }
                case .handle(_, let side): session.endDrag(side == .before ? "Shape Ease In" : "Shape Ease Out")
                case .inert: session.endDrag("Move Marker")
                // A click on the line drops a marker on that frame, selected,
                // and moves the playhead there to show it.
                case .pressed(.line(let piece, let time)):
                    session.addMarker(toPiece: piece, atTime: time)
                    session.seek(to: time)
                default: break
                }
                resetDrag()
            }
    }

    private func resetDrag() {
        drag = nil
        snapTime = nil
        lassoRect = nil
    }

    /// Lets go of the drag under way, putting the draft back as it was
    /// when the drag began, as Escape does: a sheet opening over the panel
    /// takes its release. The rest of its press is ignored.
    private func abandonDrag() {
        guard drag != nil else { return }
        session.cancelDrag()
        resetDrag()
        press.abandon()
    }

    // MARK: Menus and VoiceOver

    /// Before the graph's menu opens: the point under the pointer is picked
    /// alone, unless it is among those picked, which the menu then acts on
    /// together; else an edge keyframe there. Elsewhere the menu acts on
    /// what is picked.
    private func pickForMenu(at location: CGPoint, stack: Stack) {
        if let id = point(at: location, stack: stack) {
            if !session.pickedPoints.contains(id) { session.select(point: id) }

        }
    }

    @ViewBuilder
    private var pointMenu: some View {
        let picked = session.pickedPointIDs
        if picked.count > 1 {
            Button("Lock Markers") { session.setLockedOfPicked(true) }
            Button("Unlock Markers") { session.setLockedOfPicked(false) }
            Divider()
            ForEach(TimePoint.presets) { preset in
                Button(preset.name) { session.setEaseOfPicked(preset) }
                    .help(MotionDesignSidebar.easeDetail(preset))
            }
            Divider()
            Button("Remove Markers", role: .destructive) { session.deleteSelected() }
                .disabled(!session.canRemovePicked)
        } else if let point = session.selectedPoint {
            Button(point.locked ? "Unlock" : "Lock") { session.setLocked(!point.locked, ofPoint: point.id) }
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
            Button("Remove Marker", role: .destructive) { session.deleteSelected() }
                .disabled(point.locked || session.selectedPlace?.map.isEdge(point.id) == true)
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

    private var graphSummary: String {
        let points = allPoints.map(\.point)
        let locked = points.filter(\.locked).count
        return "\(session.run.pieces.count) \(session.run.pieces.count == 1 ? "clip" : "clips"), \(locked) \(locked == 1 ? "locked marker" : "locked markers"), \(points.count - locked) unlocked markers"
    }

    private func pointElement(_ point: TimePoint, piece index: Int) -> some View {
        let map = session.run.pieces[index].map
        let kind = map.points.first?.id == point.id ? "First frame marker" : map.points.last?.id == point.id ? "Last frame marker" : "Marker"
        let speed = session.run.pieces[index].map.index(of: point.id).map { session.run.pieces[index].map.speed(after: $0) }
        return Rectangle()
            .accessibilityLabel("\(kind), \(point.locked ? "locked" : "unlocked"), at \(session.timecode(point.time))")
            .accessibilityValue("Frame \(session.timecode(point.source))\(speed.map { ", then \(Self.speedText($0))" } ?? ""), \(easeText(point, piece: index))")
            .accessibilityAddTraits(session.pickedPoints.contains(point.id) ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { session.select(point: point.id) }
            .accessibilityAdjustableAction { direction in
                session.select(point: point.id)
                session.nudgeSelected(byFrames: direction == .increment ? 1 : -1)
            }
            .accessibilityActions {
                Button(session.pickedPoints.contains(point.id) ? "Remove from selection" : "Add to selection") {
                    session.click(point: point.id, .toggle)
                }
                Button(point.locked ? "Unlock" : "Lock") { session.setLocked(!point.locked, ofPoint: point.id) }
                // The keyframe eases, named as on a keyframe.
                if session.run.canEase(point: point.id) {
                    ForEach(TimePoint.presets.filter { $0 != point.easePreset }) { preset in
                        Button(preset.name) { session.setEase(preset, ofPoint: point.id) }
                    }
                }
                ForEach([TimePoint.Side.before, .after], id: \.self) { side in
                    if point.ease(side) != nil { handleActions(side, of: point) }
                }
                if !map.isEdge(point.id) {
                    Button("Remove") { session.select(point: point.id); session.deleteSelected() }.disabled(point.locked)
                }
            }
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

    /// Each locked marker's pin from its frame to its beat, the playhead, and where a
    /// drag snapped, drawn over the lanes.
    private func markings(width: CGFloat, height: CGFloat, graphHeight: CGFloat) -> some View {
        let stack = stack(height: graphHeight, width: width)
        let graphTop = Self.rulerHeight + Self.filmHeight
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                for (index, piece) in session.run.pieces.enumerated() {
                    for point in piece.map.points where point.locked {
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

/// Hears a right-click, or Control-click, on the view it backs, in the
/// view's own coordinates, before the context menu it opens is built. It
/// only listens: the click goes on to open the menu.
private struct SecondaryClickMonitor: NSViewRepresentable {
    let onSecondaryDown: (CGPoint) -> Void
    let onModifiers: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onSecondaryDown = onSecondaryDown
        view.onModifiers = onModifiers
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onSecondaryDown = onSecondaryDown
        view.onModifiers = onModifiers
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onSecondaryDown: ((CGPoint) -> Void)?
        var onModifiers: ((NSEvent.ModifierFlags) -> Void)?
        private var monitor: Any?

        // Top-left origin, as the SwiftUI view it backs.
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            let local = convert(event.locationInWindow, from: nil)
            if bounds.contains(local) || event.type == .leftMouseDragged { onModifiers?(event.modifierFlags) }
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return }
            if bounds.contains(local) { onSecondaryDown?(local) }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
