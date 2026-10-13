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

    private var isAnimated: Bool { transform.isAnimated(property) }
    private var keyframeTimes: [CMTime] { transform.keyframeTimes(property) }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                onEdit { $0.setAnimated(property, !isAnimated, at: time) }
            } label: {
                Image(systemName: isAnimated ? "stopwatch.fill" : "stopwatch")
                    .foregroundStyle(isAnimated ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isAnimated ? "Stop animating \(property.rawValue.lowercased()) (keeps the current value)" : "Animate \(property.rawValue.lowercased())")

            Text(property.rawValue)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            if property == .scale {
                Button {
                    onEdit { $0.scaleLinked.toggle() }
                } label: {
                    Image(systemName: "link")
                        .foregroundStyle(transform.scaleLinked ? Color.primary : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help(transform.scaleLinked ? "Width and height scale together" : "Width and height scale separately")
            }

            let components = transform.components(property, at: time, frameSize: frameSize)
            ForEach(components.indices, id: \.self) { index in
                if index > 0 { Text(",").foregroundStyle(.secondary) }
                NumericField(value: components[index], unit: property.unit) { newValue in
                    onEdit { $0.setComponent(index, of: property, to: newValue, at: time, frameSize: frameSize) }
                }
            }

            Spacer(minLength: 4)

            if isAnimated {
                keyframeNavigation
            }
        }
        .font(.caption)
    }

    private var keyframeNavigation: some View {
        let previous = keyframeTimes.last { $0 < time }
        let next = keyframeTimes.first { $0 > time }
        let hasKeyframe = keyframeTimes.contains(time)
        return HStack(spacing: 2) {
            Button {
                if let previous { onSeek(previous) }
            } label: {
                Image(systemName: "arrowtriangle.left.fill")
            }
            .disabled(previous == nil)
            .help("Previous keyframe")
            Button {
                onEdit { $0.toggleKeyframe(property, at: time) }
            } label: {
                Image(systemName: hasKeyframe ? "diamond.fill" : "diamond")
                    .foregroundStyle(hasKeyframe ? Color.yellow : Color.secondary)
            }
            .help(hasKeyframe ? "Remove the keyframe at the playhead" : "Add a keyframe at the playhead")
            Button {
                if let next { onSeek(next) }
            } label: {
                Image(systemName: "arrowtriangle.right.fill")
            }
            .disabled(next == nil)
            .help("Next keyframe")
        }
        .buttonStyle(.plain)
        .font(.system(size: 8))
    }
}

/// The four property rows of a layer, for the inspector.
struct TransformInspectorSection: View {
    let transform: LayerTransform
    let time: CMTime
    let frameSize: CGSize
    let onEdit: ((inout LayerTransform) -> Void) -> Void
    let onSeek: (CMTime) -> Void

    var body: some View {
        ForEach(TransformProperty.allCases) { property in
            TransformPropertyRow(
                property: property, transform: transform, time: time,
                frameSize: frameSize, onEdit: onEdit, onSeek: onSeek
            )
        }
        Button("Reset Transform") {
            onEdit { $0 = .identity }
        }
        .disabled(transform == .identity)
    }
}
