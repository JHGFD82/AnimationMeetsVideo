import SwiftUI

/// What the Effects Library at the right end of the timeline lists.
enum EffectsLibraryTab: String, CaseIterable, Identifiable {
    case effects, transitions

    var id: Self { self }

    var title: String {
        switch self {
        case .effects: "Effects"
        case .transitions: "Transitions"
        }
    }
}

/// The things that can be dragged onto clips, in tabs: effects and
/// transitions. One button on the timeline's header shows or hides it.
/// Opening it changes nothing else; the inspector or effects list beside
/// the viewer only switches when an effect is applied.
struct EffectsLibrary: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    let selection: TimelineSelection?
    let state: EffectsPanelState
    @Binding var tab: EffectsLibraryTab
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar(tabs: EffectsLibraryTab.allCases, selection: $tab, title: \.title, onClose: onClose, closeHelp: "Hide the Effects Library")
            switch tab {
            case .effects:
                EffectsListPanel(project: $project, timelineID: timelineID, selection: selection, state: state)
            case .transitions:
                TransitionsPanel()
            }
        }
        .panelSurface(.base)
    }
}
