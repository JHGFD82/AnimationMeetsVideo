import SwiftUI

/// The settings a transition's kind offers besides its length and curve,
/// in the inspector's transition row.
struct TransitionSettingsControls: View {
    let transition: ClipTransition
    let onChange: (TransitionOptions) -> Void

    var body: some View {
        let settings = transition.kind.settings
        if !settings.isEmpty {
            VStack(alignment: .leading, spacing: Design.Space.close) {
                ForEach(settings, id: \.self) { setting in
                    control(for: setting)
                }
            }
        }
    }

    @ViewBuilder
    private func control(for setting: TransitionSetting) -> some View {
        switch setting {
        case .direction:
            Picker("Direction", selection: binding(\.direction)) {
                ForEach(TransitionDirection.allCases) { direction in
                    Image(systemName: direction.systemImage)
                        .accessibilityLabel(direction.name)
                        .tag(direction)
                }
            }
            .pickerStyle(.segmented)
            .help("Which way it moves")
        default:
            EmptyView()
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<TransitionOptions, Value>) -> Binding<Value> {
        Binding(
            get: { transition.options[keyPath: keyPath] },
            set: { value in
                var options = transition.options
                options[keyPath: keyPath] = value
                onChange(options)
            }
        )
    }
}
