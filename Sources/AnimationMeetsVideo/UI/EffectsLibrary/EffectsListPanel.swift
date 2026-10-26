import AppKit
import SwiftUI

/// The effects that can be added, grouped by category: a tab of the
/// Effects Library at the right end of the timeline. Effects are dragged
/// onto a clip or into the stack in the effects panel, or double-clicked
/// to add them to the selected clip. Text and the shapes aren't here:
/// they make clips of their own, from the browser's Generators tab.
struct EffectsListPanel: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    let selection: TimelineSelection?
    let state: EffectsPanelState
    /// Which packages' kernels don't compile, as found after launch.
    var packageStatus = EffectPackageStatus.shared

    var body: some View {
        // Read so a package installed while the app runs is listed.
        let _ = packageStatus.revision
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.close) {
                    ForEach(EffectCategory.allCases) { category in
                        let kinds = Self.kinds.filter { $0.category == category }
                        if !kinds.isEmpty {
                            Text(category.name)
                                .font(Design.Typeface.groupTitle)
                                .foregroundStyle(Design.textSecondary)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                                ForEach(kinds) { kind in
                                    // The double-click goes inside the drag: on
                                    // the outside its tap gesture takes the mouse
                                    // down first, and the chip never starts a drag.
                                    EffectLibraryChip(kind: kind, problem: packageStatus.kernelProblems[kind.rawValue])
                                        .onTapGesture(count: 2) { addToSelectedClip(kind) }
                                        .draggable(EffectDragPayload(kind: kind)) { EffectLibraryChip(kind: kind) }
                                        .contextMenu {
                                            if let package = kind.definition.package {
                                                Button("Make a Package from This") { NewEffectPackagePrompt.shared.copy(package) }
                                            }
                                        }
                                        .accessibilityAction(named: "Add to the selected clip") { addToSelectedClip(kind) }
                                        .accessibilityAction(named: "Make a Package from This") {
                                            if let package = kind.definition.package { NewEffectPackagePrompt.shared.copy(package) }
                                        }
                                }
                            }
                        }
                    }
                    problems
                }
                .padding(Design.Space.group)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sunken(.sunken)
            .contextMenu {
                Button("New Effect Package…") { NewEffectPackagePrompt.shared.ask() }
                Button("Show Effects Folder") { NewEffectPackagePrompt.showEffectsFolder() }
            }
            .accessibilityAction(named: "New Effect Package") { NewEffectPackagePrompt.shared.ask() }
            .accessibilityAction(named: "Show Effects Folder") { NewEffectPackagePrompt.showEffectsFolder() }

            Text("Drag an effect onto a clip or into the stack, or double-click it to add it to the selected clip. Text and shapes are in the browser's Generators tab.")
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

    /// What the library lists: every effect but the generators (text and
    /// the shapes), which aren't effects but clips of their own.
    static var kinds: [EffectKind] { EffectKind.all.filter { !$0.drawsShape } }

    /// Adds to the selected clip; a beep when none is selected or it can't
    /// take the effect.
    private func addToSelectedClip(_ kind: EffectKind) {
        guard let selection, selection.timelineID == timelineID,
              let id = project.addEffect(kind, toClip: selection.timelineClipID, in: timelineID)
        else {
            NSSound.beep()
            return
        }
        state.select(effect: id)
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
        .help(problem.map { "\(kind.name) can't draw: its kernel doesn't compile. \($0)" }
            ?? "\(kind.name): drag onto a clip or into the stack, or double-click to add it to the selected clip")
        .accessibilityValue(problem == nil ? "" : "Can't draw: its kernel doesn't compile")
    }
}
