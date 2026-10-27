import AppKit
import CoreMedia
import Observation
import SwiftUI

/// One parameter's keyframes as a value graph, for its HUD panel: a line
/// per component over the parameter's time (a clip's source time, or the
/// timeline's), each keyframe a point on it. Drag a point to move the
/// keyframe in time (on frames) and value; Shift keeps it to one
/// direction. Click a point to select it and show the bezier handles of
/// its eased sides. Dragging a handle shapes that side's ease and swings
/// the other side's handle to stay in line with it, at its own length;
/// with Option it moves alone. A handle dragged onto its keyframe goes,
/// leaving that side linear. Option-click a point to switch it between
/// linear and bezier (Easy Ease); Option-drag one pulls a handle out of a
/// linear side, the side the drag heads to. Escape cancels a drag. Click
/// elsewhere to move the playhead there; double-click to add a keyframe,
/// or select the one there. The arrow keys move the selected keyframe a
/// frame or a point at a time (ten with Shift), and Delete deletes it.
/// The buttons act on the selected keyframe, or the one at the playhead;
/// the right-click menu on the keyframe under the pointer, or else the
/// same.
///
/// The sliders under the graph zoom values and time, each step by the same
/// ratio wherever the zoom is, time no further out than the clip; pinching
/// zooms time about the pointer (values with Option), and scrolling moves
/// the view, one way per swipe. The legend's chips show or hide each
/// component, and Separate Scales draws each on its own scale. Linked with
/// other graphs in one panel (`link`), time is theirs together: zooming or
/// scrolling it in one moves them all. The panel then has one time slider
/// and one row of presets for them all (`KeyframeGraphStack`), and each
/// graph's own row names it, with its value slider and Unlink.
struct KeyframeGraphView: View {
    let hud: KeyframeGraphHUDs
    let key: ParameterKey
    let input: GraphInput
    /// The panel's graphs, which hold this one's selection; with others,
    /// this one shares its time with them.
    var link: KeyframeGraphLink?

    /// The keyframes as a drag in progress leaves them, drawn instead of
    /// the project's and saved when the drag ends.
    @State private var draft: AnimatedValue<ComponentValue>?
    /// A finished drag's keyframes, drawn until the project has them, so
    /// the old ones don't show for a frame on release.
    @State private var committed: AnimatedValue<ComponentValue>?
    /// Lets go of `committed` if its edit never lands; the last one only.
    @State private var commitFallback: Task<Void, Never>?
    @State private var drag: Drag?
    /// Escape cancelled the drag in progress: the rest of it does nothing.
    @State private var dragCancelled = false
    @State private var ownSelected: CMTime?
    @State private var viewport = KeyframeGraphViewport()
    /// The pinch's magnification when it last changed the zoom.
    @State private var lastMagnification: CGFloat?
    /// What the pinch zooms, chosen as it starts: values with Option, else
    /// time.
    @State private var pinchAxis: Axis?
    /// The way a trackpad swipe scrolls, chosen by its first movement, so a
    /// diagonal swipe through time doesn't drift the values.
    @State private var scrollAxis: Axis?
    @State private var lastScrollPhase: ScrollInputPhase?
    @State private var pointer = GraphPointer()
    @FocusState private var isFocused: Bool
    /// The zooms' edges: past them the plot stretches and springs back.
    @State private var timeBand = RubberBandZoom()
    @State private var valueBand = RubberBandZoom()
    /// Time's scroll edge: past the clip's ends the plot slides on and
    /// springs back. Values scroll without end, so they have none.
    @State private var timeScrollBand = RubberBandScroll()

    private enum Target: Equatable {
        case keyframe(CMTime, component: Int)
        case handle(segment: Int, outgoing: Bool)
        /// Option on a keyframe: a click switches it between linear and
        /// bezier; a drag pulls a handle out of the side it heads to.
        case pull(CMTime)
        case scrub

        /// The keyframe it is, if it is one.
        var keyframeTime: CMTime? {
            switch self {
            case .keyframe(let time, _), .pull(let time): time
            case .handle, .scrub: nil
            }
        }
    }

    /// Closer than this on screen, a dragged handle goes and its side turns
    /// linear.
    private static let collapseDistance: CGFloat = 6
    /// How near a point a click must be to take it.
    private static let reach: CGFloat = 8

    private struct Drag {
        var target: Target
        var layout: KeyframeGraphLayout
        var original: AnimatedValue<ComponentValue>
        var segments: [KeyframeGraphLayout.Segment]
        /// Where a dragged keyframe is now, selected when the drag ends.
        var movedTo: CMTime?
        /// The way Shift keeps the drag to, chosen once it has gone far
        /// enough to tell.
        var lockedAxis: Axis?
        /// The selection before the drag, which Escape puts back.
        var selectedBefore: CMTime?
    }

    private static let palette: [Color] = [Design.statusDanger, Design.statusDone, Design.accent, Design.keyframe]

    /// Everything the graph needs about the parameter right now.
    private struct Context {
        var value: AnimatedValue<ComponentValue>
        var offset: [Double]
        var timeline: Timeline
        var axis: ParameterTimeAxis
        var segments: [KeyframeGraphLayout.Segment]
        /// The parameter's span with room past its ends, and the time that
        /// fits its keyframes.
        var padded: ClosedRange<Double>
        var fit: ClosedRange<Double>
        /// The link's shared time in the parameter's, while linked.
        var sharedTimes: ClosedRange<Double>?
    }

    /// The link when the graph shares its time with others in it.
    private var shared: KeyframeGraphLink? {
        link?.isLinked == true ? link : nil
    }

    /// The selected keyframe, kept in the link for the panel's presets.
    private var selected: CMTime? {
        get { link.map { $0.selected[key] } ?? ownSelected }
        nonmutating set {
            if let link { link.selected[key] = newValue } else { ownSelected = newValue }
        }
    }

