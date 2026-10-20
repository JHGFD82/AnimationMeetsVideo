import AppKit
import Observation
import SwiftUI

/// The presets in the presets folder, for the browser's Presets tab.
/// They are shared by every project, so they are read from the folder
/// again when the app comes forward or one is saved, not kept per project.
@MainActor @Observable
final class PresetsModel {
    var library = PresetLibrary()
    /// The preset being renamed, with the name being typed.
    var renaming: EffectPreset?
    var draftName = ""
    var errorMessage: String?

    let folder: URL

    init(folder: URL = PresetStore.defaultFolder) {
        self.folder = folder
        // The starting recipes go into the person's own folder, once.
        if folder == PresetStore.defaultFolder { PresetStore.installRecipes(in: folder) }
        reload()
    }

    func reload() {
        library = PresetStore.load(from: folder)
    }

    func beginRenaming(_ preset: EffectPreset) {
        draftName = preset.name
        renaming = preset
    }

    func commitRename() {
        guard let preset = renaming else { return }
        renaming = nil
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != preset.name else { return }
        do {
            try PresetStore.rename(preset, to: name, in: folder)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    /// Moves the preset's file to the Trash, so a deletion can be undone
    /// from there.
    func delete(_ preset: EffectPreset) {
        do {
            try FileManager.default.trashItem(at: preset.url, resultingItemURL: nil)
        } catch {
            do { try PresetStore.delete(preset) } catch { errorMessage = error.localizedDescription }
        }
        reload()
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// The browser's Presets tab: each preset can be dragged onto a clip or
/// into a stack, double-clicked to apply it to the selected clip, renamed,
/// deleted or shown in the Finder. A file that can't be read is listed with
/// why, and is never used.
///
/// The rows sit in a scroll view rather than a `List`, as the Clips tab's
/// and the Effects Library's do: a list's table takes the mouse-down for
/// its own row tracking, and a row's drag never started.
struct PresetsList: View {
    let model: PresetsModel
    /// Puts the preset on the selected clip, below its stack.
    let onApply: (EffectPreset) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.library.presets) { preset in
                    // The double-click goes inside the drag: on the outside
                    // its tap gesture takes the mouse down first, and the row
                    // never starts a drag.
                    PresetRow(preset: preset)
                        .onTapGesture(count: 2) { onApply(preset) }
                        .draggable(PresetDragPayload(presetID: preset.id)) { PresetRow(preset: preset) }
                        .contextMenu {
                            Button("Apply to Selected Clip") { onApply(preset) }
                            Divider()
                            Button("Rename…") { model.beginRenaming(preset) }
                            Button("Show in Finder") { model.showInFinder(preset.url) }
                            Divider()
                            Button("Delete", role: .destructive) { model.delete(preset) }
                        }
                        .accessibilityAction(named: "Apply to the selected clip") { onApply(preset) }
                }
                ForEach(model.library.problems) { problem in
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(problem.url.deletingPathExtension().lastPathComponent)
                            Text(problem.message)
                                .font(Design.Typeface.micro)
                                .foregroundStyle(Design.statusWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Design.statusWarning)
                    }
                    .font(Design.Typeface.label)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .help("This preset can't be used. Fix or remove its file.")
                    .contextMenu {
                        Button("Show in Finder") { model.showInFinder(problem.url) }
                    }
                }
                if model.library.presets.isEmpty, model.library.problems.isEmpty {
                    Text("Save an effect from its ⋯ menu in the effects panel to make a preset.")
                        .font(Design.Typeface.micro)
                        .foregroundStyle(Design.textTertiary)
                        .padding(8)
                }
            }
            .padding(Design.Space.step)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sunken(.sunken)
    }

    /// "Color, Transform" or "3 effects".
    static func summary(of preset: EffectPreset) -> String {
        let kinds = preset.bundle.effects.map(\.effect.displayName)
        return kinds.count <= 2 ? kinds.joined(separator: ", ") : "\(kinds.count) effects"
    }
}

/// One preset in the list: its name, and what effects it holds.
private struct PresetRow: View {
    let preset: EffectPreset

    @State private var isHovering = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .foregroundStyle(Design.textPrimary)
                Text(PresetsList.summary(of: preset))
                    .font(Design.Typeface.numericMicro)
                    .foregroundStyle(Design.textTertiary)
            }
        } icon: {
            Image(systemName: Design.Symbol.preset)
                .foregroundStyle(Design.accent)
        }
        .font(Design.Typeface.label)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Design.Surface.overlay.color : .clear, in: RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("Drag onto a clip or into its stack in the effects panel, or double-click to apply it to the selected clip")
        .accessibilityElement(children: .combine)
    }
}
