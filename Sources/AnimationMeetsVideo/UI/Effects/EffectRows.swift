import CoreMedia
import SwiftUI

/// Sizes the effects panel lays its rows out to.
enum EffectsPanelMetrics {
    static let rowHeight: CGFloat = 24
    /// The labels, values and buttons of a row, before its lane.
    static let labelWidth: CGFloat = 316
    static let controlIndent: CGFloat = 26
    /// Space either side of a lane's keyframes, so one at the clip's start
    /// or end isn't cut off by its neighbors.
    static let laneInset: CGFloat = 8
}

/// The button beside a row's ⋯ that puts it back to its default, shown
/// only while it isn't there, which is how a changed value is told apart.
struct RowResetButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(Design.Typeface.glyphSmall)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reset \(name.lowercased()) to its default")
        .accessibilityLabel("Reset \(name)")
    }
}

/// The ⋯ button that opens a row's menu.
private struct RowMenu<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// One numeric control of the panel's stack (or the anchor point): the
/// stopwatch that turns keyframing on and off, its name, its values at the
/// playhead (click to type, drag to change), the buttons that step between
/// keyframes and add or remove one, the graph button and a ⋯ menu.
struct ParameterRow<MenuContent: View>: View {
    let name: String
    var indent: CGFloat = 0
    let components: [Double]
    let unit: String
    /// What one point of dragging a value moves it.
    var dragStep: Double = 1
    var dragRange: (Int) -> ClosedRange<Double>? = { _ in nil }
    /// For components that measure different things (an EQ band's
    /// frequency, gain and Q): each one's unit and drag step.
    var componentUnit: ((Int) -> String)?
    var componentDragStep: ((Int) -> Double)?
    let isAnimated: Bool
    let isSelected: Bool
    /// Where the row's keyframes are, in the timeline's time.
    let keyframeTimes: [CMTime]
    /// The playhead, snapped to a frame.
    let playhead: CMTime
    /// For a scale or a size: whether its two axes are linked.
    var linked: Bool?
    var onToggleLink: () -> Void = {}
    var dragHandle: AnyView?
    /// Draws the row faded: it is off, or its effect is off or can't be
    /// applied.
    var isDimmed = false
    /// Puts it back to its default; nil while it is there.
    var onReset: (() -> Void)?
    let onSelect: () -> Void
    let onSetComponent: (Int, Double) -> Void
    let onToggleAnimated: () -> Void
    let onToggleKeyframe: () -> Void
    let onSeek: (CMTime) -> Void
    var onShowGraph: (() -> Void)?
    /// For a color: picked with a color well instead of typed as numbers.
    var color: Binding<CGColor>?
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 4) {
            if let dragHandle {
                dragHandle
            } else {
                Color.clear.frame(width: 12)
            }
            Button(action: onToggleAnimated) {
                Image(systemName: isAnimated ? "stopwatch.fill" : "stopwatch")
                    .foregroundStyle(isAnimated ? Design.accent : Design.textTertiary)
            }
            .buttonStyle(.plain)
            .help(isAnimated ? "Stop animating \(name.lowercased()) (keeps the current value)" : "Animate \(name.lowercased())")

            Text(name)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)

            if let linked {
                Button(action: onToggleLink) {
                    Image(systemName: "link")
                        .foregroundStyle(linked ? Design.textPrimary : Design.textTertiary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(linked ? "Width and height change together" : "Width and height change separately")
            }

            if let color {
                HeldColorWell(name: name, selection: color)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(name)
                    .help("Pick the \(name.lowercased()) color and its opacity")
            } else {
                ForEach(components.indices, id: \.self) { index in
                    if index > 0 { Text(",").foregroundStyle(Design.textTertiary) }
                    NumericField(
                        value: components[index], unit: componentUnit?(index) ?? unit,
                        fractionDigits: componentDragStep.map { $0(index) < 0.1 ? 2 : 1 } ?? 1,
                        dragStep: componentDragStep?(index) ?? dragStep, dragRange: dragRange(index)
                    ) { onSetComponent(index, $0) }
                }
            }

            Spacer(minLength: 2)

            if isAnimated { keyframeNavigation }
            if isAnimated, let onShowGraph {
                Button(action: onShowGraph) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(Design.textSecondary)
                }
                .buttonStyle(.plain)
                .font(Design.Typeface.glyphSmall)
                .help("Open \(name.lowercased())'s graph editor to shape its eases")
            }
            if let onReset { RowResetButton(name: name, action: onReset) }
            RowMenu(content: menu)
        }
        .font(Design.Typeface.label)
        .opacity(isDimmed ? 0.45 : 1)
        .padding(.leading, indent)
        .padding(.horizontal, 4)
        .frame(height: EffectsPanelMetrics.rowHeight)
        .onMouseDown { _ in onSelect() }
        .selectedRow(isSelected)
        .contextMenu { menu() }
    }

    private var keyframeNavigation: some View {
        let previous = keyframeTimes.last { $0 < playhead }
        let next = keyframeTimes.first { $0 > playhead }
        let hasKeyframe = keyframeTimes.contains(playhead)
        return HStack(spacing: 2) {
            Button {
                if let previous { onSeek(previous) }
            } label: {
                Image(systemName: "arrowtriangle.left.fill")
            }
            .disabled(previous == nil)
            .help("Previous keyframe")
            Button(action: onToggleKeyframe) {
                Image(systemName: hasKeyframe ? "diamond.fill" : "diamond")
                    .foregroundStyle(hasKeyframe ? Design.keyframe : Design.textTertiary)
            }
            .help(hasKeyframe ? "Remove the keyframe at the playhead" : "Add a keyframe at the playhead")
            Button {
                if let next { onSeek(next) }
            } label: {
                Image(systemName: "arrowtriangle.right.fill")
            }
            .disabled(next == nil)
            .help("Next keyframe")
        }
        .buttonStyle(.plain)
        .font(Design.Typeface.glyphTiny)
    }
}

