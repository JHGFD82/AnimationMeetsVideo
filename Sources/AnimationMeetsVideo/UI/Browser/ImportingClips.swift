import SwiftUI

/// The files being imported, at the end of the Clips tab where each will
/// arrive: its name over its progress, or a bar that runs until the
/// import can tell. It reads `MediaImports` itself, so each step of
/// progress redraws only these lines, not the clips above them.
struct ImportingClips: View {
    let imports: MediaImports

    var body: some View {
        ForEach(imports.items) { item in
            ImportingClipRow(item: item)
                .padding(.top, Design.Space.step)
        }
    }
}

struct ImportingClipRow: View {
    let item: MediaImports.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .lineLimit(1)
            HStack(spacing: Design.Space.close) {
                Group {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                .controlSize(.small)
                .frame(width: 60)
                Text("Importing…")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Importing \(item.name)")
        .accessibilityValue(item.fraction.map { "\(Int($0 * 100)) percent" } ?? "")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
