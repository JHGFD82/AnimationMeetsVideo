import SwiftUI

/// Along the bottom of a clip that takes part in a stretch still to be
/// rendered: how much of it is rendered so far.
struct RenderProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.orange.opacity(0.85))
                Rectangle().fill(Color.green.opacity(0.85))
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 3)
        .help("Rendering in the background when the timeline is idle: \(Int(progress * 100))% done")
    }
}
