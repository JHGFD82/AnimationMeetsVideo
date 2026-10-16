import CoreMedia
import SwiftUI

/// One transform property's controls: the stopwatch that turns keyframing
/// on and off, its name, its values at the playhead, and, once animated,
/// buttons to go to the previous or next keyframe and to add or remove one
/// at the playhead. Used in the timeline and the inspector.
struct TransformPropertyRow: View {
    let property: TransformProperty
    let transform: LayerTransform
    /// The playhead, snapped to a frame.
    let time: CMTime
    let frameSize: CGSize
    let onEdit: ((inout LayerTransform) -> Void) -> Void
    let onSeek: (CMTime) -> Void
    /// Opens the property's graph editor; offered while it is animated.
    var onShowGraph: (() -> Void)?

    private var isAnimated: Bool { transform.isAnimated(property) }
    private var keyframeTimes: [CMTime] { transform.keyframeTimes(property) }

    var body: some View {
        HStack(spacing: 4) {
            AnimateToggle(name: property.rawValue.lowercased(), isAnimated: isAnimated) {
                onEdit { $0.setAnimated(property, !isAnimated, at: time) }
            }

            Text(property.rawValue)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 50, alignment: .leading)

            if property == .scale {
                Button {
                    onEdit { $0.scaleLinked.toggle() }
                } label: {
                    PropertyRowIcon(systemName: "link")
                        .foregroundStyle(transform.scaleLinked ? Design.textPrimary : Design.textTertiary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(transform.scaleLinked ? "Width and height scale together" : "Width and height scale separately")
                .accessibilityLabel("Link width and height")
                .accessibilityValue(transform.scaleLinked ? "On" : "Off")
            }

            let components = transform.components(property, at: time, frameSize: frameSize)
            ForEach(components.indices, id: \.self) { index in
                if index > 0 { Text(",").foregroundStyle(Design.textTertiary) }
                NumericField(value: components[index], unit: property.unit, accessibilityName: componentName(index)) { newValue in
                    onEdit { $0.setComponent(index, of: property, to: newValue, at: time, frameSize: frameSize) }
                }
            }

            Spacer(minLength: 4)

            if isAnimated {
                KeyframeNavigator(name: property.rawValue.lowercased(), keyframeTimes: keyframeTimes, time: time, onSeek: onSeek) {
                    onEdit { $0.toggleKeyframe(property, at: time) }
                }
                if let onShowGraph { GraphEditorButton(name: property.rawValue.lowercased(), action: onShowGraph) }
            }
        }
        .font(Design.Typeface.label)
    }

    /// "Position X", or just "Rotation" for a property of one component.
    private func componentName(_ index: Int) -> String {
        let names = AnimatedParameter.transform(property).componentNames
        guard names.count > 1, names.indices.contains(index) else { return property.rawValue }
        return "\(property.rawValue) \(names[index])"
    }
}

/// The four property rows of a layer, for the inspector.
struct TransformInspectorSection: View {
    let transform: LayerTransform
    let time: CMTime
    let frameSize: CGSize
    let onEdit: ((inout LayerTransform) -> Void) -> Void
    let onSeek: (CMTime) -> Void
    var onShowGraph: ((TransformProperty) -> Void)?

    var body: some View {
        ForEach(TransformProperty.allCases) { property in
            TransformPropertyRow(
                property: property, transform: transform, time: time,
                frameSize: frameSize, onEdit: onEdit, onSeek: onSeek,
                onShowGraph: onShowGraph.map { show in { show(property) } }
            )
        }
        Button("Reset transform") {
            onEdit { $0 = .identity }
        }
        .disabled(transform == .identity)
    }
}
