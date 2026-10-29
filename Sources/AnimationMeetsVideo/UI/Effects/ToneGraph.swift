import AppKit
import CoreMedia
import SwiftUI

/// Where tones sit on a tone graph: black to reference white across and up.
struct ToneGraphLayout {
    let plot: CGRect

    func x(_ tone: Double) -> CGFloat { plot.minX + CGFloat(tone.clamped(between: 0, and: 1)) * plot.width }
    func y(_ tone: Double) -> CGFloat { plot.maxY - CGFloat(tone.clamped(between: 0, and: 1)) * plot.height }
    func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: self.x(x), y: self.y(y)) }

    func tone(atX x: CGFloat) -> Double { Double((x - plot.minX) / max(plot.width, 1)) }
    func tone(atY y: CGFloat) -> Double { Double((plot.maxY - y) / max(plot.height, 1)) }
}

/// An effect's tone graph (see docs/effects-correction.md, "Tone graphs"):
/// tones from black to white across, what they become up, above the
/// effect's controls in the effects panel.
///
/// - **Curves** (an effect whose package lists curve controls, Curves):
///   the picked curve bold with its points, the others faint in their
///   colors. Drag a point to move it; click or drag between the edges
///   where there is none to add one there; double-click a point to delete
///   it. The edges, the first and last points, stay where they are up,
///   drawn small and not dragged on the plot: only the slider under it
///   (`ToneCurveEdgeSlider`) moves them, across.
/// - **Handles** (Levels, Threshold, Highs & Lows, Solarize): what the
///   kernel does to each tone, measured by drawing it (`ToneResponse`),
///   with the package's handles on it; dragging one sets the controls it
///   names.
///
/// With a point or handle picked (clicked, or reached with Tab), the arrow
/// keys move it a hundredth of the way (a tenth with Shift), Delete removes
/// a point other than an edge and + adds one in the widest gap; the buttons beside the graph
/// add and delete points too. VoiceOver reaches each point and handle as an
/// element of its own with the same actions.
///
/// A drag is held to one side of the project (`ProjectState.hold`), with
/// the graph drawn from its own copy of the effect, and written to the
/// project once, when it ends, as one undo step.
struct ToneGraph: View {
    /// The effect the project has; `effect` is the drag's while one is held.
    let committed: Effect
    /// The clip's source time at the playhead, where edits land.
    let time: CMTime
    var isDimmed = false
    /// Changes one control of the effect.
    let onEdit: (ControlKind, @escaping (inout EffectControl) -> Void) -> Void

    @Environment(\.projectHistory) private var history
    @Environment(ProjectState.self) private var projectState: ProjectState?
    @State private var heldEffect: Effect?
    @State private var stepEdits: [(kind: ControlKind, change: (inout EffectControl) -> Void)] = []
    /// The curve being edited, among the graph's.
    @State private var channel: ControlKind?
    /// The picked point of the curve, or handle, by its index.
    @State private var picked: Int?
    @State private var drag: DragState?
    /// The effect's measured response, kept while the next is measured.
    @State private var response: [SIMD3<Double>]?
    @FocusState private var isFocused: Bool

    /// The height it takes in the effects panel.
    static let panelHeight: CGFloat = 176

    /// A hundredth of the tones per arrow key press.
    private static let nudge = 0.01

    private struct DragState {
        var index: Int
        /// The effect as the drag found it, which each step starts from.
        var start: Effect
        /// Where the dragged point or handle was, in tones.
        var from: (x: Double, y: Double)
    }

    private struct ResponseRequest: Equatable {
        var effect: Effect
        var time: CMTime
    }

    init(effect: Effect, time: CMTime, isDimmed: Bool = false, onEdit: @escaping (ControlKind, @escaping (inout EffectControl) -> Void) -> Void) {
        committed = effect
        self.time = time
        self.isDimmed = isDimmed
        self.onEdit = onEdit
    }

    private var effect: Effect { heldEffect ?? committed }
    private var package: EffectPackage? { effect.kind.definition.package }
    private var graph: EffectPackage.Graph? { package?.graph }

    /// The graph's curves the effect still has (a deleted one is gone).
    private var curves: [ControlKind] { (graph?.curves ?? []).filter { effect.control($0) != nil } }
    private var editedCurve: ControlKind? { channel.flatMap { curves.contains($0) ? $0 : nil } ?? curves.first }
    private var handles: [EffectPackage.Graph.Handle] { graph?.handles ?? [] }

