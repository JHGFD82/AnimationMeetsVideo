import CoreMedia
import SwiftUI

/// The effects that can be added, grouped by category: a tab of the
/// Effects Library at the right end of the timeline. Effects are dragged onto a clip or into the stack in the effects
/// panel, or double-clicked to add them to the selected clip. A shape
/// dragged onto the timeline's video area, or double-clicked with no
/// shape clip selected, starts a shape layer of its own.
struct EffectsListPanel: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    let selection: TimelineSelection?
    /// Where a shape layer started by a double-click begins, read then.
    let playhead: PlayheadState
    /// Selects a shape layer's clip once it is made.
    let onSelect: (TimelineSelection) -> Void
    let state: EffectsPanelState
    /// Which packages' kernels don't compile, as found after launch.
    var packageStatus = EffectPackageStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.close) {
                    ForEach(EffectCategory.allCases) { category in
                        Text(category.name)
                            .font(Design.Typeface.groupTitle)
                            .foregroundStyle(Design.textSecondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(EffectKind.all.filter { $0.category == category }) { kind in
                                // The double-click goes inside the drag: on
                                // the outside its tap gesture takes the mouse
                                // down first, and the chip never starts a drag.
                                EffectLibraryChip(kind: kind, problem: packageStatus.kernelProblems[kind.rawValue])
                                    .onTapGesture(count: 2) { addToSelectedClip(kind) }
                                    .draggable(EffectDragPayload(kind: kind)) { EffectLibraryChip(kind: kind) }
                                    .accessibilityAction(named: "Add to the selected clip") { addToSelectedClip(kind) }
                            }
                        }
                    }
                    problems
                }
                .padding(Design.Space.group)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sunken(.sunken)

            Text("Drag an effect onto a clip or into the stack, or double-click it to add it to the selected clip. A shape dragged onto empty timeline, or double-clicked with no shape clip selected, makes a shape layer.")
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

    /// The packages that couldn't be read or installed, then those whose
    /// look can't draw, each with why.
    @ViewBuilder
    private var problems: some View {
        let unread = EffectRegistry.current.problems
        let broken = EffectKind.all.compactMap { kind in
            kind.definition.package.flatMap { package in packageStatus.kernelProblems[kind.rawValue].map { (package, $0) } }
        }
        if !unread.isEmpty || !broken.isEmpty {
            Text("Can't Be Used")
                .font(Design.Typeface.groupTitle)
                .foregroundStyle(Design.textSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(unread) { problem in
                PackageProblemRow(name: problem.url.deletingPathExtension().lastPathComponent, message: problem.message, url: problem.url)
            }
            ForEach(broken, id: \.0.id) { package, message in
                PackageProblemRow(name: package.name, message: "Its kernel doesn't compile. \(message)", url: package.url)
            }
        }
    }

    /// Adds to the selected clip, or for a shape with no shape clip
    /// selected, makes a shape layer at the playhead (on footage a shape
    /// goes by a drag).
    private func addToSelectedClip(_ kind: EffectKind) {
        let selected = selection?.timelineID == timelineID ? selection?.timelineClipID : nil
        switch project.addFromLibrary(kind, in: timelineID, selectedClip: selected, playhead: playhead.time) {
        case .effect(let id):
            state.select(effect: id)
        case .shapeLayer(let layerID, let clipID):
            onSelect(TimelineSelection(timelineID: timelineID, layerID: layerID, timelineClipID: clipID))
        case nil:
            break
        }
    }
}

/// An effect in the library.
struct EffectLibraryChip: View {
    let kind: EffectKind
    /// Why its package's kernel doesn't compile, for one that can be added
    /// but leaves the picture as it is.
    var problem: String?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: problem == nil ? kind.systemImage : "exclamationmark.triangle")
                .foregroundStyle(problem != nil ? Design.statusWarning : isHovering ? Design.textPrimary : Design.textSecondary)
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
        .help(problem.map { "\(kind.name) can't draw: its kernel doesn't compile. \($0)" } ?? (kind.drawsShape
            ? "\(kind.name): drag onto a clip or onto empty timeline, or double-click to make a shape layer (or add it to the selected shape clip)"
            : "\(kind.name): drag onto a clip or into the stack, or double-click to add it to the selected clip"))
        .accessibilityValue(problem == nil ? "" : "Can't draw: its kernel doesn't compile")
    }
}