/// A control that is a choice from a list, such as a blend mode.
struct ChoiceRow<MenuContent: View>: View {
    let name: String
    var indent: CGFloat = 0
    let options: [(id: String, name: String)]
    let selected: String
    let isSelected: Bool
    var dragHandle: AnyView?
    /// Whether the row has a ⋯ menu.
    var showsMenu = true
    var isDimmed = false
    /// Puts it back to its default; nil while it is there.
    var onReset: (() -> Void)?
    let onSelect: () -> Void
    let onChoose: @MainActor (String) -> Void
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 4) {
            if let dragHandle {
                dragHandle
            } else {
                Color.clear.frame(width: 12)
            }
            Color.clear.frame(width: 14)
            Text(name)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
                .frame(width: 74, alignment: .leading)
            Picker(name, selection: Binding(get: { selected }, set: { onChoose($0) })) {
                ForEach(options, id: \.id) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130)
            Spacer(minLength: 2)
            if let onReset { RowResetButton(name: name, action: onReset) }
            if showsMenu { RowMenu(content: menu) }
        }
        .font(Design.Typeface.label)
        .opacity(isDimmed ? 0.45 : 1)
        .padding(.leading, indent)
        .padding(.horizontal, 4)
        .frame(height: EffectsPanelMetrics.rowHeight)
        .onMouseDown { _ in onSelect() }
        .selectedRow(isSelected)
        .contextMenu { if showsMenu { menu() } }
    }
}

/// The row of an effect: a handle to drag it by, a disclosure arrow, an
/// enable checkbox, its name (double-click to rename) and a ⋯ menu.
struct EffectHeaderRow<MenuContent: View>: View {
    let effect: Effect
    let isCollapsed: Bool
    let isSelected: Bool
    let clipID: UUID
    /// The clip's picture after this effect, at the playhead.
    var thumbnail: CGImage?
    /// For an effect that draws nothing and writes keyframes: a curve in
    /// place of the thumbnail.
    var showsCurve = false
    /// What VoiceOver reads for the name, when there is more to say.
    var accessibilitySummary: String?
    var isDimmed = false
    /// Whether the effect has paste changes left to resolve, which marks
    /// its edge.
    var isFlagged = false
    let onToggleCollapsed: () -> Void
    let onSetEnabled: @MainActor (Bool) -> Void
    let onSelect: () -> Void
    let onRename: (String?) -> Void
    /// Whether the name is being edited, which the ⋯ menu can start.
    @Binding var isRenaming: Bool
    @ViewBuilder let menu: () -> MenuContent

    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(Design.Typeface.glyphSmall)
                .foregroundStyle(Design.textTertiary)
                .frame(width: 12)
                .contentShape(Rectangle())
                .onDrag {
                    EffectMovePayload(clipID: clipID, effectID: effect.id).itemProvider()
                } preview: {
                    Label(effect.displayName, systemImage: effect.kind.systemImage)
                        .padding(4)
                }
                .help("Drag to move the effect in the stack; Option-drag to copy it")
            Button(action: onToggleCollapsed) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Design.textSecondary)
            Toggle("", isOn: Binding(get: { effect.enabled }, set: { onSetEnabled($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .help(effect.enabled ? "Turn the effect off" : "Turn the effect on")
            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                    .onAppear {
                        draft = effect.displayName
                        nameFocused = true
                    }
            } else {
                Text(effect.displayName)
                    .font(Design.Typeface.bodyEmphasis)
                    .foregroundStyle(effect.enabled ? Design.textPrimary : Design.textTertiary)
                    .lineLimit(1)
                    .onMouseDown { clicks in if clicks == 2 { isRenaming = true } }
                    .accessibilityLabel(accessibilitySummary ?? effect.displayName)
            }
            Spacer(minLength: 2)
            if showsCurve {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(Design.Typeface.glyphSmall)
                    .foregroundStyle(Design.generatedKeyframe)
                    .frame(width: 32, height: 18)
                    .help("Writes keyframes onto another control, and draws nothing itself")
                    .accessibilityHidden(true)
            } else if let thumbnail {
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Design.bevelEdge, lineWidth: 0.5) }
                    .help("The clip after \(effect.displayName), at the playhead")
            }
            RowMenu(content: menu)
        }
        .font(Design.Typeface.label)
        .opacity(isDimmed ? 0.5 : 1)
        .padding(.horizontal, 4)
        .frame(height: EffectsPanelMetrics.rowHeight)
        // Anywhere on the row selects the effect, on the press.
        .onMouseDown { _ in onSelect() }
        .background(Design.Surface.raised.color.opacity(0.6))
        .overlay(alignment: .leading) {
            if isFlagged { Rectangle().fill(Design.statusWarning).frame(width: 3) }
        }
        .selectedRow(isSelected)
        .contextMenu { menu() }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let name = draft.trimmingCharacters(in: .whitespaces)
        onRename(name.isEmpty || name == effect.kind.name ? nil : name)
    }
}