    var body: some View {
        if let timeline = hud.project.timeline(id: key.timelineID), let stored = hud.project.components(of: key),
           let axis = hud.project.timeAxis(of: key) {
            let c = context(draft ?? committed ?? stored, timeline: timeline, axis: axis)
            VStack(spacing: 0) {
                toolbar(c)
                Divider()
                if c.value.keyframes.count < 2 {
                    Text(c.value.isAnimated
                         ? "Add a second keyframe to shape the curve between them."
                         : "\(key.parameter.name) isn't animated. Turn on its stopwatch to add keyframes.")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        let layout = drag?.layout ?? layout(c, size: geometry.size)
                        graph(c, layout: layout)
                            .rubberBand(timeBandBinding, axis: .horizontal)
                            .rubberBand($valueBand, axis: .vertical)
                            .rubberBandScroll(shared?.timeScrollBand ?? timeScrollBand, length: layout.plot.width)
                            .rubberBandSettling(timeScrollBandBinding)
                            .clipped()
                        .onChange(of: input.scroll) { _, scroll in
                            guard let scroll else { return }
                            // Linked graphs share the panel's input: the one
                            // under the pointer takes the scroll.
                            if shared != nil, let at = scroll.location, !geometry.frame(in: .global).contains(at) { return }
                            scrolled(scroll, c, layout: layout)
                        }
                    }
                    if shared == nil {
                        Divider()
                        zoomBar(c)
                    }
                }
            }
            .background(Color.black.opacity(0.2))
            .onChange(of: stored) { _, stored in
                committed = nil
                // An undo, or an edit elsewhere, can take the selected
                // keyframe away.
                if drag == nil, let time = selected, stored.keyframe(at: time) == nil { selected = nil }
            }
            .onChange(of: link?.fits) { _, _ in fitValues() }
        } else {
            Text("This layer is no longer on the timeline.")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func context(_ value: AnimatedValue<ComponentValue>, timeline: Timeline, axis: ParameterTimeAxis) -> Context {
        let padded = KeyframeGraphLayout.padded(axis.span)
        return Context(
            value: value, offset: key.parameter.displayOffset(frameSize: timeline.frameSize), timeline: timeline, axis: axis,
            segments: KeyframeGraphLayout.segments(of: value), padded: padded,
            fit: KeyframeGraphLayout.fitTimes(value, span: padded, frame: timeline.frameDuration.seconds),
            sharedTimes: shared?.keyTimes(for: axis, in: hud.project)
        )
    }

    private func layout(_ c: Context, size: CGSize) -> KeyframeGraphLayout {
        KeyframeGraphLayout(
            c.value, offset: c.offset, size: size, viewport: viewport, span: c.axis.span, frame: c.timeline.frameDuration.seconds,
            times: c.sharedTimes ?? viewport.shownTimes(fit: c.fit, span: c.padded)
        )
    }

    /// Time's zoom edge: the link's while linked, so all its graphs stretch
    /// together.
    private var timeBandBinding: Binding<RubberBandZoom> {
        guard let shared else { return $timeBand }
        return Binding(get: { shared.timeBand }, set: { shared.timeBand = $0 })
    }

    private var timeScrollBandBinding: Binding<RubberBandScroll> {
        guard let shared else { return $timeScrollBand }
        return Binding(get: { shared.timeScrollBand }, set: { shared.timeScrollBand = $0 })
    }

    private func endTimePinch() {
        if let shared { shared.timeBand.endPinch() } else { timeBand.endPinch() }
    }

    /// The curves under the marks, each drawn by a view of its own that
    /// redraws only when what it shows changes: a new selection redraws
    /// the marks alone, and the playhead (its own line) neither.
    private func graph(_ c: Context, layout: KeyframeGraphLayout) -> some View {
        let shown = visible(c.value.value.values.count)
        // A dragged keyframe is marked, with its handles, where it is now.
        let marked = drag?.movedTo ?? selected
        let timecodes = [layout.times.lowerBound, layout.times.upperBound].map { seconds in
            let time = c.axis.timelineTime(atKey: CMTime(seconds: seconds, preferredTimescale: ParameterTimeAxis.timescale))
            return CMTimeMaximum(time, .zero).timecode(frameRate: c.timeline.frameRate)
        }
        return Curves(
            value: c.value, offset: c.offset, layout: layout, shown: shown, separateScales: viewport.separateScales,
            parameter: key.parameter, span: c.axis.span, timecodes: timecodes
        )
        .equatable()
        .overlay {
            Marks(
                value: c.value, offset: c.offset, layout: layout, shown: shown, selected: marked,
                handles: handles(c, layout: layout, selected: marked, shown: shown)
            )
            .equatable()
        }
        .overlay { HoverRing(pointer: pointer) { drag == nil ? hit(at: $0, c, layout: layout).point : nil } }
        .overlay { GraphPlayheadLine(playback: hud.playback, parked: hud.playhead, axis: c.axis, layout: layout) }
        .contentShape(Rectangle())
        .gesture(dragGesture(c, layout: layout))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
            // Only ever adds, so a stray double-click can't delete.
            let time = c.axis.snapped(layout.seconds(atX: tap.location.x))
            if c.value.keyframe(at: time) == nil { addKeyframe(at: time) }
            selected = time
        })
        .simultaneousGesture(MagnifyGesture()
            .onChanged { pinch in
                let axis = pinchAxis ?? (NSEvent.modifierFlags.contains(.option) ? .vertical : .horizontal)
                pinchAxis = axis
                let factor = pinch.magnification / (lastMagnification ?? 1)
                lastMagnification = pinch.magnification
                if axis == .vertical {
                    let fraction = Double((layout.plot.maxY - pinch.startLocation.y) / layout.plot.height)
                    zoomValues(by: factor, around: fraction.clamped(between: 0, and: 1), pinching: true)
                } else {
                    zoomTimes(by: factor, around: layout.seconds(atX: pinch.startLocation.x), c, layout: layout, pinching: true)
                }
            }
            .onEnded { _ in
                lastMagnification = nil
                pinchAxis = nil
                endTimePinch()
                valueBand.endPinch()
            })
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointer.location = location
                let target = hit(at: location, c, layout: layout).target
                if pointer.keyframe != target.keyframeTime { pointer.keyframe = target.keyframeTime }
                if target != .scrub {
                    NSCursor.pointingHand.set()
                } else {
                    (layout.plot.contains(location) ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                }
            case .ended:
                leaveHover()
            }
        }
        // The panel hides with the app, which may not end the hover.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in leaveHover() }
        .contextMenu {
            GraphMenu(
                pointer: pointer, fallback: { presetTarget(c) },
                onEase: { preset, time in
                    selected = time
                    edit { $0.applyEase(preset, at: time) }
                },
                onDelete: deleteKeyframe(at:),
                onAdd: { addKeyframeAtPlayhead(c) }
            )
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onDeleteCommand { if let time = presetTarget(c) { deleteKeyframe(at: time) } }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard drag == nil, let time = selected, c.value.keyframe(at: time) != nil else { return .ignored }
            let steps = press.modifiers.contains(.shift) ? 10 : 1
            switch press.key {
            case .leftArrow: nudge(time, frames: -steps, points: 0, c, layout: layout)
            case .rightArrow: nudge(time, frames: steps, points: 0, c, layout: layout)
            case .upArrow: nudge(time, frames: 0, points: CGFloat(steps), c, layout: layout)
            default: nudge(time, frames: 0, points: -CGFloat(steps), c, layout: layout)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            guard let current = drag else { return .ignored }
            draft = nil
            drag = nil
            dragCancelled = true
            selected = current.selectedBefore
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(key.parameter.name) graph")
        .accessibilityValue("\(c.value.keyframes.count) keyframes")
        .accessibilityHint(shared == nil
                           ? "The sliders below zoom; the buttons above ease the selected keyframe or the one at the playhead"
                           : "The sliders zoom; the buttons at the top of the panel ease its selected keyframe or the one at the playhead")
        .accessibilityChildren {
            ForEach(Array(c.value.keyframes.enumerated()), id: \.offset) { _, keyframe in
                keyframeElement(keyframe, c, layout: layout, shown: shown)
            }
        }
        .accessibilityAction(named: "Add keyframe at playhead") { addKeyframeAtPlayhead(c) }
    }

    /// A keyframe for VoiceOver: its time and values; pressing it selects
    /// it, and its actions are the menu's and the arrow keys'.
    private func keyframeElement(_ keyframe: Keyframe<ComponentValue>, _ c: Context, layout: KeyframeGraphLayout, shown: [Int]) -> some View {
        let names = key.parameter.componentNames
        let values = keyframe.value.values.indices.map { index in
            let label = key.parameter.label(keyframe.value.values[index] + c.offset[index], component: index)
            return names.count > 1 ? "\(names[index]) \(label)" : label
        }
        let timecode = c.axis.timelineTime(atKey: keyframe.time).timecode(frameRate: c.timeline.frameRate)
        let component = shown.first ?? 0
        let point = CGPoint(
            x: layout.x(keyframe.time.seconds),
            y: layout.y(keyframe.value.values[component] + c.offset[component], component: component)
        )
        return Rectangle()
            .frame(width: 10, height: 10)
            .position(point)
            .accessibilityLabel("Keyframe at \(timecode), \(values.joined(separator: ", "))")
            .accessibilityAddTraits(keyframe.time == selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selected = keyframe.time }
            .accessibilityAdjustableAction { direction in
                nudge(keyframe.time, frames: direction == .increment ? 1 : -1, points: 0, c, layout: layout)
            }
            .accessibilityActions {
                ForEach(KeyframeEase.Preset.allCases) { preset in
                    Button(preset.name) { edit { $0.applyEase(preset, at: keyframe.time) } }
                }
                Button("Move a frame earlier") { nudge(keyframe.time, frames: -1, points: 0, c, layout: layout) }
                Button("Move a frame later") { nudge(keyframe.time, frames: 1, points: 0, c, layout: layout) }
                Button("Raise value") { nudge(keyframe.time, frames: 0, points: 1, c, layout: layout) }
                Button("Lower value") { nudge(keyframe.time, frames: 0, points: -1, c, layout: layout) }
                Button("Delete") { deleteKeyframe(at: keyframe.time) }
            }
    }

    // MARK: - Zooming and scrolling

    /// The zoom sliders under an unlinked graph, values then time, with
    /// Fit, as the other timelines have them.
    private func zoomBar(_ c: Context) -> some View {
        HStack(spacing: Design.Space.step) {
            Spacer(minLength: 0)
            valueZoomSlider
            ZoomSlider(fraction: timeZoomFraction(c), label: "Time zoom", help: "Zoom time about the playhead (pinch)")
            fitButton
        }
        .padding(.horizontal, Design.Space.step)
        .frame(height: Self.zoomBarHeight)
    }

    static let zoomBarHeight: CGFloat = 24

    private var valueZoomSlider: some View {
        ZoomSlider(
            fraction: Binding(
                get: { ZoomScale.fraction(of: viewport.valueZoom, in: KeyframeGraphViewport.valueZooms) },
                set: { fraction in
                    let factor = ZoomScale.factor(from: viewport.valueZoom, toFraction: fraction, in: KeyframeGraphViewport.valueZooms)
                    viewport.zoomValues(by: factor, around: 0.5)
                }
            ),
            label: "Value zoom", axis: .vertical, help: "Zoom the values about the middle (Option-pinch)"
        )
    }

    /// Time's zoom for its slider, from the whole clip to a few frames;
    /// moving it zooms about the playhead while it is in view, else the
    /// middle.
    private func timeZoomFraction(_ c: Context) -> Binding<Double> {
        let padded = c.padded, fit = c.fit
        let frame = c.timeline.frameDuration.seconds
        let zooms = KeyframeGraphViewport.timeZooms(span: padded, frame: frame)
        return Binding(
            get: { ZoomScale.fraction(of: viewport.timeZoom(fit: fit, span: padded), in: zooms) },
            set: { fraction in
                let shown = viewport.shownTimes(fit: fit, span: padded)
                let playhead = c.axis.keyTime(atTimeline: hud.playhead).seconds
                let anchor = shown.contains(playhead) ? playhead : (shown.lowerBound + shown.upperBound) / 2
                let factor = ZoomScale.factor(from: viewport.timeZoom(fit: fit, span: padded), toFraction: fraction, in: zooms)
                viewport.zoomTimes(by: factor, around: anchor, fit: fit, span: padded, frame: frame)
            }
        )
    }

    /// Fits the keyframes in view, both ways.
    private var fitButton: some View {
        Button {
            viewport = KeyframeGraphViewport(hidden: viewport.hidden, separateScales: viewport.separateScales)
        } label: {
            Image(systemName: Design.Symbol.zoomToFitBoth)
        }
        .buttonStyle(.icon)
        .help("Fit the keyframes in view")
        .accessibilityLabel("Fit")
    }

    /// Fits the values to the keyframes, for the panel's Fit when linked.
    private func fitValues() {
        viewport.valueZoom = 1
        viewport.valuePan = 0
    }

    /// Zooms time about `anchor`; past the clip or the closest zoom the
    /// plot stretches instead (`timeBand`).
    private func zoomTimes(by factor: Double, around anchor: Double, _ c: Context, layout: KeyframeGraphLayout, pinching: Bool) {
        let share = layout.plot.width > 0 ? (layout.x(anchor) - layout.plot.minX) / layout.plot.width : 0.5
        if let link = shared {
            let moment = c.axis.timelineTime(atKey: CMTime(seconds: anchor, preferredTimescale: ParameterTimeAxis.timescale)).seconds
            let project = hud.project
            var band = link.timeBand
            band.zoom(by: factor, about: share, pinching: pinching) { factor in
                link.zoomTimes(by: factor, around: moment, in: project)
            }
            link.timeBand = band
            return
        }
        let padded = c.padded, fit = c.fit
        let frame = c.timeline.frameDuration.seconds
        timeBand.zoom(by: factor, about: share, pinching: pinching) { factor in
            let before = viewport.shownTimes(fit: fit, span: padded)
            viewport.zoomTimes(by: factor, around: anchor, fit: fit, span: padded, frame: frame)
            let after = viewport.shownTimes(fit: fit, span: padded)
            let length = after.upperBound - after.lowerBound
            return length > 0 ? (before.upperBound - before.lowerBound) / length : 1
        }
    }

    /// Zooms values about the value `fraction` up the plot; past the
    /// limits the plot stretches instead (`valueBand`).
    private func zoomValues(by factor: Double, around fraction: Double, pinching: Bool) {
        valueBand.zoom(by: factor, about: CGFloat(1 - fraction), pinching: pinching) { factor in
            let before = viewport.valueZoom
            viewport.zoomValues(by: factor, around: fraction)
            return viewport.valueZoom / before
        }
    }

    /// Scrolling across moves time; up and down moves values. A swipe
    /// moves only the way it started.
    private func scrolled(_ scroll: GraphInput.Scroll, _ c: Context, layout: KeyframeGraphLayout) {
        let axis = scrollAxis(of: scroll)
        let dx = axis == .vertical ? 0 : scroll.dx
        let dy = axis == .horizontal ? 0 : scroll.dy
        let padded = c.padded
        // Also without movement across, so a lift lets go of the edge.
        if dx != 0 || scroll.phase == .lifted, let link = shared {
            let project = hud.project
            var band = link.timeScrollBand
            band.scroll(by: -dx, phase: scroll.phase) { points in
                link.panTimes(byPoints: points, across: layout.plot.width, in: project)
            }
            link.timeScrollBand = band
        } else if dx != 0 || scroll.phase == .lifted {
            let fit = c.fit
            // Toward later times is against the scroll's dx.
            timeScrollBand.scroll(by: -dx, phase: scroll.phase) { points in
                let before = viewport.shownTimes(fit: fit, span: padded).lowerBound
                viewport.panTimes(by: Double(points) * layout.secondsPerPoint, fit: fit, span: padded)
                return CGFloat((viewport.shownTimes(fit: fit, span: padded).lowerBound - before) / layout.secondsPerPoint)
            }
        }
        if dy != 0 {
            viewport.valuePan += Double(dy / layout.plot.height) / viewport.valueZoom
        }
    }

    /// The one way a trackpad swipe scrolls: the way it first moves most,
    /// kept through its momentum until the next swipe. A wheel's turns go
    /// both ways (nil).
    private func scrollAxis(of scroll: GraphInput.Scroll) -> Axis? {
        var axis = scrollAxis
        switch scroll.phase {
        case .wheel: axis = nil
        case .touching where lastScrollPhase != .touching: axis = nil
        case .momentum where lastScrollPhase == nil || lastScrollPhase == .wheel: axis = nil
        default: break
        }
        if axis == nil, scroll.phase != .wheel, scroll.dx != 0 || scroll.dy != 0 {
            axis = abs(scroll.dx) > abs(scroll.dy) ? .horizontal : .vertical
        }
        scrollAxis = axis
        lastScrollPhase = scroll.phase
        return axis
    }

    // MARK: - Toolbar

    private func presetTarget(_ c: Context) -> CMTime? {
        Self.presetTarget(selected: selected, value: c.value, axis: c.axis, timeline: c.timeline, playhead: hud.playhead)
    }

    /// The selected keyframe if it still exists, else the one at the playhead.
    static func presetTarget(
        selected: CMTime?, value: AnimatedValue<ComponentValue>, axis: ParameterTimeAxis, timeline: Timeline, playhead: CMTime
    ) -> CMTime? {
        if let selected, value.keyframe(at: selected) != nil { return selected }
        let now = axis.keyTime(atTimeline: timeline.snappedToFrame(playhead))
        return value.keyframes.first { abs($0.time.seconds - now.seconds) < timeline.frameDuration.seconds / 2 }?.time
    }

    /// The values at the playhead, Separate Scales, and the presets with
    /// Link With; linked, the graph's name and Unlink instead, the panel
    /// having one row of presets for all its graphs.
    private func toolbar(_ c: Context) -> some View {
        let now = c.axis.keyTime(atTimeline: c.timeline.snappedToFrame(hud.playhead))
        let shown = zip(c.value.value(at: now).values, c.offset).map { $0 + $1 }
        let names = key.parameter.componentNames
        return HStack(spacing: Design.Space.step) {
            if let shared { nameButton(shared) } else { ToolGlyph(tone: .graphEditor) }
            ForEach(shown.indices, id: \.self) { index in
                if names.count > 1 {
                    componentChip(index, name: names[index], shown: shown[index])
                } else {
                    Text(key.parameter.label(shown[index], component: index))
                        .font(Design.Typeface.numericSmall)
                        .foregroundStyle(Design.textPrimary)
                }
            }
            if names.count > 1 {
                Toggle(isOn: $viewport.separateScales) { Image(systemName: "arrow.up.and.down.text.horizontal") }
                    .toggleStyle(.icon)
                    .help(viewport.separateScales
                          ? "Draw every component on one value scale"
                          : "Draw each component on a scale of its own, so small moves show beside large ones")
                    .accessibilityLabel("Separate scales")
            }
            Spacer(minLength: Design.Space.step)
            if let shared {
                valueZoomSlider
                Button("Unlink") { hud.unlink(key, from: shared.id) }
                    .help("Take this graph out into a panel of its own")
                    .accessibilityLabel("Unlink \(hud.project.parameterTitle(of: key))")
            } else {
                KeyframeEasePresets(hud: hud, key: key, target: presetTarget(c), axis: c.axis, timeline: c.timeline)
                if let link { KeyframeGraphLinkMenu(hud: hud, link: link) }
            }
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.step)
        .padding(.vertical, Design.Space.close)
    }

    /// The graph's name in a linked panel; clicking it, or the graph, has
    /// the panel's presets act on it, which its name shows in full tone.
    private func nameButton(_ link: KeyframeGraphLink) -> some View {
        let isActive = link.activeKey == key
        let title = hud.project.parameterTitle(of: key)
        return Button { link.active = key } label: {
            Text(title)
                .font(Design.Typeface.groupTitle)
                .foregroundStyle(isActive ? Design.textPrimary : Design.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help(isActive ? "The presets at the top act on this graph" : "Have the presets at the top act on this graph")
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "Presets act on this graph" : "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// A component's color, name and value, which shows or hides its curve.
    /// The last one shown can't be hidden.
    private func componentChip(_ index: Int, name: String, shown: Double) -> some View {
        let isShown = !viewport.hidden.contains(index)
        let count = key.parameter.componentNames.count
        return Button {
            if isShown {
                guard viewport.hidden.count < count - 1 else { return }
                viewport.hidden.insert(index)
            } else {
                viewport.hidden.remove(index)
            }
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .strokeBorder(Self.palette[index % Self.palette.count], lineWidth: 1.5)
                    .background(Circle().fill(isShown ? Self.palette[index % Self.palette.count] : .clear))
                    .frame(width: 8, height: 8)
                Text(name).foregroundStyle(Design.textTertiary)
                Text(key.parameter.label(shown, component: index))
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(isShown ? Design.textPrimary : Design.textTertiary)
            }
            // The keyframe's time gives way first.
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(isShown ? "Hide \(name)" : "Show \(name)")
        .accessibilityLabel(name)
        .accessibilityValue("\(key.parameter.label(shown, component: index)), \(isShown ? "shown" : "hidden")")
    }

    // MARK: - Drawing

    fileprivate static func color(_ component: Int, of count: Int) -> Color {
        count == 1 ? Design.keyframe : palette[component % palette.count]
    }

    private func visible(_ count: Int) -> [Int] {
        (0..<count).filter { !viewport.hidden.contains($0) }
    }

    // MARK: - Handles

    fileprivate struct Handle: Equatable {
        var segment: Int
        var outgoing: Bool
        /// The component it is drawn against.
        var component: Int
        /// The keyframe's point, and the handle's.
        var anchor: CGPoint
        var point: CGPoint
    }

    /// Of the `shown` components, the one whose change over a segment is
    /// largest on screen, which its handles are drawn against.
    private func referenceComponent(of segment: KeyframeGraphLayout.Segment, shown: [Int], layout: KeyframeGraphLayout) -> Int {
        let delta = { (c: Int) in abs(layout.y(segment.to.value.values[c], component: c) - layout.y(segment.from.value.values[c], component: c)) }
        return shown.max { delta($0) < delta($1) } ?? 0
    }

    /// Where a side's handle and its keyframe are drawn, against the
    /// segment's reference component; a linear side's at its implied place.
    private func handle(
        segment index: Int, outgoing: Bool, of segments: [KeyframeGraphLayout.Segment], shown: [Int], _ c: Context, layout: KeyframeGraphLayout
    ) -> Handle? {
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        let component = referenceComponent(of: segment, shown: shown, layout: layout)
        let a = segment.from.value.values[component] + c.offset[component]
        let b = segment.to.value.values[component] + c.offset[component]
        let unit = outgoing ? KeyframeEase.outgoingHandle(segment.from.easeOut) : KeyframeEase.incomingHandle(segment.to.easeIn)
        let t0 = segment.from.time.seconds, t1 = segment.to.time.seconds
        let point = CGPoint(x: layout.x(t0 + Double(unit.x) * (t1 - t0)), y: layout.y(a + Double(unit.y) * (b - a), component: component))
        let anchor = outgoing
            ? CGPoint(x: layout.x(t0), y: layout.y(a, component: component))
            : CGPoint(x: layout.x(t1), y: layout.y(b, component: component))
        return Handle(segment: index, outgoing: outgoing, component: component, anchor: anchor, point: point)
    }

    /// The handles of the `selected` keyframe's eased sides. A linear side
    /// has none to show, nor does either side of a held segment.
    private func handles(_ c: Context, layout: KeyframeGraphLayout, selected: CMTime?, shown: [Int]) -> [Handle] {
        guard let selected else { return [] }
        var result: [Handle] = []
        for (index, segment) in c.segments.enumerated() where !segment.from.hold {
            if segment.from.time == selected, segment.from.easeOut != nil,
               let handle = handle(segment: index, outgoing: true, of: c.segments, shown: shown, c, layout: layout) {
                result.append(handle)
            }
            if segment.to.time == selected, segment.to.easeIn != nil,
               let handle = handle(segment: index, outgoing: false, of: c.segments, shown: shown, c, layout: layout) {
                result.append(handle)
            }
        }
        return result
    }

    /// The ease a side's handle drawn at `point` makes, measured against
    /// its segment. Over a flat segment there is no slope to read, so the
    /// speed it had is kept.
    private func ease(
        handleAt point: CGPoint, segment index: Int, outgoing: Bool, of segments: [KeyframeGraphLayout.Segment], shown: [Int], _ c: Context,
        layout: KeyframeGraphLayout
    ) -> KeyframeEase? {
        guard segments.indices.contains(index) else { return nil }
        let (from, to) = segments[index]
        let component = referenceComponent(of: segments[index], shown: shown, layout: layout)
        let a = from.value.values[component] + c.offset[component]
        let b = to.value.values[component] + c.offset[component]
        let t0 = from.time.seconds, t1 = to.time.seconds
        let flat = abs(b - a) < 1e-9
        let unit = CGPoint(
            x: (layout.seconds(atX: point.x) - t0) / (t1 - t0),
            y: flat ? 0 : (layout.value(atY: point.y, component: component) - a) / (b - a)
        )
        var ease = outgoing ? KeyframeEase.outgoing(handleAt: unit) : KeyframeEase.incoming(handleAt: unit)
        if flat {
            let previous = outgoing ? from.easeOut : to.easeIn
            ease = KeyframeEase(influence: ease.influence, speed: previous?.speed ?? 1)
        }
        return ease
    }

    // MARK: - Dragging

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func target(at point: CGPoint, _ c: Context, layout: KeyframeGraphLayout) -> Target {
        hit(at: point, c, layout: layout).target
    }

    /// What a click at `point` would take, and where that is drawn.
    private func hit(at point: CGPoint, _ c: Context, layout: KeyframeGraphLayout) -> (target: Target, point: CGPoint?) {
        let shown = visible(c.value.value.values.count)
        var handle: (handle: Handle, distance: CGFloat)?
        for candidate in handles(c, layout: layout, selected: selected, shown: shown) {
            let d = Self.distance(candidate.point, point)
            if d < Self.reach, d < handle?.distance ?? .infinity { handle = (candidate, d) }
        }
        var nearest: (target: Target, point: CGPoint, distance: CGFloat)?
        for keyframe in c.value.keyframes {
            let x = layout.x(keyframe.time.seconds)
            for component in shown {
                let at = CGPoint(x: x, y: layout.y(keyframe.value.values[component] + c.offset[component], component: component))
                let d = Self.distance(at, point)
                if d < Self.reach, d < nearest?.distance ?? .infinity {
                    nearest = (.keyframe(keyframe.time, component: component), at, d)
                }
            }
        }
        // A handle just clear of its keyframe takes the click only when
        // clearly nearer, so the keyframe under it stays easy to take.
        if let handle, handle.distance < (nearest?.distance ?? .infinity) - 2 {
            return (.handle(segment: handle.handle.segment, outgoing: handle.handle.outgoing), handle.handle.point)
        }
        guard let nearest else { return (.scrub, nil) }
        if case .keyframe(let time, _) = nearest.target, NSEvent.modifierFlags.contains(.option) {
            return (.pull(time), nearest.point)
        }
        return (nearest.target, nearest.point)
    }

    /// Whether a drag has gone far enough to be one rather than a click.
    private static func moved(_ translation: CGSize) -> Bool {
        abs(translation.width) >= 2 || abs(translation.height) >= 2
    }

    private func dragGesture(_ c: Context, layout: KeyframeGraphLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard !dragCancelled else { return }
                if drag == nil {
                    link?.active = key
                    isFocused = true
                    pointer.location = nil
                    NSCursor.arrow.set()
                    let target = target(at: gesture.startLocation, c, layout: layout)
                    drag = Drag(target: target, layout: layout, original: c.value, segments: c.segments, selectedBefore: selected)
                    if let time = target.keyframeTime { selected = time }
                    if case .scrub = target { selected = nil }
                }
                guard let current = drag else { return }
                switch current.target {
                case .scrub:
                    hud.onSeek(c.axis.timelineTime(atKey: c.axis.snapped(current.layout.seconds(atX: gesture.location.x))))
                case .keyframe(let time, let component):
                    guard Self.moved(gesture.translation) else { return }
                    let (dx, dy) = constrained(gesture.translation)
                    let toward = dx == 0 ? time : c.axis.snapped(time.seconds + Double(dx) * current.layout.secondsPerPoint)
                    let moved = movedKeyframe(time, component: component, toward: toward, dy: dy, in: current.original, layout: current.layout, c)
                    draft = moved.value
                    drag?.movedTo = moved.time
                case .handle(let segment, let outgoing):
                    guard Self.moved(gesture.translation) else { return }
                    let alone = NSEvent.modifierFlags.contains(.option)
                    draft = movedHandle(segment, outgoing: outgoing, to: gesture.location, alone: alone, drag: current, c)
                case .pull(let time):
                    // The side the drag heads to; nothing until it heads somewhere.
                    guard abs(gesture.translation.width) >= 2 else { return }
                    let outgoing = gesture.translation.width > 0
                    let keyframes = current.original.keyframes
                    guard let index = keyframes.firstIndex(where: { $0.time == time }) else { return }
                    let segment = outgoing ? index : index - 1
                    guard segment >= 0, segment < keyframes.count - 1 else { return }
                    draft = movedHandle(segment, outgoing: outgoing, to: gesture.location, alone: true, drag: current, c)
                }
            }
            .onEnded { gesture in
                defer {
                    draft = nil
                    drag = nil
                }
                if dragCancelled {
                    dragCancelled = false
                    return
                }
                // A scrub only seeks; it leaves nothing to save.
                guard let current = drag, current.target != .scrub else { return }
                if case .pull(let time) = current.target, !Self.moved(gesture.translation) {
                    // Option-click: linear becomes bezier, and bezier linear.
                    edit { $0.toggleBezier(at: time) }
                } else if let draft, draft != current.original {
                    commit(draft)
                    if let movedTo = current.movedTo { selected = movedTo }
                }
            }
    }

    /// A keyframe drag's movement across and up, which Shift keeps to one
    /// way: the way it moves most once it has gone four points, kept for
    /// the rest of the drag while Shift is down.
    private func constrained(_ translation: CGSize) -> (dx: CGFloat, dy: CGFloat) {
        let dx = translation.width, dy = translation.height
        guard NSEvent.modifierFlags.contains(.shift) else {
            if drag?.lockedAxis != nil { drag?.lockedAxis = nil }
            return (dx, dy)
        }
        var axis = drag?.lockedAxis
        if axis == nil, max(abs(dx), abs(dy)) >= 4 {
            axis = abs(dx) > abs(dy) ? .horizontal : .vertical
            drag?.lockedAxis = axis
        }
        switch axis ?? (abs(dx) > abs(dy) ? .horizontal : .vertical) {
        case .horizontal: return (dx, 0)
        case .vertical: return (0, dy)
        }
    }

    /// `original` with the keyframe at `time` moved toward `newTime`, kept
    /// on frames and between its neighbors, and its `component` value
    /// moved `dy` points down the plot; with the time it lands on.
    private func movedKeyframe(
        _ time: CMTime, component: Int, toward newTime: CMTime, dy: CGFloat, in original: AnimatedValue<ComponentValue>,
        layout: KeyframeGraphLayout, _ c: Context
    ) -> (value: AnimatedValue<ComponentValue>, time: CMTime) {
        var result = original
        guard let index = result.keyframes.firstIndex(where: { $0.time == time }) else { return (result, time) }
        let frame = c.axis.keyTime(atTimeline: c.axis.timelineTime(atKey: time) + c.timeline.frameDuration) - time
        var newTime = newTime
        if index > 0 { newTime = CMTimeMaximum(newTime, CMTimeAdd(result.keyframes[index - 1].time, frame)) }
        if index < result.keyframes.count - 1 { newTime = CMTimeMinimum(newTime, CMTimeSubtract(result.keyframes[index + 1].time, frame)) }
        if dy != 0 {
            var moved = result.keyframes[index].value
            let shown = moved.values[component] + c.offset[component]
            let newShown = layout.value(atY: layout.y(shown, component: component) + dy, component: component)
            moved.values[component] = key.parameter.clamped(newShown - c.offset[component], index: component)
            result.set(moved, at: time)
        }
        result.moveKeyframe(at: time, to: newTime)
        return (result, newTime)
    }

    /// Moves the keyframe at `time` `frames` frames along and its first
    /// shown component's value `points` up the plot, as a drag would, in
    /// one edit, and selects it where it lands: the arrow keys' and
    /// VoiceOver's way to drag it.
    private func nudge(_ time: CMTime, frames: Int, points: CGFloat, _ c: Context, layout: KeyframeGraphLayout) {
        guard drag == nil else { return }
        var toward = time
        if frames != 0 {
            let moved = CMTimeAdd(c.axis.timelineTime(atKey: time), CMTimeMultiply(c.timeline.frameDuration, multiplier: Int32(frames)))
            toward = c.axis.snapped(c.axis.keyTime(atTimeline: moved).seconds)
        }
        let component = visible(c.value.value.values.count).first ?? 0
        let moved = movedKeyframe(time, component: component, toward: toward, dy: -points, in: c.value, layout: layout, c)
        selected = moved.time
        if moved.value != c.value { commit(moved.value) }
    }

    /// The keyframes with one side's ease set from a handle dragged to
    /// `location`. Unless `alone`, the keyframe's other handle, if that
    /// side is eased, swings to stay on one line through the keyframe with
    /// the dragged one, keeping its own length on screen. Dragged onto the
    /// keyframe, the handle goes and its side turns linear.
    private func movedHandle(_ segment: Int, outgoing: Bool, to location: CGPoint, alone: Bool, drag: Drag, _ c: Context) -> AnimatedValue<ComponentValue> {
        var result = drag.original
        let layout = drag.layout
        let segments = drag.segments
        let shown = visible(result.value.values.count)
        guard segments.indices.contains(segment),
              let dragged = handle(segment: segment, outgoing: outgoing, of: segments, shown: shown, c, layout: layout)
        else { return result }
        let keyframe = outgoing ? segments[segment].from : segments[segment].to
        let collapsed = Self.distance(location, dragged.anchor) < Self.collapseDistance
        var easeIn = keyframe.easeIn, easeOut = keyframe.easeOut
        let newEase = collapsed
            ? nil : ease(handleAt: location, segment: segment, outgoing: outgoing, of: segments, shown: shown, c, layout: layout)
        if outgoing { easeOut = newEase } else { easeIn = newEase }

        // The other side's handle, on the segment across the keyframe.
        let otherSegment = outgoing ? segment - 1 : segment + 1
        let otherEase = outgoing ? keyframe.easeIn : keyframe.easeOut
        if !alone, !collapsed, otherEase != nil,
           let other = handle(segment: otherSegment, outgoing: !outgoing, of: segments, shown: shown, c, layout: layout) {
            let length = Self.distance(other.point, other.anchor)
            let dx = location.x - dragged.anchor.x, dy = location.y - dragged.anchor.y
            let reach = hypot(dx, dy)
            if reach > 0 {
                let point = CGPoint(x: other.anchor.x - dx / reach * length, y: other.anchor.y - dy / reach * length)
                let swung = ease(handleAt: point, segment: otherSegment, outgoing: !outgoing, of: segments, shown: shown, c, layout: layout)
                if outgoing { easeIn = swung } else { easeOut = swung }
            }
        }
        result.setEase(at: keyframe.time, in: easeIn, out: easeOut)
        return result
    }

    private func leaveHover() {
        pointer.location = nil
        pointer.keyframe = nil
        NSCursor.arrow.set()
    }

    // MARK: - Editing

    /// Saves keyframes the graph made, drawing them until the project has
    /// them.
    private func commit(_ value: AnimatedValue<ComponentValue>) {
        committed = value
        edit { $0 = value }
        commitFallback?.cancel()
        commitFallback = Task { @MainActor in
            // In case the edit didn't land and nothing clears it.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if committed == value { committed = nil }
        }
    }

    private func addKeyframe(at time: CMTime) {
        edit { value in
            if value.keyframe(at: time) == nil { value.toggleKeyframe(at: time) }
        }
    }

    private func addKeyframeAtPlayhead(_ c: Context) {
        let time = c.axis.keyTime(atTimeline: c.timeline.snappedToFrame(hud.playhead))
        addKeyframe(at: time)
        selected = time
    }

    private func deleteKeyframe(at time: CMTime) {
        edit { $0.removeKeyframe(at: time) }
        selected = nil
    }

    private func edit(_ change: @escaping (inout AnimatedValue<ComponentValue>) -> Void) {
        let key = key
        hud.onEdit { $0.editComponents(of: key, change) }
    }
}

// MARK: - Layers

extension KeyframeGraphView {
    /// The grid, its labels, the clip's ends and the curves: everything
    /// that stays put while the selection changes.
    fileprivate struct Curves: View, Equatable {
        let value: AnimatedValue<ComponentValue>
        let offset: [Double]
        let layout: KeyframeGraphLayout
        /// The components drawn, which the viewport doesn't hide.
        let shown: [Int]
        let separateScales: Bool
        let parameter: AnimatedParameter
        /// The clip's ends, in the parameter's time.
        let span: ClosedRange<Double>
        /// The timecodes at the plot's left and right.
        let timecodes: [String]

        var body: some View {
            Canvas { context, _ in draw(in: &context) }
        }

        private func draw(in context: inout GraphicsContext) {
            let plot = layout.plot
            let count = value.value.values.count
            let colors = (0..<count).map { KeyframeGraphView.color($0, of: count) }
            // The values the axis is labelled in: the one scale, or with
            // separate scales the first shown component's, in its color.
            let labelled = shown.first ?? 0
            let labelColor = separateScales && count > 1 ? colors[labelled] : Design.textTertiary
            let ticks = KeyframeGraphLayout.ticks(in: layout.values[labelled])
            let tickLabels = ticks.map { tick in
                context.resolve(Text(parameter.label(tick, component: labelled)).font(Design.Typeface.numericScale).foregroundStyle(labelColor))
            }
            let labelHeight = tickLabels.map { $0.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).height }.max() ?? 0
            let timeLabels = timecodes.map { context.resolve(Text($0).font(Design.Typeface.numericScale).foregroundStyle(Design.textTertiary)) }

            context.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: 0, y: plot.minY - 6, width: plot.maxX + 14, height: plot.height + 30)))
                // A label too close to the last one drawn is left out, its
                // line kept: a squashed plot has room for fewer.
                var lastLabelY: CGFloat?
                for (tick, label) in zip(ticks, tickLabels) {
                    let y = layout.y(tick, component: labelled)
                    layer.fill(Path(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.5)), with: .color(.white.opacity(0.08)))
                    if let lastLabelY, abs(y - lastLabelY) < labelHeight { continue }
                    layer.draw(label, at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
                    lastLabelY = y
                }
                for (label, (seconds, anchor)) in zip(timeLabels, [(layout.times.lowerBound, UnitPoint.topLeading), (layout.times.upperBound, .topTrailing)]) {
                    layer.draw(label, at: CGPoint(x: layout.x(seconds), y: plot.maxY + 4), anchor: anchor)
                }
                // The clip's ends, where its keyframes stop playing.
                for edge in [span.lowerBound, span.upperBound] where layout.times.contains(edge) {
                    layer.fill(Path(CGRect(x: layout.x(edge) - 0.5, y: plot.minY, width: 1, height: plot.height)), with: .color(.white.opacity(0.18)))
                }
            }

            context.clip(to: Path(plot.insetBy(dx: -6, dy: -6)))
            for (component, line) in zip(shown, curves()) {
                context.stroke(line, with: .color(colors[component]), lineWidth: 1.5)
            }
        }

        /// A line per shown component, read once per point across for them
        /// all: sampled between keyframes, every two points or so; straight
        /// where the value holds, before the first and after the last.
        private func curves() -> [Path] {
            var lines = shown.map { _ in Path() }
            func add(_ seconds: Double, _ values: [Double]) {
                let x = layout.x(seconds)
                for (line, component) in shown.enumerated() {
                    let point = CGPoint(x: x, y: layout.y(values[component] + offset[component], component: component))
                    if lines[line].isEmpty { lines[line].move(to: point) } else { lines[line].addLine(to: point) }
                }
            }
            let start = layout.times.lowerBound, end = layout.times.upperBound
            guard let first = value.keyframes.first, let last = value.keyframes.last else {
                add(start, value.value.values)
                add(end, value.value.values)
                return lines
            }
            // Fewer samples on a very wide plot.
            let step = Double(max(2, layout.plot.width / 400)) * layout.secondsPerPoint
            if start < first.time.seconds { add(start, first.value.values) }
            for (from, to) in KeyframeGraphLayout.segments(of: value) {
                let a = max(from.time.seconds, start), b = min(to.time.seconds, end)
                guard a <= b else { continue }
                if from.hold {
                    // Flat to the next keyframe, which then starts its own.
                    add(a, from.value.values)
                    add(b, from.value.values)
                    continue
                }
                var seconds = a
                while step > 0, seconds < b {
                    add(seconds, value.value(atSeconds: seconds).values)
                    seconds += step
                }
                add(b, value.value(atSeconds: b).values)
            }
            if end > last.time.seconds {
                add(max(last.time.seconds, start), last.value.values)
                add(end, last.value.values)
            }
            return lines
        }
    }

    /// The selected keyframe's handles and every keyframe's mark.
    fileprivate struct Marks: View, Equatable {
        let value: AnimatedValue<ComponentValue>
        let offset: [Double]
        let layout: KeyframeGraphLayout
        let shown: [Int]
        let selected: CMTime?
        let handles: [Handle]

        var body: some View {
            Canvas { context, _ in draw(in: &context) }
                .allowsHitTesting(false)
        }

        private func draw(in context: inout GraphicsContext) {
            context.clip(to: Path(layout.plot.insetBy(dx: -6, dy: -6)))
            for handle in handles {
                var stem = Path()
                stem.move(to: handle.anchor)
                stem.addLine(to: handle.point)
                context.stroke(stem, with: .color(.white.opacity(0.6)), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: handle.point.x - 3.5, y: handle.point.y - 3.5, width: 7, height: 7)), with: .color(.white))
            }
            // A mark of each kind, made once and moved to each point.
            var marks: [Int: Path] = [:]
            for keyframe in value.keyframes {
                let kind = (keyframe.easeIn != nil ? 1 : 0) | (keyframe.easeOut != nil ? 2 : 0) | (keyframe.hold ? 4 : 0)
                let mark = marks[kind] ?? KeyframeMarkShape(easedIn: keyframe.easeIn != nil, easedOut: keyframe.easeOut != nil, holds: keyframe.hold)
                    .path(in: CGRect(x: -5, y: -5, width: 10, height: 10))
                marks[kind] = mark
                let fill = keyframe.time == selected ? Design.keyframe : Design.textSecondary
                let x = layout.x(keyframe.time.seconds)
                for component in shown {
                    let y = layout.y(keyframe.value.values[component] + offset[component], component: component)
                    let placed = mark.applying(CGAffineTransform(translationX: x, y: y))
                    context.fill(placed, with: .color(fill))
                    context.stroke(placed, with: .color(.black.opacity(0.5)), lineWidth: 0.5)
                }
            }
        }
    }

    /// A ring round what a click under the pointer would take. It follows
    /// the pointer alone, so the graph doesn't redraw as it moves.
    fileprivate struct HoverRing: View {
        let pointer: GraphPointer
        /// Where the point a click at a location takes is drawn.
        let ring: (CGPoint) -> CGPoint?

        var body: some View {
            let point = pointer.location.flatMap(ring)
            Canvas { context, _ in
                guard let point else { return }
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)), with: .color(.white), lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
    }

    /// The right-click menu: eases and Delete for the keyframe under the
    /// pointer, or else the selected one or the one at the playhead; with
    /// none, a keyframe to add at the playhead.
    fileprivate struct GraphMenu: View {
        let pointer: GraphPointer
        let fallback: () -> CMTime?
        let onEase: (KeyframeEase.Preset, CMTime) -> Void
        let onDelete: (CMTime) -> Void
        let onAdd: () -> Void

        var body: some View {
            if let time = pointer.keyframe ?? fallback() {
                KeyframeEaseMenuItems { onEase($0, time) }
                Divider()
                Button("Delete Keyframe", role: .destructive) { onDelete(time) }
            } else {
                Button("Add Keyframe at Playhead", action: onAdd)
            }
        }
    }
}

