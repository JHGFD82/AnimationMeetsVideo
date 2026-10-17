import SwiftUI

/// The effects that can be added, grouped by category: a tab of the
/// Effects Library at the right end of the timeline. Effects are dragged onto a clip or into the stack in the effects
/// panel, or double-clicked to add them to the selected clip.
struct EffectsListPanel: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    let selection: TimelineSelection?
    let state: EffectsPanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.close) {
                    ForEach(EffectCategory.allCases) { category in
                        Text(category.name)
                            .font(Design.Typeface.groupTitle)
                            .foregroundStyle(Design.textSecondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(EffectKind.allCases.filter { $0.category == category }) { kind in
                                // The double-click goes inside the drag: on
                                // the outside its tap gesture takes the mouse
                                // down first, and the chip never starts a drag.
                                EffectLibraryChip(kind: kind)
                                    .onTapGesture(count: 2) { addToSelectedClip(kind) }
                                    .draggable(EffectDragPayload(kind: kind)) { EffectLibraryChip(kind: kind) }
                                    .accessibilityAction(named: "Add to the selected clip") { addToSelectedClip(kind) }
                            }
                        }
                    }
                }
                .padding(Design.Space.group)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sunken(.sunken)

            Text("Drag an effect onto a clip or into the stack, or double-click it to add it to the selected clip.")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textTertiary)
                .padding(.horizontal, Design.Space.group)
                .padding(.vertical, Design.Space.step)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Design.Surface.base.color)
                .overlay(alignment: .top) { Groove() }
        }
        .panelSurface(.base)
    }

    private func addToSelectedClip(_ kind: EffectKind) {
        guard let selection, selection.timelineID == timelineID,
              let id = project.addEffect(kind, toClip: selection.timelineClipID, in: timelineID)
        else { return }
        state.select(effect: id)
    }
}

/// An effect in the library.
struct EffectLibraryChip: View {
    let kind: EffectKind

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(isHovering ? Design.textPrimary : Design.textSecondary)
                .frame(width: 16)
            Text(kind.name)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .beveledChip(fill: isHovering ? Design.Surface.floating.color : Design.Surface.overlay.color)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("\(kind.name): drag onto a clip or into the stack, or double-click to add it to the selected clip")
    }
}
