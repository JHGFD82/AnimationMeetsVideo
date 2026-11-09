import AppKit
import SwiftUI

/// What the Effects Library at the right end of the timeline lists.
enum EffectsLibraryTab: String, CaseIterable, Identifiable {
    case effects, transitions, presets

    var id: Self { self }

    var title: String {
        switch self {
        case .effects: "Effects"
        case .transitions: "Transitions"
        case .presets: "Presets"
        }
    }
}

/// The things that can be dragged onto clips, in tabs: effects,
/// transitions and presets. One button on the timeline's header shows or
/// hides it. Opening it changes nothing else; the inspector or effects
/// list beside the viewer only switches when an effect is applied.
struct EffectsLibrary: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    let selection: TimelineSelection?
    let state: EffectsPanelState
    @Binding var tab: EffectsLibraryTab
    let onClose: () -> Void

    /// The presets, which every project and window shares.
    var presets = PresetsModel.shared

    /// The preset being renamed in this window, with the name being typed.
    @State private var renaming: EffectPreset?
    @State private var draftName = ""
    @State private var problem: String?
    /// A preset the Trash couldn't take, to delete for good once confirmed.
    @State private var permanentDeletion: EffectPreset?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar(tabs: EffectsLibraryTab.allCases, selection: $tab, title: \.title, onClose: onClose, closeHelp: "Hide the Effects Library")
            switch tab {
            case .effects:
                EffectsListPanel(project: $project, timelineID: timelineID, selection: selection, state: state)
            case .transitions:
                TransitionsPanel()
            case .presets:
                PresetsList(model: presets, onApply: applyToSelectedClip, onRename: beginRenaming, onDelete: delete)
            }
        }
        .panelSurface(.base)
        .alert("Rename Preset", isPresented: $renaming.isPresent) {
            TextField("Name", text: $draftName)
            Button("Rename", action: commitRename)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete “\(permanentDeletion?.name ?? "")” Permanently?", isPresented: $permanentDeletion.isPresent) {
            Button("Delete", role: .destructive) {
                guard let preset = permanentDeletion else { return }
                do { try presets.deletePermanently(preset) } catch { problem = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It can't be moved to the Trash, so deleting it can't be undone.")
        }
        .messageAlert("Preset Problem", message: $problem)
        .onReceive(NotificationCenter.default.publisher(for: .presetsChanged)) { _ in presets.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in presets.reload() }
    }

    private func beginRenaming(_ preset: EffectPreset) {
        draftName = preset.name
        renaming = preset
    }

    private func commitRename() {
        guard let preset = renaming else { return }
        renaming = nil
        do { try presets.rename(preset, to: draftName) } catch { problem = error.localizedDescription }
    }

    /// Moves the preset to the Trash, which Undo takes it back from; one
    /// the Trash can't take is deleted for good only once confirmed.
    private func delete(_ preset: EffectPreset) {
        do { try presets.trash(preset.url, undoManager: undoManager) } catch { permanentDeletion = preset }
    }

    /// Puts a preset's effects on the selected clip, below its stacks; a
    /// beep when no clip is selected or it has nowhere to put them.
    private func applyToSelectedClip(_ preset: EffectPreset) {
        guard let selection, !project.paste(preset.bundle, ontoClip: selection.timelineClipID, in: selection.timelineID).isEmpty else {
            NSSound.beep()
            return
        }
    }
}
