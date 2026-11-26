import AppKit
import CoreGraphics
import CoreMedia
import SwiftUI

/// A Fill or Stroke's gradient in the inspector (see docs/gradients.md),
/// as Illustrator's Gradient panel: a preview of it, a bar of stops under
/// it, each a color at a location, with a midpoint between each pair, and
/// the picked stop's color, opacity and location as fields.
///
/// - Click the bar to add a stop of the color the gradient has there, at
///   every keyframe; drag a stop to move it (Option-drag copies it), drag
///   it off the bar or press Delete to take it out. Drag a midpoint to
///   lean the blend toward one side.
/// - The keys: Tab and Shift-Tab pick the next or previous stop, ← and →
///   move the picked one a percent (ten with Shift), Delete takes it out.
/// - VoiceOver reads the bar as one element whose stops are its children,
///   each adjustable for its location, with actions to add a stop after
///   it, take it out and pick the next or previous.
///
/// A drag shows as it goes and is set when it ends, as one change. While
/// the color is keyframed it reads as it is at the playhead and is changed
/// in the effects panel, as every keyframed control in the inspector is;
/// adding and taking out stops still works, at every keyframe.
struct GradientEditor: View {
    let control: EffectControl
    /// The playhead in the clip's source time.
    let time: CMTime
    let isReadOnly: Bool
    let onEdit: ((inout EffectControl) -> Void) -> Void

    @State private var picked = 0
    /// A stop or midpoint being dragged: its index and where it is now.
    @State private var dragged: (index: Int, location: Double, isMidpoint: Bool, copies: Bool, leaving: Bool)?
    @FocusState private var isFocused: Bool

    private static let barHeight: CGFloat = 18
    private static let stopSize: CGFloat = 11
    /// How far below the bar a stop is dragged to take it out.
    private static let tearOff: CGFloat = 26

    private var style: PaintStyle { control.paint ?? PaintStyle() }
    private var name: String { control.kind.name }

    var body: some View {
        if let gradient = control.gradient(at: time) {
            let shown = draggedGradient(gradient)
            VStack(alignment: .leading, spacing: 6) {
                bar(shown)
                pickedStopRow(shown)
                settingsRow
            }
            .onChange(of: gradient.stops.count) { _, count in picked = min(picked, max(count - 1, 0)) }
        }
    }

    // MARK: The bar

    /// The gradient as it would be with the drag under way.
    private func draggedGradient(_ gradient: PaintGradient) -> PaintGradient {
        guard let dragged, gradient.stops.indices.contains(dragged.index) else { return gradient }
        var shown = gradient
        if dragged.isMidpoint {
            shown.stops[dragged.index].midpoint = dragged.location
        } else if dragged.copies {
            var copy = shown.stops[dragged.index]
            copy.location = dragged.location
            shown.stops.insert(copy, at: dragged.index + 1)
        } else if !dragged.leaving {
            shown.stops[dragged.index].location = dragged.location
        } else if shown.stops.count > 2 {
            shown.stops.remove(at: dragged.index)
        }
        return shown
    }

