import SwiftUI

/// What the browser panel at the right end of the timeline lists.
enum BrowserTab: String, CaseIterable, Identifiable {
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
struct BrowserPanel: View {
    @Binding var project: EditingProject
    let timelineID: UUID
    let selection: TimelineSelection?
    let state: EffectsPanelState
    @Binding var tab: BrowserTab
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar(tabs: BrowserTab.allCases, selection: $tab, title: \.title, onClose: onClose, closeHelp: "Hide the browser")
            switch tab {
            case .effects:
                EffectsLibraryPanel(project: $project, timelineID: timelineID, selection: selection, state: state)
            case .transitions:
                TransitionsPanel()
            }
        }
        .panelSurface(.base)
    }
}

/// A row of tabs along the top of a panel, with a button that hides it.
struct PanelTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: KeyPath<Tab, String>
    let onClose: () -> Void
    let closeHelp: String

    var body: some View {
        HStack(spacing: Design.Space.close) {
            Picker("", selection: $selection) {
                ForEach(tabs) { tab in
                    Text(tab[keyPath: title]).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(closeHelp)
        }
        .padding(.horizontal, Design.Space.group)
        .padding(.vertical, Design.Space.close)
        .rail(.raised)
    }
}