    var body: some View {
        HStack(alignment: .top, spacing: Design.Space.step) {
            GeometryReader { proxy in
                // Inset so a point at a corner is drawn whole, and above a
                // curve's edge slider.
                let square = min(proxy.size.width, proxy.size.height)
                let band = editedCurve == nil ? 0 : ToneCurveEdgeSlider.height + 4
                let side = max(square - 16 - band, 10)
                let layout = ToneGraphLayout(plot: CGRect(x: (square - side) / 2, y: 8, width: side, height: side))
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(in: &context, layout: layout) }
                        .contentShape(Rectangle())
                        .gesture(dragGesture(layout))
                        .onTapGesture(count: 2, coordinateSpace: .local) { location in
                            guard let index = self.index(near: location, layout: layout) else { return }
                            removePoint(index)
                        }
                        .onTapGesture(count: 1, coordinateSpace: .local) { location in tap(at: location, layout: layout) }
                        .accessibilityHidden(true)
                    ForEach(Array(nodePlaces(layout).enumerated()), id: \.offset) { index, place in
                        accessibleNode(index, at: place)
                    }
                    if let kind = editedCurve {
                        edgeSlider(kind, layout: layout)
                            .frame(width: square, height: ToneCurveEdgeSlider.height)
                            .offset(y: layout.plot.maxY + 4)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color.black.opacity(0.18))
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .tab, .delete, .deleteForward, "+", "="]) { press in
                handle(press.key, modifiers: press.modifiers) ? .handled : .ignored
            }
            sidebar
        }
        .task(id: ResponseRequest(effect: effect, time: time)) { await measure() }
        .opacity(isDimmed ? 0.55 : 1)
    }

    /// The curve picker, what is picked, and the point buttons.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Design.Space.close) {
            if curves.count > 1 {
                Picker("Curve", selection: Binding(get: { editedCurve }, set: { channel = $0; picked = nil })) {
                    ForEach(curves, id: \.self) { Text($0.name).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("The curve the graph edits")
            }
            Text(pickedDescription)
                .font(Design.Typeface.numericMicro)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(2)
            if let kind = editedCurve {
                HStack(spacing: Design.Space.tight) {
                    Button("Add Point") { addPoint(to: kind) }
                        .help("Add a point to the \(kind.name) curve in its widest gap (+)")
                    Button("Delete Point") { picked.map(removePoint) }
                        .disabled(!(picked.map(curve(kind).canRemove) ?? false))
                        .help("Delete the picked point (Delete); the edges stay, moved by the slider under the graph")
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
            Text(curves.isEmpty ? "Drag a handle; arrows nudge the picked one." : "Click to add a point, drag to move, double-click to delete. The slider moves the edges.")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 220, alignment: .leading)
        .padding(.vertical, 4)
    }

    // MARK: Reading

    private func curve(_ kind: ControlKind) -> ToneCurve {
        effect.control(kind).map { $0.curve(at: time) } ?? .identity
    }

    /// Where each point of the edited curve, or each handle, is in tones.
    private func places() -> [(x: Double, y: Double)] { placesIn(effect) }

    private func nodePlaces(_ layout: ToneGraphLayout) -> [CGPoint] {
        places().map { layout.point($0.x, $0.y) }
    }

    /// Whether point `index` is an edge of the edited curve, which only
    /// the edge slider moves.
    private func isCurveEdge(_ index: Int) -> Bool {
        editedCurve.map { curve($0).isEdge(index) } ?? false
    }

    /// The point or handle nearest `location`, within reach of a click; never
    /// a curve's edge.
    private func index(near location: CGPoint, layout: ToneGraphLayout) -> Int? {
        let reach: CGFloat = 9
        return nodePlaces(layout).enumerated()
            .filter { !isCurveEdge($0.offset) }
            .map { ($0.offset, hypot($0.element.x - location.x, $0.element.y - location.y)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    private func percent(_ tone: Double) -> String { NumericExpression.format(tone * 100, maxFractionDigits: 1) + "%" }

    private var pickedDescription: String {
        let places = places()
        guard let picked, places.indices.contains(picked) else {
            if let kind = editedCurve { return "\(kind.name): \(curve(kind).points.count) points" }
            return handles.map(\.name).joined(separator: ", ")
        }
        let place = places[picked]
        let name = editedCurve == nil ? handles[picked].name
            : picked == 0 ? "Left edge" : picked == places.count - 1 ? "Right edge" : "Point \(picked + 1)"
        return "\(name): \(percent(place.x)) → \(percent(place.y))"
    }

    private func measure() async {
        guard graph?.showsResponse == true else { return }
        let effect = effect, time = time
        let measured = await Task.detached(priority: .userInitiated) { ToneResponse.measure(effect, at: time) }.value
        guard !Task.isCancelled else { return }
        response = measured
    }

    // MARK: Editing

    /// An edit a drag makes: to the project, and while the drag is held to
    /// the copy of the effect the graph draws.
    private func dragEdit(_ kind: ControlKind, _ change: @escaping (inout EffectControl) -> Void) {
        if heldEffect != nil {
            heldEffect = heldEffect?.changing(kind, change)
            stepEdits.append((kind, change))
        }
        onEdit(kind, change)
    }

    /// A click on a point picks it; anywhere else on a curve adds a point
    /// there.
    private func tap(at location: CGPoint, layout: ToneGraphLayout) {
        isFocused = true
        if let index = index(near: location, layout: layout) {
            picked = index
            return
        }
        guard let kind = editedCurve else {
            picked = nil
            return
        }
        let x = layout.tone(atX: location.x), y = layout.tone(atY: location.y)
        guard let index = curve(kind).insertionIndex(atX: x) else { return }
        let time = time
        onEdit(kind) { control in
            control.enabled = true
            control.insertCurvePoint(atX: x, at: time)
            control.setCurve(control.curve(at: time).moving(index, toX: x, y: y), at: time)
        }
        picked = index
    }

    private func dragGesture(_ layout: ToneGraphLayout) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil, !beginDrag(at: value.startLocation, layout: layout) { return }
                let shift = NSEvent.modifierFlags.contains(.shift)
                var dx = Double(value.translation.width / max(layout.plot.width, 1))
                var dy = Double(-value.translation.height / max(layout.plot.height, 1))
                // ⇧ keeps a drag to one axis.
                if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
                dragStep(dx, dy)
            }
            .onEnded { _ in endDrag() }
    }

    /// The slider under the plot that moves the edited curve's edges.
    private func edgeSlider(_ kind: ControlKind, layout: ToneGraphLayout) -> some View {
        let points = curve(kind).points
        let last = points.count - 1
        func index(_ edge: ToneCurveEdgeSlider.Edge) -> Int { edge == .left ? 0 : last }
        return ToneCurveEdgeSlider(
            left: points[0].x, right: points[last].x, layout: layout,
            tint: Self.color(kind.curveTint).opacity(effect.control(kind)?.enabled ?? false ? 1 : 0.5),
            picked: picked == 0 ? .left : picked == last ? .right : nil,
            isFocused: isFocused,
            onDrag: { edge, dx in
                if drag == nil {
                    history?.beginGesture()
                    guard beginDrag(of: index(edge)) else { return }
                }
                dragStep(dx, 0)
            },
            onDragEnded: endDrag,
            onNudge: { edge, dx in nudge(index(edge), dx: dx) },
            name: "\(kind.name) curve"
        )
    }

    /// The drag moved by (`dx`, `dy`) tones since it began.
    private func dragStep(_ dx: Double, _ dy: Double) {
        guard let drag else { return }
        if let projectState {
            stepEdits = []
            projectState.hold { move(drag, by: dx, dy) }
        } else {
            move(drag, by: dx, dy)
        }
    }

    private func endDrag() {
        guard drag != nil else { return }
        let edits = stepEdits
        projectState?.endHold()
        heldEffect = nil
        stepEdits = []
        drag = nil
        // The drag's last step goes to the project once; a drag let go
        // (see `ProjectState.letGo`) has written it already.
        for edit in edits { onEdit(edit.kind, edit.change) }
        Task { @MainActor in history?.endGesture() }
    }

    /// Starts dragging the point or handle under `location`; on a curve
    /// with none there, a point added there first, as a change of its own.
    private func beginDrag(at location: CGPoint, layout: ToneGraphLayout) -> Bool {
        var index = self.index(near: location, layout: layout)
        if index == nil, let kind = editedCurve {
            let x = layout.tone(atX: location.x)
            guard let at = curve(kind).insertionIndex(atX: x) else { return false }
            history?.beginGesture()
            let time = time
            onEdit(kind) { control in
                control.enabled = true
                control.insertCurvePoint(atX: x, at: time)
            }
            heldEffect = committed.changing(kind) { control in
                control.enabled = true
                control.insertCurvePoint(atX: x, at: time)
            }
            index = at
        } else if index != nil {
            history?.beginGesture()
        }
        guard let index else { return false }
        return beginDrag(of: index)
    }

    /// Starts dragging point or handle `index`, from the effect with any
    /// point just added, which the project may not show yet.
    private func beginDrag(of index: Int) -> Bool {
        let start = heldEffect ?? effect
        heldEffect = projectState == nil ? nil : start
        let places = placesIn(start)
        guard places.indices.contains(index) else { return false }
        drag = DragState(index: index, start: start, from: places[index])
        picked = index
        isFocused = true
        projectState?.beginHold()
        return true
    }

    /// Where each point of the edited curve, or each handle, is in tones,
    /// in `effect`.
    private func placesIn(_ effect: Effect) -> [(x: Double, y: Double)] {
        if let kind = editedCurve {
            return (effect.control(kind).map { $0.curve(at: time) } ?? .identity).points.map { ($0.x, $0.y) }
        }
        guard let package else { return [] }
        return handles.map { $0.place(in: effect, of: package, at: time) }
    }

    /// Sets the dragged point or handle from where the drag has taken it.
    private func move(_ drag: DragState, by dx: Double, _ dy: Double) {
        set(drag.index, in: drag.start, to: drag.from.x + dx, drag.from.y + dy)
    }

    /// Point or handle `index` of `start` moved to tones (`x`, `y`); a
    /// curve's edge only across.
    private func set(_ index: Int, in start: Effect, to x: Double, _ y: Double) {
        let time = time
        let x = x.clamped(between: 0, and: 1), y = y.clamped(between: 0, and: 1)
        if let kind = editedCurve {
            let curve = start.control(kind).map { $0.curve(at: time) } ?? .identity
            guard curve.points.indices.contains(index) else { return }
            let moved = curve.moving(index, toX: x, y: curve.isEdge(index) ? curve.points[index].y : y)
            dragEdit(kind) { control in
                control.enabled = true
                control.setCurve(moved, at: time)
            }
            return
        }
        guard let package, handles.indices.contains(index) else { return }
        for (kind, value) in handles[index].settings(draggedTo: x, y, in: start, of: package, at: time) {
            dragEdit(kind) { control in
                control.enabled = true
                control.setComponent(0, to: value, at: time)
            }
        }
    }

    /// Point or handle `index` moved by a nudge, as one edit.
    private func nudge(_ index: Int, dx: Double = 0, dy: Double = 0) {
        let places = places()
        guard places.indices.contains(index) else { return }
        set(index, in: effect, to: places[index].x + dx, places[index].y + dy)
    }

    private func addPoint(to kind: ControlKind) {
        let x = curve(kind).widestGapMiddle
        let index = curve(kind).insertionIndex(atX: x)
        let time = time
        onEdit(kind) { control in
            control.enabled = true
            control.insertCurvePoint(atX: x, at: time)
        }
        picked = index
    }

    private func removePoint(_ index: Int) {
        guard let kind = editedCurve, curve(kind).canRemove(index) else { return }
        onEdit(kind) { $0.removeCurvePoint(index) }
        picked = nil
    }

    private func handle(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        let count = places().count
        let step = modifiers.contains(.shift) ? Self.nudge * 10 : Self.nudge
        switch key {
        case .tab:
            guard count > 0 else { return false }
            let delta = modifiers.contains(.shift) ? -1 : 1
            picked = picked.map { ($0 + delta + count) % count } ?? 0
        case "+", "=":
            guard let kind = editedCurve else { return false }
            addPoint(to: kind)
        case .delete, .deleteForward:
            guard let picked, editedCurve != nil else { return false }
            removePoint(picked)
        default:
            guard let picked, picked < count else { return false }
            switch key {
            case .leftArrow: nudge(picked, dx: -step)
            case .rightArrow: nudge(picked, dx: step)
            case .upArrow where isCurveEdge(picked), .downArrow where isCurveEdge(picked): return false
            case .upArrow: nudge(picked, dy: step)
            case .downArrow: nudge(picked, dy: -step)
            default: return false
            }
        }
        return true
    }

    // MARK: Accessibility

    /// An element over a point or handle, for VoiceOver: adjusting it moves
    /// it up or down (a handle that only moves across, or a curve's edge,
    /// across), and actions
    /// move it the other ways and delete a point.
    @ViewBuilder
    private func accessibleNode(_ index: Int, at place: CGPoint) -> some View {
        let places = places()
        if places.indices.contains(index) {
            let isCurve = editedCurve != nil
            let handle = isCurve ? nil : handles[index]
            let edge = index == 0 ? "left edge" : index == places.count - 1 ? "right edge" : "point \(index + 1) of \(places.count)"
            let name = handle?.name ?? "\(editedCurve?.name ?? "") curve \(edge)"
            let upAndDown = handle?.movesUp ?? !isCurveEdge(index)
            let across = handle?.movesAcross ?? true
            Color.clear
                .frame(width: 14, height: 14)
                .position(place)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(name)
                .accessibilityValue("in \(percent(places[index].x)), out \(percent(places[index].y))")
                .accessibilityAdjustableAction { direction in
                    let step = direction == .increment ? Self.nudge : -Self.nudge
                    if upAndDown { nudge(index, dy: step) } else { nudge(index, dx: step) }
                }
                .accessibilityActions {
                    if across && upAndDown {
                        Button("Move left") { nudge(index, dx: -Self.nudge) }
                        Button("Move right") { nudge(index, dx: Self.nudge) }
                    }
                    if let kind = editedCurve, curve(kind).canRemove(index) {
                        Button("Delete point") { removePoint(index) }
                    }
                }
        }
    }

    // MARK: Drawing

    private static func color(_ tint: CurveTint) -> Color {
        switch tint {
        case .white: Design.textPrimary
        case .red: Color(red: 1, green: 0.4, blue: 0.38)
        case .green: Color(red: 0.4, green: 0.85, blue: 0.45)
        case .blue: Color(red: 0.42, green: 0.6, blue: 1)
        }
    }

    private func draw(in context: inout GraphicsContext, layout: ToneGraphLayout) {
        let plot = layout.plot
        let grid = Color.white.opacity(0.08)
        for quarter in 1...3 {
            let at = CGFloat(quarter) / 4
            context.fill(Path(CGRect(x: plot.minX + at * plot.width, y: plot.minY, width: 0.5, height: plot.height)), with: .color(grid))
            context.fill(Path(CGRect(x: plot.minX, y: plot.minY + at * plot.height, width: plot.width, height: 0.5)), with: .color(grid))
        }
        context.stroke(Path(plot), with: .color(grid), lineWidth: 1)
        var diagonal = Path()
        diagonal.move(to: layout.point(0, 0))
        diagonal.addLine(to: layout.point(1, 1))
        context.stroke(diagonal, with: .color(Color.white.opacity(0.14)), lineWidth: 1)

        var plotted = context
        plotted.clip(to: Path(plot))
        func line(_ tones: [Double]) -> Path {
            Path { path in
                for (i, tone) in tones.enumerated() {
                    let point = layout.point(Double(i) / Double(max(tones.count - 1, 1)), tone)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
        }

        if let response, graph?.showsResponse == true {
            let channels = [response.map(\.x), response.map(\.y), response.map(\.z)]
            let gray = zip(channels[0], channels[1]).allSatisfy { abs($0 - $1) < 0.002 }
                && zip(channels[1], channels[2]).allSatisfy { abs($0 - $1) < 0.002 }
            if gray {
                plotted.stroke(line(channels[1]), with: .color(Design.textPrimary), lineWidth: 2)
            } else {
                for (tones, tint) in zip(channels, [CurveTint.red, .green, .blue]) {
                    plotted.stroke(line(tones), with: .color(Self.color(tint)), lineWidth: 1.5)
                }
            }
        }

        let steps = max(Int(plot.width / 2), 64)
        let xs = (0...steps).map { Double($0) / Double(steps) }
        for kind in curves where kind != editedCurve {
            let isOn = effect.control(kind)?.enabled ?? false
            plotted.stroke(line(curve(kind).sample(xs)), with: .color(Self.color(kind.curveTint).opacity(isOn ? 0.45 : 0.2)), lineWidth: 1)
        }
        if let kind = editedCurve {
            let isOn = effect.control(kind)?.enabled ?? false
            plotted.stroke(line(curve(kind).sample(xs)), with: .color(Self.color(kind.curveTint).opacity(isOn ? 1 : 0.5)), lineWidth: 2)
        }

        let tint = editedCurve.map { Self.color($0.curveTint) } ?? Design.accent
        for (index, center) in nodePlaces(layout).enumerated() {
            // A curve's edges are moved by the slider, so they are only
            // marked, not drawn as points to drag.
            if isCurveEdge(index) {
                context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(tint))
                continue
            }
            let dot = Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            context.fill(dot, with: .color(tint))
            context.stroke(dot, with: .color(Color.black.opacity(0.6)), lineWidth: 1)
            if index == picked || index == drag?.index {
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 7.5, y: center.y - 7.5, width: 15, height: 15)),
                               with: .color(isFocused ? Design.accent : Design.textSecondary), lineWidth: 1.5)
            }
        }
    }
}
