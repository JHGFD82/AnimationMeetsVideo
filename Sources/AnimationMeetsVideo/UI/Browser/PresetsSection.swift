import AppKit
import Observation
import SwiftUI

/// The presets in the presets folder, for the browser's Presets section.
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

/// The browser's Presets section: each preset can be dragged onto a clip or
/// into a stack, renamed, deleted or shown in the Finder. A file that can't
/// be read is listed with why, and is never used.
struct PresetsSection: View {
    let model: PresetsModel

    var body: some View {
        Section("Presets") {
            ForEach(model.library.presets) { preset in
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.name)
                        Text(Self.summary(of: preset))
                            .font(Design.Typeface.numericMicro)
                            .foregroundStyle(Design.textTertiary)
                    }
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Design.accent)
                }
                .draggable(PresetDragPayload(presetID: preset.id))
                .help("Drag onto a clip or into its stack in the effects panel")
                .contextMenu {
                    Button("Rename…") { model.beginRenaming(preset) }
                    Button("Show in Finder") { model.showInFinder(preset.url) }
                    Divider()
                    Button("Delete", role: .destructive) { model.delete(preset) }
                }
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
                .help("This preset can't be used. Fix or remove its file.")
                .contextMenu {
                    Button("Show in Finder") { model.showInFinder(problem.url) }
                }
            }
            if model.library.presets.isEmpty, model.library.problems.isEmpty {
                Text("Save an effect from its ⋯ menu in the effects panel to make a preset.")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textTertiary)
            }
        }
    }

    /// "Color, Transform" or "3 effects".
    static func summary(of preset: EffectPreset) -> String {
        let kinds = preset.bundle.effects.map(\.effect.displayName)
        return kinds.count <= 2 ? kinds.joined(separator: ", ") : "\(kinds.count) effects"
    }
}
