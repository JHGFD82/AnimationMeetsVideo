import SwiftUI

/// A menu item that starts analyzing an asset again, off while it is being
/// analyzed. It reads the analysis itself, so the menu around it, built
/// with the Clips tab, doesn't redraw the tab at every step of progress.
struct AnalysisIdleButton: View {
    let title: String
    let analysis: AssetAnalysis
    let assetID: UUID
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .disabled(analysis.progress[assetID] != nil)
    }
}
