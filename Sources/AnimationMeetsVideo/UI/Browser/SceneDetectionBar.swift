import SwiftUI

/// How far scene detection has got for a video shown whole, across the top
/// of its filmstrip's first row; nothing once its scenes are found or while
/// none are being found. It reads the analysis itself, so each step of
/// progress redraws only this bar, not the whole list of clips around it.
struct SceneDetectionBar: View {
    let analysis: AssetAnalysis
    let clip: MediaClip

    /// How far detection has got, while it is finding this video's scenes.
    static func fraction(of clip: MediaClip, in analysis: AssetAnalysis) -> Double? {
        guard clip.kind == .video, analysis.tracks[clip.id] == nil else { return nil }
        return analysis.progress[clip.id]
    }

    var body: some View {
        if let fraction = Self.fraction(of: clip, in: analysis) {
            // The label, shortened, then left out, on a single small
            // thumbnail, so the bar always has room.
            ViewThatFits(in: .horizontal) {
                bar(fraction, label: "Detecting scenes")
                bar(fraction, label: "Detecting")
                bar(fraction, label: nil)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.6))
            .clipped()
            .accessibilityHidden(true)
        }
    }

    private func bar(_ fraction: Double, label: String?) -> some View {
        HStack(spacing: Design.Space.tight) {
            if let label {
                Text(label)
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textOnColor)
                    .fixedSize()
            }
            Capsule()
                .fill(Design.textOnColor.opacity(0.25))
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Design.accent)
                            .frame(width: proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
                    }
                }
                .frame(minWidth: 24, maxWidth: .infinity)
                .frame(height: 4)
        }
    }
}
