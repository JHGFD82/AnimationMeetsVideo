import AppKit
import CoreMedia
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
/// linear side, the side the drag heads to. Click elsewhere to move the
/// playhead there; double-click to add a keyframe. The buttons and the
/// right-click menu apply ease presets to the selected keyframe, or to the
/// one at the playhead.
///
/// The dials under and beside the graph zoom time and values, each turn
/// by the same ratio wherever the zoom is, time no further out than the
/// clip; pinching zooms time about the pointer (values with Option), and
/// scrolling moves the view. The legend's chips show or hide each
/// component, and Separate Scales draws each on its own scale.
struct KeyframeGraphView: View {
    let hud: KeyframeGraphHUDs
    let key: ParameterKey
    let input: GraphInput

    /// The keyframes as a drag in progress leaves them, drawn instead of
    /// the project's and saved when the drag ends.
    @State private var draft: AnimatedValue<ComponentValue>?
    /// A finished drag's keyframes, drawn until the project has them, so
    /// the old ones don't show for a frame on release.
    @State private var committed: AnimatedValue<ComponentValue>?
    @State private var drag: Drag?
    @State private var selected: CMTime?
    @State private var viewport = KeyframeGraphViewport()
    /// The pinch's magnification when it last changed the zoom.
    @State private var lastMagnification: CGFloat?

    private enum Target: Equatable {
        case keyframe(CMTime, component: Int)
        case handle(segment: Int, outgoing: Bool)
        /// Option on a keyframe: a click switches it between linear and
        /// bezier; a drag pulls a handle out of the side it heads to.
        case pull(CMTime)
        case scrub
    }

    /// Closer than this on screen, a dragged handle goes and its side turns
    /// linear.
    private static let collapseDistance: CGFloat = 6

    private struct Drag {
        var target: Target
        var layout: KeyframeGraphLayout
        var original: AnimatedValue<ComponentValue>
    }

    private static let palette: [Color] = [Design.statusDanger, Design.statusDone, Design.accent, Design.keyframe]

    /// Everything the graph needs about the parameter right now.
    private struct Context {
        var value: AnimatedValue<ComponentValue>
        var offset: [Double]
        var timeline: Timeline
        var axis: ParameterTimeAxis
    }