    private func bar(_ gradient: PaintGradient) -> some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - Self.stopSize, 1)
            let inset = Self.stopSize / 2
            ZStack(alignment: .topLeading) {
                preview(gradient)
                    .frame(width: width, height: Self.barHeight)
                    .offset(x: inset)
                    .contentShape(Rectangle())
                    .onTapGesture { point in addStop(at: Double(point.x / width)) }
                ForEach(Array(midpoints(of: gradient).enumerated()), id: \.offset) { _, mid in
                    midpointMark
                        .position(x: inset + CGFloat(mid.at) * width, y: Self.barHeight + Self.stopSize / 2 + 1)
                        .gesture(midpointDrag(mid.index, between: mid.span, width: width))
                }
                ForEach(gradient.stops.indices, id: \.self) { index in
                    stopMark(gradient.stops[index], isPicked: index == picked)
                        .position(x: inset + CGFloat(gradient.stops[index].location) * width, y: Self.barHeight + Self.stopSize / 2 + 1)
                        .gesture(stopDrag(index, of: gradient, width: width))
                        .onTapGesture { picked = index }
                }
            }
        }
        .frame(height: Self.barHeight + Self.stopSize + 2)
        .disabled(!control.enabled)
        .focusable()
        .focused($isFocused)
        .onKeyPress(keys: [.tab, .leftArrow, .rightArrow, .delete, .deleteForward]) { press in
            handle(press, gradient)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) gradient stops")
        .accessibilityValue("\(gradient.stops.count) stops, \(style.kind.name)")
        .accessibilityChildren {
            ForEach(gradient.stops.indices, id: \.self) { index in
                stopAccessibility(index, of: gradient)
            }
        }
    }

    private func preview(_ gradient: PaintGradient) -> some View {
        Canvas { context, size in
            // A checkerboard under it, so opacity shows.
            let cell: CGFloat = 5
            for row in 0..<Int((size.height / cell).rounded(.up)) {
                for column in 0..<Int((size.width / cell).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(.gray.opacity(0.35)))
                }
            }
            let colors = gradient.samples(64, blend: style.blend).map { Self.color($0) }
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.control).strokeBorder(Design.textTertiary.opacity(0.5)))
        .help("Click to add a stop of the color the gradient has there")
        .accessibilityHidden(true)
    }

    private func stopMark(_ stop: PaintGradient.Stop, isPicked: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Self.color(stop.color))
            .frame(width: Self.stopSize, height: Self.stopSize)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(isPicked ? Design.accent : Design.textPrimary, lineWidth: isPicked ? 2 : 1))
            .contentShape(Rectangle().inset(by: -3))
            .help("Drag to move this stop, Option-drag to copy it, drag it off the bar to take it out")
    }

    private var midpointMark: some View {
        Rectangle()
            .fill(Design.textSecondary)
            .frame(width: 6, height: 6)
            .rotationEffect(.degrees(45))
            .contentShape(Rectangle().inset(by: -4))
            .help("Drag to move where the two colors are half and half")
    }

    /// Each pair of stops next to each other along the bar: the first's
    /// index, which holds the midpoint, the span between them, and where
    /// the midpoint is drawn.
    private func midpoints(of gradient: PaintGradient) -> [(index: Int, span: ClosedRange<Double>, at: Double)] {
        let order = gradient.stops.indices.sorted { (gradient.stops[$0].location, $0) < (gradient.stops[$1].location, $1) }
        return zip(order, order.dropFirst()).compactMap { a, b in
            let from = gradient.stops[a].location, to = gradient.stops[b].location
            guard to - from > 0.02 else { return nil }
            return (a, from...to, from + (to - from) * gradient.stops[a].midpoint)
        }
    }

    // MARK: Dragging

    private func stopDrag(_ index: Int, of gradient: PaintGradient, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                guard !isReadOnly else { return }
                picked = index
                let location = (gradient.stops[index].location + Double(drag.translation.width / width)).clamped(between: 0, and: 1)
                let copies = NSEvent.modifierFlags.contains(.option)
                let leaving = drag.translation.height > Self.tearOff && gradient.stops.count > 2 && !copies
                dragged = (index, location, false, copies, leaving)
            }
            .onEnded { _ in
                guard let ended = dragged else { return }
                dragged = nil
                if ended.leaving {
                    removeStop(ended.index)
                } else if ended.copies {
                    copyStop(ended.index, to: ended.location)
                } else {
                    let location = ended.location
                    edit { $0.stops[ended.index].location = location }
                }
            }
    }

    private func midpointDrag(_ index: Int, between span: ClosedRange<Double>, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                guard !isReadOnly, span.upperBound > span.lowerBound else { return }
                let x = Double(drag.location.x / width)
                let share = ((x - span.lowerBound) / (span.upperBound - span.lowerBound)).clamped(between: 0.01, and: 0.99)
                dragged = (index, share, true, false, false)
            }
            .onEnded { _ in
                guard let ended = dragged else { return }
                dragged = nil
                let midpoint = ended.location
                edit { $0.stops[ended.index].midpoint = midpoint }
            }
    }

    // MARK: Keys and VoiceOver

    private func handle(_ press: KeyPress, _ gradient: PaintGradient) -> KeyPress.Result {
        let count = gradient.stops.count
        guard count > 0 else { return .ignored }
        switch press.key {
        case .tab:
            picked = (picked + (press.modifiers.contains(.shift) ? count - 1 : 1)) % count
            announcePicked(gradient)
            return .handled
        case .leftArrow, .rightArrow:
            guard !isReadOnly, gradient.stops.indices.contains(picked) else { return .ignored }
            let step = (press.modifiers.contains(.shift) ? 0.1 : 0.01) * (press.key == .leftArrow ? -1 : 1)
            let index = picked
            edit { $0.stops[index].location = ($0.stops[index].location + step).clamped(between: 0, and: 1) }
            return .handled
        case .delete, .deleteForward:
            removeStop(picked)
            return .handled
        default:
            return .ignored
        }
    }

    private func stopAccessibility(_ index: Int, of gradient: PaintGradient) -> some View {
        let stop = gradient.stops[index]
        return Color.clear
            .accessibilityElement()
            .accessibilityLabel("Stop \(index + 1) of \(gradient.stops.count)")
            .accessibilityValue("\(Int((stop.location * 100).rounded())) percent, \(Self.describe(stop.color))")
            .accessibilityAddTraits(index == picked ? .isSelected : [])
            .accessibilityAdjustableAction { direction in
                guard !isReadOnly else { return }
                let step = direction == .increment ? 0.01 : -0.01
                edit { $0.stops[index].location = ($0.stops[index].location + step).clamped(between: 0, and: 1) }
            }
            .accessibilityAction(named: "Add a Stop After") {
                let next = gradient.sortedStops.first { $0.location > stop.location }?.location ?? 1
                addStop(at: (stop.location + next) / 2)
            }
            .accessibilityAction(named: "Remove") { removeStop(index) }
            .accessibilityAction(named: "Pick") { picked = index }
            .accessibilityAction(named: "Pick Next") { picked = (index + 1) % gradient.stops.count }
            .accessibilityAction(named: "Pick Previous") { picked = (index + gradient.stops.count - 1) % gradient.stops.count }
    }

    private func announcePicked(_ gradient: PaintGradient) {
        guard gradient.stops.indices.contains(picked) else { return }
        let stop = gradient.stops[picked]
        AccessibilityNotification.Announcement(
            "Stop \(picked + 1), \(Int((stop.location * 100).rounded())) percent, \(Self.describe(stop.color))"
        ).post()
    }

    // MARK: The picked stop

    @ViewBuilder
    private func pickedStopRow(_ gradient: PaintGradient) -> some View {
        if gradient.stops.indices.contains(picked) {
            let stop = gradient.stops[picked]
            let index = picked
            HStack(spacing: 6) {
                HeldColorWell(name: "\(name) stop color", selection: Binding(
                    get: {
                        let c = stop.color.map { CGFloat($0) }
                        return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
                    },
                    set: { picked in
                        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                              let srgb = picked.converted(to: space, intent: .defaultIntent, options: nil),
                              let parts = srgb.components, parts.count >= 4
                        else { return }
                        let color = parts.prefix(4).map { Double($0).clamped(between: 0, and: 1) }
                        edit { $0.stops[index].color = color }
                    }
                ))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Stop \(index + 1) color")
                .disabled(isReadOnly)
                Text("\(Int((stop.color[3] * 100).rounded()))%")
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textTertiary)
                    .help("Opacity, set in the color well")
                    .accessibilityLabel("Stop \(index + 1) opacity")
                NumericField(
                    value: stop.location * 100, unit: "%", fractionDigits: 1, dragStep: 1, dragRange: 0...100,
                    accessibilityName: "Stop \(index + 1) location"
                ) { value in
                    edit { $0.stops[index].location = (value / 100).clamped(between: 0, and: 1) }
                }
                .frame(width: 64)
                .disabled(isReadOnly)
                Spacer(minLength: 0)
                Button { onEdit { $0.editGradientEverywhere { $0.reversed } } } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.icon)
                .help("Reverse the stops")
                .accessibilityLabel("Reverse Stops")
                Button { onEdit { $0.editGradientEverywhere { $0.distributed } } } label: {
                    Image(systemName: "distribute.horizontal.center")
                }
                .buttonStyle(.icon)
                .help("Space the stops evenly")
                .accessibilityLabel("Distribute Stops")
                Button { removeStop(index) } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.icon)
                .disabled(gradient.stops.count <= 2)
                .help("Take out the picked stop")
                .accessibilityLabel("Remove Stop")
            }
            .disabled(!control.enabled)
        }
    }

    private var settingsRow: some View {
        HStack(spacing: 6) {
            PanelMenuField(
                glyph: nil, name: "\(name) repeat", options: GradientRepeat.allCases.map { ($0, $0.name) }, selection: style.repeats
            ) { value in onEdit { $0.paint?.repeats = value } }
            PanelMenuField(
                glyph: nil, name: "\(name) blend", options: GradientBlend.allCases.map { ($0, $0.name) }, selection: style.blend
            ) { value in onEdit { $0.paint?.blend = value } }
            PanelMenuField(
                glyph: nil, name: "\(name) lies", options: GradientSpace.allCases.map { ($0, $0.name) }, selection: style.space
            ) { value in onEdit { $0.paint?.space = value } }
        }
        .disabled(!control.enabled)
    }

    // MARK: Editing

    private func edit(_ change: @escaping (inout PaintGradient) -> Void) {
        guard !isReadOnly else { return }
        let at = time
        onEdit { $0.editGradient(at: at) { gradient in change(&gradient) } }
    }

    private func addStop(at location: Double) {
        let at = time
        var added: Int?
        onEdit { added = $0.addGradientStop(at: location, time: at) }
        if let added { picked = added }
    }

    private func copyStop(_ index: Int, to location: Double) {
        let at = time
        onEdit { control in
            guard let added = control.addGradientStop(at: location, time: at) else { return }
            // The copy takes the copied stop's color, at every keyframe.
            control.editGradientEverywhere { gradient in
                var copied = gradient
                let source = index < added ? index : index + 1
                if copied.stops.indices.contains(source), copied.stops.indices.contains(added) {
                    copied.stops[added].color = copied.stops[source].color
                }
                return copied
            }
        }
    }

    private func removeStop(_ index: Int) {
        onEdit { $0.removeGradientStop(index) }
        picked = max(0, min(picked, index - 1))
    }

    // MARK: Colors

    static func color(_ rgba: [Double]) -> Color {
        guard rgba.count == 4 else { return .clear }
        return Color(.sRGB, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
    }

    /// A color for VoiceOver: its red, green and blue as percents, and its
    /// opacity when it isn't opaque.
    static func describe(_ rgba: [Double]) -> String {
        guard rgba.count == 4 else { return "" }
        let percent = { (value: Double) in "\(Int((value * 100).rounded()))" }
        var text = "red \(percent(rgba[0])), green \(percent(rgba[1])), blue \(percent(rgba[2]))"
        if rgba[3] < 1 { text += ", \(percent(rgba[3])) percent opaque" }
        return text
    }
}

/// How a Fill or Stroke paints, as a menu beside its checkbox: one color,
/// or a linear, radial or angular gradient.
struct PaintKindMenu: View {
    let control: EffectControl
    let onEdit: ((inout EffectControl) -> Void) -> Void

    var body: some View {
        let selection = control.paint?.kind.rawValue ?? "solid"
        Menu {
            Picker("\(control.kind.name) paint", selection: Binding(
                get: { selection },
                set: { picked in onEdit { $0.setPaint(GradientKind(rawValue: picked)) } }
            )) {
                Label("Color", systemImage: "square.fill").tag("solid")
                ForEach(GradientKind.allCases) { kind in
                    Label("\(kind.name) Gradient", systemImage: kind.systemImage).tag(kind.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: control.paint?.kind.systemImage ?? "square.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Paint the \(control.kind.name.lowercased()) with one color or a gradient")
        .accessibilityLabel("\(control.kind.name) paint")
        .accessibilityValue(control.paint.map { "\($0.kind.name) gradient" } ?? "Color")
    }
}
