import SwiftUI

/// The settings a transition's kind offers besides its length and curve,
/// in the inspector's transition row.
struct TransitionSettingsControls: View {
    let transition: ClipTransition
    /// The project's videos, which a matte wipe can take its map from.
    let videos: [MediaClip]
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
        let kind = transition.kind
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
        case .color:
            ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                .font(Design.Typeface.label)
                .help("The color it passes through")
        case .center:
            fractionSlider("Center across", value: centerBinding(\.x))
            fractionSlider("Center down", value: centerBinding(\.y))
        case .shape:
            Picker("Shape", selection: binding(\.shape)) {
                ForEach(IrisShape.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
        case .count:
            Stepper(value: binding(\.count), in: TransitionOptions.countRange) {
                Text("\(kind.countName): \(transition.options.count)")
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textSecondary)
            }
        case .order:
            Picker("Order", selection: binding(\.order)) {
                ForEach(GridOrder.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
        case .amount:
            fractionSlider(kind.amountName, value: binding(\.amount))
        case .matte:
            Picker("Map", selection: binding(\.matte)) {
                Text("Noise").tag(MatteSource.noise)
                ForEach(videos) { video in
                    Text(video.name).tag(MatteSource.clip(video.id))
                }
            }
            .help("Its brightest parts are revealed first: noise, or the first frame of a video")
        }
    }

    /// A slider from 0 to 1 labeled with its name and value in percent.
    private func fractionSlider(_ name: String, value: Binding<Double>) -> some View {
        HStack(spacing: Design.Space.step) {
            Text(name)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
                .frame(width: 92, alignment: .leading)
            Slider(value: value, in: 0...1)
                .accessibilityLabel(name)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 36, alignment: .trailing)
                .accessibilityHidden(true)
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

    private func centerBinding(_ keyPath: WritableKeyPath<CGPoint, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(transition.options.center[keyPath: keyPath]) },
            set: { value in
                var options = transition.options
                options.center[keyPath: keyPath] = CGFloat(value)
                onChange(options)
            }
        )
    }

    private var colorBinding: Binding<CGColor> {
        Binding(
            get: {
                let color = transition.options.color
                return CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
            },
            set: { cgColor in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let srgb = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
                      let parts = srgb.components, parts.count >= 3
                else { return }
                var options = transition.options
                options.color = TransitionColor(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
                onChange(options)
            }
        )
    }
}