    var body: some View {
        if let timeline = hud.project.timeline(id: key.timelineID), let stored = hud.project.components(of: key),
           let axis = hud.project.timeAxis(of: key) {
            let c = Context(
                value: draft ?? committed ?? stored, offset: key.parameter.displayOffset(frameSize: timeline.frameSize),
                timeline: timeline, axis: axis
            )
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
                        let layout = drag?.layout ?? layout(c, size: CGSize(width: geometry.size.width - ZoomDial.thickness, height: geometry.size.height - ZoomDial.thickness))
                        // The dials meet in the bottom right corner, each along
                        // the axis it zooms, with Fit where they meet.
                        let reach = { (room: CGFloat) in min(ZoomDial.length, max(room - 8, 40)) }
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                graph(c, layout: layout)
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    ZoomDial(axis: .vertical, label: "Value zoom") { factor in
                                        viewport.zoomValues(by: factor, around: 0.5)
                                    } onReset: {
                                        viewport.valueZoom = 1
                                        viewport.valuePan = 0
                                    }
                                    .frame(height: reach(geometry.size.height - ZoomDial.thickness))
                                }
                            }
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
                                ZoomDial(axis: .horizontal, label: "Time zoom") { factor in
                                    zoomTimes(by: factor, around: timeAnchor(c, layout: layout), c)
                                } onReset: {
                                    viewport.times = nil
                                }
                                .frame(width: reach(geometry.size.width - ZoomDial.thickness))
                                fitButton
                            }
                        }
                        .onChange(of: input.scroll) { _, scroll in
                            guard let scroll else { return }
                            scrolled(scroll, c, layout: layout)
                        }
                    }
                }
            }
            .background(Color.black.opacity(0.2))
            .onChange(of: stored) { _, _ in committed = nil }
        } else {
            Text("This layer is no longer on the timeline.")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func layout(_ c: Context, size: CGSize) -> KeyframeGraphLayout {
        KeyframeGraphLayout(
            c.value, offset: c.offset, size: size, viewport: viewport, span: c.axis.span, frame: c.timeline.frameDuration.seconds
        )
    }

    private func graph(_ c: Context, layout: KeyframeGraphLayout) -> some View {
        Canvas { context, _ in
            draw(c, layout: layout, in: &context)
        }
        .overlay { GraphPlayheadLine(playback: hud.playback, parked: hud.playhead, axis: c.axis, layout: layout) }
        .contentShape(Rectangle())
        .gesture(dragGesture(c, layout: layout))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
            let time = c.axis.snapped(layout.seconds(atX: tap.location.x))
            edit { $0.toggleKeyframe(at: time) }
            selected = time
        })
        .simultaneousGesture(MagnifyGesture()
            .onChanged { pinch in
                let factor = pinch.magnification / (lastMagnification ?? 1)
                lastMagnification = pinch.magnification
                if NSEvent.modifierFlags.contains(.option) {
                    let fraction = Double((layout.plot.maxY - pinch.startLocation.y) / layout.plot.height)
                    viewport.zoomValues(by: factor, around: min(max(fraction, 0), 1))
                } else {
                    zoomTimes(by: factor, around: layout.seconds(atX: pinch.startLocation.x), c)
                }
            }
            .onEnded { _ in lastMagnification = nil })
        .contextMenu {
            if let target = presetTarget(c) {
                KeyframeEaseMenuItems { preset in edit { $0.applyEase(preset, at: target) } }
                Divider()
                Button("Delete Keyframe", role: .destructive) {
                    edit { $0.removeKeyframe(at: target) }
                    selected = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key.parameter.name) graph")
        .accessibilityValue("\(c.value.keyframes.count) keyframes")
        .accessibilityHint("The dials zoom; the buttons above ease the selected keyframe or the one at the playhead")
    }

    // MARK: - Zooming and scrolling

    /// Fits the keyframes in view, both ways, in the corner between the
    /// dials.
    private var fitButton: some View {
        Button { viewport = KeyframeGraphViewport(hidden: viewport.hidden, separateScales: viewport.separateScales) } label: {
            Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                .font(Design.Typeface.glyphSmall)
                .foregroundStyle(Design.textSecondary)
                .frame(width: ZoomDial.thickness, height: ZoomDial.thickness)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Fit the keyframes in view")
        .accessibilityLabel("Fit")
    }

    /// The time the dial zooms about: the playhead while it's in view, else
    /// the middle.
    private func timeAnchor(_ c: Context, layout: KeyframeGraphLayout) -> Double {
        let playhead = c.axis.keyTime(atTimeline: hud.playhead).seconds
        return layout.times.contains(playhead) ? playhead : (layout.times.lowerBound + layout.times.upperBound) / 2
    }

    private func zoomTimes(by factor: Double, around anchor: Double, _ c: Context) {
        let padded = KeyframeGraphLayout.padded(c.axis.span)
        let frame = c.timeline.frameDuration.seconds
        viewport.zoomTimes(by: factor, around: anchor, fit: KeyframeGraphLayout.fitTimes(c.value, span: padded, frame: frame), span: padded, frame: frame)
    }

    /// Scrolling across moves time; up and down moves values.
    private func scrolled(_ scroll: GraphInput.Scroll, _ c: Context, layout: KeyframeGraphLayout) {
        let padded = KeyframeGraphLayout.padded(c.axis.span)
        if scroll.dx != 0 {
            let fit = KeyframeGraphLayout.fitTimes(c.value, span: padded, frame: c.timeline.frameDuration.seconds)
            viewport.panTimes(by: -Double(scroll.dx) * layout.secondsPerPoint, fit: fit, span: padded)
        }
        if scroll.dy != 0 {
            viewport.valuePan += Double(scroll.dy / layout.plot.height) / viewport.valueZoom
        }
    }

    // MARK: - Toolbar

    /// The selected keyframe if it still exists, else the one at the playhead.
    private func presetTarget(_ c: Context) -> CMTime? {
        if let selected, c.value.keyframe(at: selected) != nil { return selected }
        let playhead = c.axis.keyTime(atTimeline: c.timeline.snappedToFrame(hud.playhead))
        return c.value.keyframes.first { abs($0.time.seconds - playhead.seconds) < c.timeline.frameDuration.seconds / 2 }?.time
    }

    private func toolbar(_ c: Context) -> some View {
        let target = presetTarget(c)
        let now = c.axis.keyTime(atTimeline: c.timeline.snappedToFrame(hud.playhead))
        let shown = zip(c.value.value(at: now).values, c.offset).map { $0 + $1 }
        let names = key.parameter.componentNames
        return HStack(spacing: Design.Space.step) {
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
            Text(target.map { "Keyframe \(c.axis.timelineTime(atKey: $0).timecode(frameRate: c.timeline.frameRate))" } ?? "No keyframe selected")
                .foregroundStyle(Design.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            ForEach(KeyframeEase.Preset.allCases) { preset in
                Button(preset.name) {
                    if let target { edit { $0.applyEase(preset, at: target) } }
                }
                .help(preset.detail + (preset.shortcutHint.map { " (\($0) on the timeline)" } ?? ""))
            }
            .disabled(target == nil)
        }
        .font(Design.Typeface.label)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.step)
        .padding(.vertical, Design.Space.close)
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
        }
        .buttonStyle(.plain)
        .help(isShown ? "Hide \(name)" : "Show \(name)")
        .accessibilityLabel(name)
        .accessibilityValue("\(key.parameter.label(shown, component: index)), \(isShown ? "shown" : "hidden")")
    }

    // MARK: - Drawing

    private func color(_ component: Int, of count: Int) -> Color {
        count == 1 ? Design.keyframe : Self.palette[component % Self.palette.count]
    }

    private func visible(_ count: Int) -> [Int] {
        (0..<count).filter { !viewport.hidden.contains($0) }
    }

    private func draw(_ c: Context, layout: KeyframeGraphLayout, in context: inout GraphicsContext) {
        let plot = layout.plot
        let count = c.value.value.values.count
        let shownComponents = visible(count)
        // The values the axis is labelled in: the one scale, or with
        // separate scales the first shown component's, in its color.
        let labelled = shownComponents.first ?? 0
        let labelColor = viewport.separateScales && count > 1 ? color(labelled, of: count) : Design.textTertiary

        context.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: plot.minY - 6, width: plot.maxX + 14, height: plot.height + 30)))
            for step in 0...4 {
                let range = layout.values[labelled]
                let shown = range.lowerBound + (range.upperBound - range.lowerBound) * Double(step) / 4
                let y = layout.y(shown, component: labelled)
                layer.fill(Path(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.5)), with: .color(.white.opacity(0.08)))
                layer.draw(
                    Text(key.parameter.label(shown, component: labelled)).font(Design.Typeface.numericScale).foregroundStyle(labelColor),
                    at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing
                )
            }
            for (seconds, anchor) in [(layout.times.lowerBound, UnitPoint.topLeading), (layout.times.upperBound, .topTrailing)] {
                let time = c.axis.timelineTime(atKey: CMTime(seconds: seconds, preferredTimescale: 240_000))
                layer.draw(
                    Text(CMTimeMaximum(time, .zero).timecode(frameRate: c.timeline.frameRate))
                        .font(Design.Typeface.numericScale).foregroundStyle(Design.textTertiary),
                    at: CGPoint(x: layout.x(seconds), y: plot.maxY + 4), anchor: anchor
                )
            }
            // The clip's ends, where its keyframes stop playing.
            for edge in [c.axis.span.lowerBound, c.axis.span.upperBound] where layout.times.contains(edge) {
                layer.fill(Path(CGRect(x: layout.x(edge) - 0.5, y: plot.minY, width: 1, height: plot.height)), with: .color(.white.opacity(0.18)))
            }
        }

        context.clip(to: Path(plot.insetBy(dx: -6, dy: -6)))
        // The curves, a point every two points across.
        for component in shownComponents {
            var line = Path()
            var x = plot.minX
            while x <= plot.maxX {
                let shown = c.value.value(atSeconds: layout.seconds(atX: x)).values[component] + c.offset[component]
                let point = CGPoint(x: x, y: layout.y(shown, component: component))
                if line.isEmpty { line.move(to: point) } else { line.addLine(to: point) }
                x += 2
            }
            context.stroke(line, with: .color(color(component, of: count)), lineWidth: 1.5)
        }

        for handle in handles(c, layout: layout) {
            var stem = Path()
            stem.move(to: handle.anchor)
            stem.addLine(to: handle.point)
            context.stroke(stem, with: .color(.white.opacity(0.6)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: handle.point.x - 3.5, y: handle.point.y - 3.5, width: 7, height: 7)), with: .color(.white))
        }

        for keyframe in c.value.keyframes {
            let isSelected = keyframe.time == selected
            for component in shownComponents {
                let center = CGPoint(
                    x: layout.x(keyframe.time.seconds),
                    y: layout.y(keyframe.value.values[component] + c.offset[component], component: component)
                )
                let rect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
                let mark = KeyframeMarkShape(easedIn: keyframe.easeIn != nil, easedOut: keyframe.easeOut != nil).path(in: rect)
                context.fill(mark, with: .color(isSelected ? Design.keyframe : Design.textSecondary))
                context.stroke(mark, with: .color(.black.opacity(0.5)), lineWidth: 0.5)
            }
        }
    }

    // MARK: - Handles

    private struct Handle {
        var segment: Int
        var outgoing: Bool
        /// The component it is drawn against.
        var component: Int
        /// The keyframe's point, and the handle's.
        var anchor: CGPoint
        var point: CGPoint
    }

    /// The shown component whose change over a segment is largest on
    /// screen, which its handles are drawn against.
    private func referenceComponent(from: Keyframe<ComponentValue>, to: Keyframe<ComponentValue>, layout: KeyframeGraphLayout) -> Int {
        let shown = visible(from.value.values.count)
        let delta = { (c: Int) in abs(layout.y(to.value.values[c], component: c) - layout.y(from.value.values[c], component: c)) }
        return shown.max { delta($0) < delta($1) } ?? 0
    }

    /// Where a side's handle and its keyframe are drawn, against the
    /// segment's reference component; a linear side's at its implied place.
    private func handle(segment index: Int, outgoing: Bool, _ c: Context, value: AnimatedValue<ComponentValue>, layout: KeyframeGraphLayout) -> Handle? {
        let segments = KeyframeGraphLayout.segments(of: value)
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        let component = referenceComponent(from: segment.from, to: segment.to, layout: layout)
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

    /// The handles of the selected keyframe's eased sides. A linear side
    /// has none to show.
    private func handles(_ c: Context, layout: KeyframeGraphLayout) -> [Handle] {
        guard let selected else { return [] }
        var result: [Handle] = []
        for (index, segment) in KeyframeGraphLayout.segments(of: c.value).enumerated() {
            if segment.from.time == selected, segment.from.easeOut != nil,
               let handle = handle(segment: index, outgoing: true, c, value: c.value, layout: layout) {
                result.append(handle)
            }
            if segment.to.time == selected, segment.to.easeIn != nil,
               let handle = handle(segment: index, outgoing: false, c, value: c.value, layout: layout) {
                result.append(handle)
            }
        }
        return result
    }

    /// The ease a side's handle drawn at `point` makes, measured against
    /// its segment. Over a flat segment there is no slope to read, so the
    /// speed it had is kept.
    private func ease(handleAt point: CGPoint, segment index: Int, outgoing: Bool, _ c: Context, value: AnimatedValue<ComponentValue>, layout: KeyframeGraphLayout) -> KeyframeEase? {
        let segments = KeyframeGraphLayout.segments(of: value)
        guard segments.indices.contains(index) else { return nil }
        let (from, to) = segments[index]
        let component = referenceComponent(from: from, to: to, layout: layout)
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

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func target(at point: CGPoint, _ c: Context, layout: KeyframeGraphLayout) -> Target {
        if let handle = handles(c, layout: layout).first(where: { distance($0.point, point) < 8 }) {
            return .handle(segment: handle.segment, outgoing: handle.outgoing)
        }
        var nearest: (target: Target, distance: CGFloat)?
        for keyframe in c.value.keyframes {
            for component in visible(keyframe.value.values.count) {
                let stored = keyframe.value.values[component]
                let d = distance(CGPoint(x: layout.x(keyframe.time.seconds), y: layout.y(stored + c.offset[component], component: component)), point)
                if d < 8, d < nearest?.distance ?? .infinity {
                    nearest = (.keyframe(keyframe.time, component: component), d)
                }
            }
        }
        if case .keyframe(let time, _) = nearest?.target, NSEvent.modifierFlags.contains(.option) {
            return .pull(time)
        }
        return nearest?.target ?? .scrub
    }

    private func dragGesture(_ c: Context, layout: KeyframeGraphLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if drag == nil {
                    let target = target(at: gesture.startLocation, c, layout: layout)
                    drag = Drag(target: target, layout: layout, original: c.value)
                    if case .keyframe(let time, _) = target { selected = time }
                    if case .pull(let time) = target { selected = time }
                    if case .scrub = target { selected = nil }
                }
                guard let drag else { return }
                switch drag.target {
                case .scrub:
                    hud.onSeek(c.axis.timelineTime(atKey: c.axis.snapped(drag.layout.seconds(atX: gesture.location.x))))
                case .keyframe(let time, let component):
                    guard abs(gesture.translation.width) >= 2 || abs(gesture.translation.height) >= 2 else { return }
                    draft = movedKeyframe(time, component: component, by: gesture.translation, drag: drag, c)
                case .handle(let segment, let outgoing):
                    let alone = NSEvent.modifierFlags.contains(.option)
                    draft = movedHandle(segment, outgoing: outgoing, to: gesture.location, alone: alone, drag: drag, c)
                case .pull(let time):
                    // The side the drag heads to; nothing until it heads somewhere.
                    guard abs(gesture.translation.width) >= 2 else { return }
                    let outgoing = gesture.translation.width > 0
                    let keyframes = drag.original.keyframes
                    guard let index = keyframes.firstIndex(where: { $0.time == time }) else { return }
                    let segment = outgoing ? index : index - 1
                    guard segment >= 0, segment < keyframes.count - 1 else { return }
                    draft = movedHandle(segment, outgoing: outgoing, to: gesture.location, alone: true, drag: drag, c)
                }
            }
            .onEnded { gesture in
                if case .pull(let time) = drag?.target,
                   abs(gesture.translation.width) < 2, abs(gesture.translation.height) < 2 {
                    // Option-click: linear becomes bezier, and bezier linear.
                    edit { $0.toggleBezier(at: time) }
                } else if let draft, draft != drag?.original {
                    committed = draft
                    edit { $0 = draft }
                    Task { @MainActor in
                        // In case the edit didn't land and nothing clears it.
                        try? await Task.sleep(for: .milliseconds(500))
                        if committed == draft { committed = nil }
                    }
                }
                draft = nil
                drag = nil
            }
    }

    /// The keyframes with one moved by a drag: in time, on frames and
    /// between its neighbors, and in the dragged component's value.
    private func movedKeyframe(_ time: CMTime, component: Int, by translation: CGSize, drag: Drag, _ c: Context) -> AnimatedValue<ComponentValue> {
        var result = drag.original
        guard let index = result.keyframes.firstIndex(where: { $0.time == time }) else { return result }
        let layout = drag.layout
        var dx = translation.width, dy = translation.height
        if NSEvent.modifierFlags.contains(.shift) {
            if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
        }
        let frame = c.axis.keyTime(atTimeline: c.axis.timelineTime(atKey: time) + c.timeline.frameDuration) - time
        var newTime = dx == 0 ? time : c.axis.snapped(time.seconds + Double(dx) * layout.secondsPerPoint)
        if index > 0 { newTime = CMTimeMaximum(newTime, CMTimeAdd(result.keyframes[index - 1].time, frame)) }
        if index < result.keyframes.count - 1 { newTime = CMTimeMinimum(newTime, CMTimeSubtract(result.keyframes[index + 1].time, frame)) }
        var moved = result.keyframes[index].value
        let shown = moved.values[component] + c.offset[component]
        let newShown = layout.value(atY: layout.y(shown, component: component) + dy, component: component)
        moved.values[component] = key.parameter.clamped(newShown - c.offset[component], index: component)
        result.moveKeyframe(at: time, to: newTime)
        result.set(moved, at: newTime)
        selected = newTime
        return result
    }

    /// The keyframes with one side's ease set from a handle dragged to
    /// `location`. Unless `alone`, the keyframe's other handle, if that
    /// side is eased, swings to stay on one line through the keyframe with
    /// the dragged one, keeping its own length on screen. Dragged onto the
    /// keyframe, the handle goes and its side turns linear.
    private func movedHandle(_ segment: Int, outgoing: Bool, to location: CGPoint, alone: Bool, drag: Drag, _ c: Context) -> AnimatedValue<ComponentValue> {
        var result = drag.original
        let layout = drag.layout
        let segments = KeyframeGraphLayout.segments(of: result)
        guard segments.indices.contains(segment),
              let dragged = handle(segment: segment, outgoing: outgoing, c, value: result, layout: layout)
        else { return result }
        let keyframe = outgoing ? segments[segment].from : segments[segment].to
        let collapsed = distance(location, dragged.anchor) < Self.collapseDistance
        var easeIn = keyframe.easeIn, easeOut = keyframe.easeOut
        let newEase = collapsed ? nil : ease(handleAt: location, segment: segment, outgoing: outgoing, c, value: result, layout: layout)
        if outgoing { easeOut = newEase } else { easeIn = newEase }

        // The other side's handle, on the segment across the keyframe.
        let otherSegment = outgoing ? segment - 1 : segment + 1
        let otherEase = outgoing ? keyframe.easeIn : keyframe.easeOut
        if !alone, !collapsed, otherEase != nil,
           let other = handle(segment: otherSegment, outgoing: !outgoing, c, value: result, layout: layout) {
            let length = distance(other.point, other.anchor)
            let dx = location.x - dragged.anchor.x, dy = location.y - dragged.anchor.y
            let reach = hypot(dx, dy)
            if reach > 0 {
                let point = CGPoint(x: other.anchor.x - dx / reach * length, y: other.anchor.y - dy / reach * length)
                let swung = ease(handleAt: point, segment: otherSegment, outgoing: !outgoing, c, value: result, layout: layout)
                if outgoing { easeIn = swung } else { easeOut = swung }
            }
        }
        result.setEase(at: keyframe.time, in: easeIn, out: easeOut)
        return result
    }

    private func edit(_ change: @escaping (inout AnimatedValue<ComponentValue>) -> Void) {
        let key = key
        hud.onEdit { $0.editComponents(of: key, change) }
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
