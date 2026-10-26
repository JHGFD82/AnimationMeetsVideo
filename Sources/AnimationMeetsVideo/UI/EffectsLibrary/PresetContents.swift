import SwiftUI

/// What a preset holds, top of the stack first: each effect with how it is
/// set. Shown over the Presets tab while the pointer rests on a preset.
struct PresetContents: View {
    let preset: EffectPreset

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            Text(preset.name)
                .font(Design.Typeface.groupTitle)
                .foregroundStyle(Design.textPrimary)
            ForEach(Array(preset.bundle.effects.enumerated()), id: \.offset) { _, item in
                row(item.effect.summary)
            }
            Text("Drag onto a clip, or double-click to apply it to the selected clip.")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Design.Space.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface(radius: Design.Radius.chip)
    }

    private func row(_ summary: EffectSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.tight) {
            Image(systemName: summary.systemImage)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Design.Space.tight) {
                    Text(summary.name)
                        .foregroundStyle(Design.textPrimary)
                    if let kind = summary.kindName {
                        Text(kind).foregroundStyle(Design.textTertiary)
                    }
                    if !summary.enabled {
                        Text("Off").foregroundStyle(Design.textTertiary)
                    }
                }
                .font(Design.Typeface.label)
                if !summary.settings.isEmpty {
                    Text(summary.settings.joined(separator: " · "))
                        .font(Design.Typeface.numericMicro)
                        .foregroundStyle(Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(summary.enabled ? 1 : 0.6)
    }

    /// The same, read out by VoiceOver on the preset's row.
    static func spoken(_ preset: EffectPreset) -> String {
        preset.bundle.effects.map { item in
            let summary = item.effect.summary
            return ([summary.name + (summary.enabled ? "" : ", off")] + summary.settings).joined(separator: ", ")
        }
        .joined(separator: "; ")
    }
}