/// A row pinned in the stack that isn't an effect: Pass Through, the
/// transitions, and the like.
struct PinnedRow<Trailing: View>: View {
    let title: String
    var systemImage: String?
    var isSelected = false
    var onSelect: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Design.textSecondary)
                    .frame(width: 14)
            }
            Text(title)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            trailing()
        }
        .font(Design.Typeface.label)
        .padding(.horizontal, 8)
        .frame(height: EffectsPanelMetrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .selectedRow(isSelected)
    }
}

/// A line under an effect saying why it does nothing, or how it works.
struct EffectNoteRow: View {
    let note: EffectNote

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: note.dims ? "exclamationmark.triangle" : "info.circle")
                .font(Design.Typeface.glyphSmall)
            Text(note.text)
                .font(Design.Typeface.micro)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(note.dims ? Design.statusWarning : Design.textTertiary)
        .padding(.leading, EffectsPanelMetrics.controlIndent)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }
}

/// Under a Keyframing effect whose keyframes were edited by hand when what
/// it reads changed: making them again would lose the edits, so the person
/// chooses.
struct KeyframingEditsRow: View {
    let onRegenerate: () -> Void
    let onKeepEdits: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(Design.Typeface.glyphSmall)
                Text("What it reads has changed, and its keyframes were edited by hand since.")
                    .font(Design.Typeface.micro)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Design.statusWarning)
            HStack(spacing: 6) {
                Button("Regenerate", action: onRegenerate)
                    .help("Make its keyframes again, losing the edits")
                Button("Keep Edits", action: onKeepEdits)
                    .help("Keep the keyframes as they are, until what it reads changes again")
            }
            .controlSize(.small)
        }
        .padding(.leading, EffectsPanelMetrics.controlIndent)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
    }
}

/// A color well whose changes, as the color panel's sliders and wheel are
/// dragged, are held to one side of the project (`ProjectState.hold`) and
/// written to it when they have paused for a moment: one undo step, and
/// the well shows the color picked meanwhile.
private struct HeldColorWell: View {
    let name: String
    let selection: Binding<CGColor>

    @Environment(\.projectHistory) private var history
    @Environment(ProjectState.self) private var projectState: ProjectState?
    @State private var picked: CGColor?
    @State private var isHolding = false
    @State private var settle: Task<Void, Never>?

    /// How long the color must hold still for the project to take it.
    private static let pause = Duration.milliseconds(400)

    var body: some View {
        ColorPicker(
            name,
            selection: Binding(get: { picked ?? selection.wrappedValue }, set: { change(to: $0) }),
            supportsOpacity: true
        )
    }

    private func change(to color: CGColor) {
        guard let projectState else {
            selection.wrappedValue = color
            return
        }
        if !isHolding {
            isHolding = true
            history?.beginGesture()
            projectState.beginHold()
        }
        picked = color
        projectState.hold { selection.wrappedValue = color }
        settle?.cancel()
        settle = Task { @MainActor in
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled, let last = picked else { return }
            projectState.endHold()
            selection.wrappedValue = last
            isHolding = false
            history?.endGesture()
            // Until the project's color has reached the well.
            try? await Task.sleep(for: .milliseconds(100))
            if !isHolding { picked = nil }
        }
    }
}
