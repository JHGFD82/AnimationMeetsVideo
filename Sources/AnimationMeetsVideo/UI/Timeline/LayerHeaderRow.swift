import CoreMedia
import SwiftUI

struct LayerHeaderRow: View {
    let number: Int
    let layer: TimelineLayer
    /// The layer's custom name, or its default. See `displayName(of:in:)`.
    let displayName: String
    let height: CGFloat
    let canMoveUp: Bool
    let canMoveDown: Bool
    /// Nil for layers with no properties to show (no pictures and no
    /// sound), which get no arrow.
    let isExpanded: Bool?
    let onToggleExpanded: () -> Void
    /// Nil for layers with no video still carrying its sound.
    let isAudioExpanded: Bool?
    let onToggleAudio: () -> Void
    let onDetachAudio: () -> Void
    /// Whether the layer's sound shows each channel apart; nil for layers
    /// with no sound to show (or linked audio that is hidden).
    let isChannelsExpanded: Bool?
    let onToggleChannels: () -> Void
    let onRename: (String?) -> Void
    let onMove: (Int) -> Void
    /// Dragging the header up or down reorders the layers; these get the
    /// vertical distance dragged.
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    /// Selected by clicking the header; Delete then removes the layer.
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isEditingName = false
    @State private var draftName: String = ""
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let isExpanded {
                    Button(action: onToggleExpanded) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide volume (L)" : "Show volume (L)")
                    .accessibilityLabel("Volume of \(displayName)")
                    .accessibilityValue(isExpanded ? "Shown" : "Hidden")
                } else {
                    Color.clear
                }
            }
            .font(Design.Typeface.tag)
            .foregroundStyle(Design.textTertiary)
            .frame(width: 12)
            Text("\(number)")
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(Design.textTertiary)
                .frame(width: 18, alignment: .trailing)
            if layer.isAdjustment {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.ClipTone.adjustment.color)
                    .help("Adjustment layer")
            }
            if isEditingName {
                TextField(displayName, text: $draftName)
                    .font(Design.Typeface.label)
                    .textFieldStyle(.plain)
                    .focused($isNameFieldFocused)
                    // A click on the timeline doesn't take focus, so it
                    // ends the edit itself.
                    .background(OutsideClickMonitor(onOutsideClick: commitRename))
                    .onSubmit { commitRename() }
                    .onExitCommand { isEditingName = false }
                    .onAppear { isNameFieldFocused = true }
                    // onSubmit only fires on Return — clicking away to end
                    // editing without pressing Return previously left the
                    // field stuck open and never fell back to the footage
                    // name when left blank. Committing on focus-loss too
                    // fixes that.
                    .onChange(of: isNameFieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(displayName)
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        beginRename()
                    }
            }
            Spacer(minLength: 0)
            if let isAudioExpanded {
                Button(action: onToggleAudio) {
                    Image(systemName: "waveform")
                        .font(Design.Typeface.label)
                        .foregroundStyle(isAudioExpanded ? Design.accent : Design.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isAudioExpanded ? "Hide linked audio" : "Show linked audio")
                .accessibilityLabel("Linked audio of \(displayName)")
                .accessibilityValue(isAudioExpanded ? "Shown" : "Hidden")
            }
            if let isChannelsExpanded {
                Button(action: onToggleChannels) {
                    Image(systemName: "square.split.1x2")
                        .font(Design.Typeface.label)
                        .foregroundStyle(isChannelsExpanded ? Design.accent : Design.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isChannelsExpanded ? "Show the sound as one waveform" : "Show each channel (left and right) apart")
                .accessibilityLabel("Separate channels of \(displayName)")
                .accessibilityValue(isChannelsExpanded ? "On" : "Off")
            }
        }
        .padding(.horizontal, Design.Space.step)
        .frame(height: height, alignment: .leading)
        .selectedRow(isSelected)
        .editorAnimation(Design.Motion.select, value: isSelected)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { value in onDragChanged(value.translation.height) }
                .onEnded { value in onDragEnded(value.translation.height) }
        )
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .help("Click to select, then Delete to remove the layer. Drag to reorder layers.")
        .contextMenu {
            Button("Move Layer Up") { onMove(-1) }
                .disabled(!canMoveUp)
            Button("Move Layer Down") { onMove(1) }
                .disabled(!canMoveDown)
            if let isAudioExpanded {
                Divider()
                Button(isAudioExpanded ? "Hide Linked Audio" : "Show Linked Audio", action: onToggleAudio)
                Button("Detach Audio", action: onDetachAudio)
            }
            if let isChannelsExpanded {
                Divider()
                Button(isChannelsExpanded ? "Hide Channels" : "Show Channels", action: onToggleChannels)
            }
            Divider()
            Button("Delete Layer", role: .destructive, action: onDelete)
        }
        // A group, so its buttons stay reachable inside it, with the
        // layer's own actions on the group.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layer \(number), \(displayName)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { onSelect() }
        .accessibilityActions {
            if canMoveUp { Button("Move layer up") { onMove(-1) } }
            if canMoveDown { Button("Move layer down") { onMove(1) } }
            Button("Rename layer") {
                beginRename()
            }
            Button("Delete layer", action: onDelete)
        }
    }

    /// The field starts with the name shown, default or not, for its
    /// whole value to be selected and typed over.
    private func beginRename() {
        draftName = displayName
        isEditingName = true
    }

    /// The name as it was changes nothing, so a default name keeps
    /// following the footage; an empty one goes back to the default.
    private func commitRename() {
        guard isEditingName else { return }
        isEditingName = false
        guard draftName != displayName else { return }
        onRename(draftName.isEmpty ? nil : draftName)
    }
}

extension LayerHeaderRow: Equatable {
    /// Whether the header would draw the same, so it needn't be redrawn
    /// (the timeline marks it `.equatable()`). Its closures act on the
    /// layer by ID, so they aren't compared.
    nonisolated static func == (lhs: LayerHeaderRow, rhs: LayerHeaderRow) -> Bool {
        MainActor.assumeIsolated {
            lhs.number == rhs.number && lhs.layer == rhs.layer && lhs.displayName == rhs.displayName
                && lhs.height == rhs.height && lhs.canMoveUp == rhs.canMoveUp && lhs.canMoveDown == rhs.canMoveDown
                && lhs.isExpanded == rhs.isExpanded && lhs.isAudioExpanded == rhs.isAudioExpanded
                && lhs.isChannelsExpanded == rhs.isChannelsExpanded && lhs.isSelected == rhs.isSelected
        }
    }
}
