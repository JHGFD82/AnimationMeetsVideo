import SwiftUI

/// Along the bottom of a clip that takes part in a stretch still to be
/// rendered: how much of it is rendered so far.
struct RenderProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Design.statusPending)
                Rectangle().fill(Design.statusDone)
                    .frame(width: geometry.size.width * progress.clamped(between: 0, and: 1))
            }
        }
        .frame(height: 3)
        .help("Rendering in the background when the timeline is idle: \(Int(progress * 100))% done")
    }
}

/// A clip's render progress bar, drawn only while some of it is still to
/// be rendered. A view of its own, so that a render going on redraws this
/// and not the clip block it sits on.
struct ClipRenderProgressView: View {
    let cell: ClipRenderProgress

    var body: some View {
        if let progress = cell.value {
            RenderProgressBar(progress: progress)
        }
    }
}
