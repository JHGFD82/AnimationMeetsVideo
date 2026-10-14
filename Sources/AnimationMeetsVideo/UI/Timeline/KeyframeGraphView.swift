import AppKit
import CoreMedia
import SwiftUI

/// Where a parameter's graph draws things: time across the span of its
/// keyframes, the shown value up. Worked out from the keyframes when a
/// drag starts and kept until it ends, so the graph doesn't rescale under
/// the pointer.
struct KeyframeGraphLayout: Equatable {
    var times: ClosedRange<Double>
    var values: ClosedRange<Double>
    var plot: CGRect

    static let insets = EdgeInsets(top: 12, leading: 52, bottom: 20, trailing: 14)

    /// Fits `value`'s keyframes, curves and handles (shown with `offset`
    /// added) into `size`.
    init(_ value: AnimatedValue<ComponentValue>, offset: [Double], size: CGSize) {
        let insets = Self.insets
        plot = CGRect(
            x: insets.leading, y: insets.top,
            width: max(1, size.width - insets.leading - insets.trailing),
            height: max(1, size.height - insets.top - insets.bottom)
        )
        let keyTimes = value.keyframes.map(\.time.seconds)
        var start = keyTimes.first ?? 0, end = keyTimes.last ?? 1
        if end - start < 1 {
            let middle = (start + end) / 2
            start = middle - 0.5
            end = middle + 0.5
        }
        let pad = (end - start) * 0.08
        times = (start - pad)...(end + pad)

        var low = Double.infinity, high = -Double.infinity
        func include(_ shown: Double) {
            low = min(low, shown)
            high = max(high, shown)
        }
        for index in 0...120 {
            let time = CMTime(seconds: start + (end - start) * Double(index) / 120, preferredTimescale: 6000)
            for (component, stored) in value.value(at: time).values.enumerated() {
                include(stored + (component < offset.count ? offset[component] : 0))
            }
        }
        for segment in Self.segments(of: value) {
            for component in segment.from.value.values.indices {
                let shift = component < offset.count ? offset[component] : 0
                let a = segment.from.value.values[component] + shift
                let b = segment.to.value.values[component] + shift
                for handle in [KeyframeEase.outgoingHandle(segment.from.easeOut), KeyframeEase.incomingHandle(segment.to.easeIn)] {
                    include(a + Double(handle.y) * (b - a))
                }
            }
        }
        if !low.isFinite { low = 0; high = 1 }
        if high - low < 1e-6 {
            low -= 1
            high += 1
        }
        let valuePad = (high - low) * 0.1
        values = (low - valuePad)...(high + valuePad)
    }

    static func segments(of value: AnimatedValue<ComponentValue>) -> [(from: Keyframe<ComponentValue>, to: Keyframe<ComponentValue>)] {
        zip(value.keyframes, value.keyframes.dropFirst()).map { ($0, $1) }
    }

    func x(_ seconds: Double) -> CGFloat {
        plot.minX + plot.width * CGFloat((seconds - times.lowerBound) / (times.upperBound - times.lowerBound))
    }

    func y(_ shown: Double) -> CGFloat {
        plot.maxY - plot.height * CGFloat((shown - values.lowerBound) / (values.upperBound - values.lowerBound))
    }

    func seconds(atX x: CGFloat) -> Double {
        times.lowerBound + Double((x - plot.minX) / plot.width) * (times.upperBound - times.lowerBound)
    }

    func value(atY y: CGFloat) -> Double {
        values.lowerBound + Double((plot.maxY - y) / plot.height) * (values.upperBound - values.lowerBound)
    }
}

/// One parameter's keyframes as a value graph, for its HUD panel: a line
/// per component over time, each keyframe a point on it. Drag a point to
/// move the keyframe in time (on frames) and value; Shift keeps it to one
/// direction. Click a point to select it and show the bezier handles of
/// its eased sides. Dragging a handle shapes that side's ease and swings
/// the other side's handle to stay in line with it, at its own length;
/// with Option it moves alone. A handle dragged onto its keyframe goes,
/// leaving that side linear, and Option-dragging a keyframe pulls a handle
/// out of a linear side, the side the drag heads to. Click elsewhere to move
/// the playhead there; double-click to add a keyframe. The buttons and the
/// right-click menu apply ease presets to the selected keyframe, or to the
/// one at the playhead.
struct KeyframeGraphView: View {
    let hud: KeyframeGraphHUDs
    let key: ParameterKey