/// Where the pointer is over a graph, and the keyframe a click there would
/// take, kept apart from the graph's state so that following the pointer
/// redraws only what shows it.
@MainActor @Observable
private final class GraphPointer {
    var location: CGPoint?
    var keyframe: CMTime?
}

/// Which keyframe the ease presets act on, and the presets: on a graph's
/// own row, or for a linked panel on its top row, where the keyframe is
/// named with its graph (`named`).
struct KeyframeEasePresets: View {
    let hud: KeyframeGraphHUDs
    let key: ParameterKey
    let target: CMTime?
    let axis: ParameterTimeAxis
    let timeline: Timeline
    var named = false

    var body: some View {
        let title = named ? "\(hud.project.parameterTitle(of: key)) · " : ""
        Text(target.map { "\(title)Keyframe \(axis.timelineTime(atKey: $0).timecode(frameRate: timeline.frameRate))" } ?? "\(title)No keyframe selected")
            .foregroundStyle(Design.textTertiary)
            .lineLimit(1)
            .truncationMode(named ? .middle : .tail)
        ForEach(KeyframeEase.Preset.allCases) { preset in
            Button(preset.name) {
                guard let target else { return }
                let key = key
                hud.onEdit { $0.editComponents(of: key) { $0.applyEase(preset, at: target) } }
            }
            .help(preset.detail + (preset.shortcutHint.map { " (\($0) on the timeline)" } ?? ""))
            .fixedSize()
        }
        .disabled(target == nil)
    }
}

/// The playhead's line on a graph: parked, or while the player plays,
/// where it is, so following it redraws only the line.
private struct GraphPlayheadLine: View {
    let playback: PlaybackModel?
    let parked: CMTime
    let axis: ParameterTimeAxis
    let layout: KeyframeGraphLayout

    var body: some View {
        let time = playback.map { $0.isPlaying ? $0.currentTime : parked } ?? parked
        let x = layout.x(axis.keyTime(atTimeline: time).seconds)
        Canvas { context, _ in
            guard (layout.plot.minX...layout.plot.maxX).contains(x) else { return }
            context.fill(Path(CGRect(x: x - 0.5, y: layout.plot.minY, width: 1, height: layout.plot.height)), with: .color(Design.playhead))
        }
        .allowsHitTesting(false)
    }
}
