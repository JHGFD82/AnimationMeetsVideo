import SwiftUI

/// A thin strip along the bottom of the ruler showing which parts of the
/// timeline need rendering (orange), are rendering (filling in green) and
/// are rendered (green). Parts that play straight from their files show
/// nothing.
struct RenderStatusStrip: View {
    let viewport: TimelineViewport
    @Environment(RenderScheduler.self) private var renderer: RenderScheduler?

    static let height: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            guard let renderer else { return }
            let visible = viewport.visibleSeconds
            for segment in renderer.segments {
                guard let state = renderer.state(of: segment) else { continue }
                let start = segment.range.start.seconds, end = segment.range.end.seconds
                guard end > visible.lowerBound, start < visible.upperBound else { continue }
                let minX = viewport.x(atSeconds: start), maxX = viewport.x(atSeconds: end)
                let rect = CGRect(x: minX, y: 0, width: max(1, maxX - minX), height: size.height)
                switch state {
                case .rendered:
                    context.fill(Path(rect), with: .color(.green.opacity(0.75)))
                case .pending:
                    context.fill(Path(rect), with: .color(.orange.opacity(0.85)))
                case .rendering(let progress):
                    context.fill(Path(rect), with: .color(.orange.opacity(0.85)))
                    var done = rect
                    done.size.width = rect.width * progress
                    context.fill(Path(done), with: .color(.green.opacity(0.75)))
                }
            }
        }
        .frame(width: viewport.width, height: Self.height)
        .allowsHitTesting(false)
    }
}