    /// The keyframes as a drag in progress leaves them, drawn instead of
    /// the project's and saved when the drag ends.
    @State private var draft: AnimatedValue<ComponentValue>?
    /// A finished drag's keyframes, drawn until the project has them, so
    /// the old ones don't show for a frame on release.
    @State private var committed: AnimatedValue<ComponentValue>?
    @State private var drag: Drag?
    @State private var selected: CMTime?

    private enum Target: Equatable {
        case keyframe(CMTime, component: Int)
        case handle(segment: Int, outgoing: Bool)
        /// Option-dragging a keyframe: pulls a handle out of the side the
        /// drag heads to.
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

    private static let palette: [Color] = [Design.statusDanger, Design.statusDone, Design.accent]

    var body: some View {
        if let timeline = hud.project.timeline(id: key.timelineID), let stored = hud.project.components(of: key) {
            let value = draft ?? committed ?? stored
            let offset = key.parameter.displayOffset(frameSize: timeline.frameSize)
            VStack(spacing: 0) {
                toolbar(value, offset: offset, timeline: timeline)
                Divider()
                if value.keyframes.count < 2 {
                    Text(value.isAnimated
                         ? "Add a second keyframe to shape the curve between them."
                         : "\(key.parameter.name) isn't animated. Turn on its stopwatch to add keyframes.")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        let layout = drag?.layout ?? KeyframeGraphLayout(value, offset: offset, size: geometry.size)
                        Canvas { context, _ in
                            draw(value, offset: offset, layout: layout, timeline: timeline, in: &context)
                        }
                        .contentShape(Rectangle())
                        .gesture(dragGesture(value: value, offset: offset, layout: layout, timeline: timeline))
                        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
                            let time = timeline.snappedToFrame(CMTime(seconds: max(0, layout.seconds(atX: tap.location.x)), preferredTimescale: 6000))
                            edit { $0.toggleKeyframe(at: time) }
                            selected = time
                        })
                        .contextMenu {
                            if let target = presetTarget(value, timeline: timeline) {
                                KeyframeEaseMenuItems { preset in edit { $0.applyEase(preset, at: target) } }
                                Divider()
                                Button("Delete Keyframe", role: .destructive) {
                                    edit { $0.removeKeyframe(at: target) }
                                    selected = nil
                                }
                            }
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

    // MARK: - Toolbar

    /// The selected keyframe if it still exists, else the one at the playhead.
    private func presetTarget(_ value: AnimatedValue<ComponentValue>, timeline: Timeline) -> CMTime? {
        if let selected, value.keyframe(at: selected) != nil { return selected }
        let playhead = timeline.snappedToFrame(hud.playhead)
        return value.keyframe(at: playhead) != nil ? playhead : nil
    }

    private func toolbar(_ value: AnimatedValue<ComponentValue>, offset: [Double], timeline: Timeline) -> some View {
        let target = presetTarget(value, timeline: timeline)
        let shown = zip(value.value(at: timeline.snappedToFrame(hud.playhead)).values, offset).map { $0 + $1 }
        let names = key.parameter.componentNames
        return HStack(spacing: Design.Space.step) {
            ForEach(shown.indices, id: \.self) { index in
                HStack(spacing: 3) {
                    if names.count > 1 {
                        Circle().fill(Self.palette[index % Self.palette.count]).frame(width: 6, height: 6)
                        Text(names[index]).foregroundStyle(Design.textTertiary)
                    }
                    Text(key.parameter.label(shown[index]))
                        .font(Design.Typeface.numericSmall)
                        .foregroundStyle(Design.textPrimary)
                }
            }
            Spacer(minLength: Design.Space.step)
            Text(target.map { "Keyframe \($0.timecode(frameRate: timeline.frameRate))" } ?? "No keyframe selected")
                .foregroundStyle(Design.textTertiary)
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

    // MARK: - Drawing

    private func color(_ component: Int, of count: Int) -> Color {
        count == 1 ? Design.keyframe : Self.palette[component % Self.palette.count]
    }

    private func draw(_ value: AnimatedValue<ComponentValue>, offset: [Double], layout: KeyframeGraphLayout, timeline: Timeline, in context: inout GraphicsContext) {
        let plot = layout.plot
        let count = value.value.values.count

        // Value grid with labels, and the time span's ends.
        for step in 0...4 {
            let shown = layout.values.lowerBound + (layout.values.upperBound - layout.values.lowerBound) * Double(step) / 4
            let y = layout.y(shown)
            context.fill(Path(CGRect(x: plot.minX, y: y, width: plot.width, height: 0.5)), with: .color(.white.opacity(0.08)))
            context.draw(
                Text(key.parameter.label(shown)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Design.textTertiary),
                at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing
            )
        }
        for (seconds, anchor) in [(layout.times.lowerBound, UnitPoint.topLeading), (layout.times.upperBound, .topTrailing)] {
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 6000)
            context.draw(
                Text(time.timecode(frameRate: timeline.frameRate)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Design.textTertiary),
                at: CGPoint(x: layout.x(seconds), y: plot.maxY + 4), anchor: anchor
            )
        }

        // The curves, a point every two points across.
        for component in 0..<count {
            var line = Path()
            var x = plot.minX
            while x <= plot.maxX {
                let time = CMTime(seconds: layout.seconds(atX: x), preferredTimescale: 6000)
                let point = CGPoint(x: x, y: layout.y(value.value(at: time).values[component] + offset[component]))
                if line.isEmpty { line.move(to: point) } else { line.addLine(to: point) }
                x += 2
            }
            context.stroke(line, with: .color(color(component, of: count)), lineWidth: 1.5)
        }

        // The playhead.
        let playheadX = layout.x(hud.playhead.seconds)
        if (plot.minX...plot.maxX).contains(playheadX) {
            context.fill(Path(CGRect(x: playheadX - 0.5, y: plot.minY, width: 1, height: plot.height)), with: .color(Design.playhead))
        }

        // The selected keyframe's handles, on the component that changes
        // most over each of its segments.
        for handle in handles(of: value, offset: offset, layout: layout) {
            var stem = Path()
            stem.move(to: handle.anchor)
            stem.addLine(to: handle.point)
            context.stroke(stem, with: .color(.white.opacity(0.6)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: handle.point.x - 3.5, y: handle.point.y - 3.5, width: 7, height: 7)), with: .color(.white))
        }

        // The keyframes.
        for keyframe in value.keyframes {
            let isSelected = keyframe.time == selected
            for component in 0..<count {
                let center = CGPoint(x: layout.x(keyframe.time.seconds), y: layout.y(keyframe.value.values[component] + offset[component]))
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
        /// The keyframe's point, and the handle's.
        var anchor: CGPoint
        var point: CGPoint
    }

    /// The component whose change over a segment is largest on screen,
    /// which its handles are drawn against.
    private func referenceComponent(from: Keyframe<ComponentValue>, to: Keyframe<ComponentValue>, layout: KeyframeGraphLayout) -> Int {
        let deltas = zip(from.value.values, to.value.values).map { abs(layout.y($1) - layout.y($0)) }
        return deltas.indices.max { deltas[$0] < deltas[$1] } ?? 0
    }

    /// Where a side's handle and its keyframe are drawn, against the
    /// segment's reference component; a linear side's at its implied place.
    private func handle(segment index: Int, outgoing: Bool, of value: AnimatedValue<ComponentValue>, offset: [Double], layout: KeyframeGraphLayout) -> Handle? {
        let segments = KeyframeGraphLayout.segments(of: value)
        guard segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        let component = referenceComponent(from: segment.from, to: segment.to, layout: layout)
        let a = segment.from.value.values[component] + offset[component]
        let b = segment.to.value.values[component] + offset[component]
        let unit = outgoing ? KeyframeEase.outgoingHandle(segment.from.easeOut) : KeyframeEase.incomingHandle(segment.to.easeIn)
        let t0 = segment.from.time.seconds, t1 = segment.to.time.seconds
        let point = CGPoint(x: layout.x(t0 + Double(unit.x) * (t1 - t0)), y: layout.y(a + Double(unit.y) * (b - a)))
        let anchor = outgoing ? CGPoint(x: layout.x(t0), y: layout.y(a)) : CGPoint(x: layout.x(t1), y: layout.y(b))
        return Handle(segment: index, outgoing: outgoing, anchor: anchor, point: point)
    }

    /// The handles of the selected keyframe's eased sides. A linear side
    /// has none to show.
    private func handles(of value: AnimatedValue<ComponentValue>, offset: [Double], layout: KeyframeGraphLayout) -> [Handle] {
        guard let selected else { return [] }
        var result: [Handle] = []
        for (index, segment) in KeyframeGraphLayout.segments(of: value).enumerated() {
            if segment.from.time == selected, segment.from.easeOut != nil,
               let handle = handle(segment: index, outgoing: true, of: value, offset: offset, layout: layout) {
                result.append(handle)
            }
            if segment.to.time == selected, segment.to.easeIn != nil,
               let handle = handle(segment: index, outgoing: false, of: value, offset: offset, layout: layout) {
                result.append(handle)
            }
        }
        return result
    }

    /// The ease a side's handle drawn at `point` makes, measured against
    /// its segment. Over a flat segment there is no slope to read, so the
    /// speed it had is kept.
    private func ease(handleAt point: CGPoint, segment index: Int, outgoing: Bool, of value: AnimatedValue<ComponentValue>, offset: [Double], layout: KeyframeGraphLayout) -> KeyframeEase? {
        let segments = KeyframeGraphLayout.segments(of: value)
        guard segments.indices.contains(index) else { return nil }
        let (from, to) = segments[index]
        let component = referenceComponent(from: from, to: to, layout: layout)
        let a = from.value.values[component] + offset[component]
        let b = to.value.values[component] + offset[component]
        let t0 = from.time.seconds, t1 = to.time.seconds
        let flat = abs(b - a) < 1e-9
        let unit = CGPoint(
            x: (layout.seconds(atX: point.x) - t0) / (t1 - t0),
            y: flat ? 0 : (layout.value(atY: point.y) - a) / (b - a)
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

    private func target(at point: CGPoint, value: AnimatedValue<ComponentValue>, offset: [Double], layout: KeyframeGraphLayout) -> Target {
        if let handle = handles(of: value, offset: offset, layout: layout).first(where: { distance($0.point, point) < 8 }) {
            return .handle(segment: handle.segment, outgoing: handle.outgoing)
        }
        var nearest: (target: Target, distance: CGFloat)?
        for keyframe in value.keyframes {
            for (component, stored) in keyframe.value.values.enumerated() {
                let d = distance(CGPoint(x: layout.x(keyframe.time.seconds), y: layout.y(stored + offset[component])), point)
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

    private func dragGesture(value: AnimatedValue<ComponentValue>, offset: [Double], layout: KeyframeGraphLayout, timeline: Timeline) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if drag == nil {
                    let target = target(at: gesture.startLocation, value: value, offset: offset, layout: layout)
                    drag = Drag(target: target, layout: layout, original: value)
                    if case .keyframe(let time, _) = target { selected = time }
                    if case .pull(let time) = target { selected = time }
                    if case .scrub = target { selected = nil }
                }
                guard let drag else { return }
                switch drag.target {
                case .scrub:
                    hud.onSeek(timeline.snappedToFrame(CMTime(seconds: max(0, drag.layout.seconds(atX: gesture.location.x)), preferredTimescale: 6000)))
                case .keyframe(let time, let component):
                    guard abs(gesture.translation.width) >= 2 || abs(gesture.translation.height) >= 2 else { return }
                    draft = movedKeyframe(time, component: component, by: gesture.translation, drag: drag, offset: offset, timeline: timeline)
                case .handle(let segment, let outgoing):
                    let alone = NSEvent.modifierFlags.contains(.option)
                    draft = movedHandle(segment, outgoing: outgoing, to: gesture.location, alone: alone, drag: drag, offset: offset)
                case .pull(let time):
                    // The side the drag heads to; nothing until it heads somewhere.
                    guard abs(gesture.translation.width) >= 1 else { return }
                    let outgoing = gesture.translation.width > 0
                    let keyframes = drag.original.keyframes
                    guard let index = keyframes.firstIndex(where: { $0.time == time }) else { return }
                    let segment = outgoing ? index : index - 1
                    guard segment >= 0, segment < keyframes.count - 1 else { return }
                    draft = movedHandle(segment, outgoing: outgoing, to: gesture.location, alone: true, drag: drag, offset: offset)
                }
            }
            .onEnded { _ in
                if let draft, draft != drag?.original {
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
    private func movedKeyframe(_ time: CMTime, component: Int, by translation: CGSize, drag: Drag, offset: [Double], timeline: Timeline) -> AnimatedValue<ComponentValue> {
        var result = drag.original
        guard let index = result.keyframes.firstIndex(where: { $0.time == time }) else { return result }
        let layout = drag.layout
        var dx = translation.width, dy = translation.height
        if NSEvent.modifierFlags.contains(.shift) {
            if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
        }
        let frame = timeline.frameDuration
        var newTime = timeline.snappedToFrame(CMTime(seconds: time.seconds + Double(dx) * (layout.times.upperBound - layout.times.lowerBound) / Double(layout.plot.width), preferredTimescale: 6000))
        if index > 0 { newTime = CMTimeMaximum(newTime, CMTimeAdd(result.keyframes[index - 1].time, frame)) }
        if index < result.keyframes.count - 1 { newTime = CMTimeMinimum(newTime, CMTimeSubtract(result.keyframes[index + 1].time, frame)) }
        var moved = result.keyframes[index].value
        let shown = moved.values[component] + offset[component]
        let newShown = layout.value(atY: layout.y(shown) + dy)
        moved.values[component] = key.parameter.clamped(newShown - offset[component])
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
    private func movedHandle(_ segment: Int, outgoing: Bool, to location: CGPoint, alone: Bool, drag: Drag, offset: [Double]) -> AnimatedValue<ComponentValue> {
        var result = drag.original
        let layout = drag.layout
        let segments = KeyframeGraphLayout.segments(of: result)
        guard segments.indices.contains(segment),
              let dragged = handle(segment: segment, outgoing: outgoing, of: result, offset: offset, layout: layout)
        else { return result }
        let keyframe = outgoing ? segments[segment].from : segments[segment].to
        let collapsed = distance(location, dragged.anchor) < Self.collapseDistance
        var easeIn = keyframe.easeIn, easeOut = keyframe.easeOut
        let newEase = collapsed ? nil : ease(handleAt: location, segment: segment, outgoing: outgoing, of: result, offset: offset, layout: layout)
        if outgoing { easeOut = newEase } else { easeIn = newEase }

        // The other side's handle, on the segment across the keyframe.
        let otherSegment = outgoing ? segment - 1 : segment + 1
        let otherEase = outgoing ? keyframe.easeIn : keyframe.easeOut
        if !alone, !collapsed, otherEase != nil,
           let other = handle(segment: otherSegment, outgoing: !outgoing, of: result, offset: offset, layout: layout) {
            let length = distance(other.point, other.anchor)
            let dx = location.x - dragged.anchor.x, dy = location.y - dragged.anchor.y
            let reach = hypot(dx, dy)
            if reach > 0 {
                let point = CGPoint(x: other.anchor.x - dx / reach * length, y: other.anchor.y - dy / reach * length)
                let swung = ease(handleAt: point, segment: otherSegment, outgoing: !outgoing, of: result, offset: offset, layout: layout)
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
