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

    var body: some View {
        @Bindable var presets = presets
        VStack(spacing: 0) {
            PanelTabBar(tabs: EffectsLibraryTab.allCases, selection: $tab, title: \.title, onClose: onClose, closeHelp: "Hide the Effects Library")
            switch tab {
            case .effects:
                EffectsListPanel(project: $project, timelineID: timelineID, selection: selection, state: state)
            case .transitions:
                TransitionsPanel()
            case .presets:
                PresetsList(model: presets, onApply: applyToSelectedClip)
            }
        }
        .panelSurface(.base)
        .alert("Rename Preset", isPresented: $presets.renaming.isPresent) {
            TextField("Name", text: $presets.draftName)
            Button("Rename") { presets.commitRename() }
            Button("Cancel", role: .cancel) {}
        }
        .messageAlert("Preset Problem", message: $presets.errorMessage)
        .onReceive(NotificationCenter.default.publisher(for: .presetsChanged)) { _ in presets.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in presets.reload() }
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
