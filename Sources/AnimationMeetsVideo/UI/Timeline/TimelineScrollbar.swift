import SwiftUI

/// A horizontal scroller for the track area, which scrolls itself rather
/// than sitting in a scroll view. The thumb shows the visible share of the
/// timeline; dragging it scrolls, and clicking the track pages toward the
/// click.
struct TimelineScrollbar: View {
    let viewport: TimelineViewport
    let onScroll: (CGFloat) -> Void

    @State private var dragStartScrollX: CGFloat?

    static let height: CGFloat = 12

    var body: some View {
        let trackWidth = viewport.width
        // The lead-in before 0:00 counts as content while there is one.
        let span = viewport.maxScrollX - viewport.minScrollX
        let thumbWidth = max(28, trackWidth * min(1, viewport.width / max(viewport.contentWidth + viewport.leadIn, 1)))
        let travel = max(1, trackWidth - thumbWidth)
        let thumbX = span > 0 ? (viewport.scrollX - viewport.minScrollX) / span * travel : 0

        ZStack(alignment: .leading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let page = viewport.width * 0.9
                    onScroll(viewport.scrollX + (location.x < thumbX ? -page : page))
                }
            Capsule()
                .fill(dragStartScrollX == nil ? Design.textTertiary.opacity(0.5) : Design.textSecondary)
                .frame(width: thumbWidth, height: 6)
                .frame(width: thumbWidth, height: Self.height)
                .contentShape(Rectangle())
                .offset(x: thumbX)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStartScrollX ?? viewport.scrollX
                            if dragStartScrollX == nil { dragStartScrollX = start }
                            onScroll(start + value.translation.width * span / travel)
                        }
                        .onEnded { _ in dragStartScrollX = nil }
                )
        }
        .frame(width: trackWidth, height: Self.height)
        .opacity(span > 0 ? 1 : 0)
        .allowsHitTesting(span > 0)
    }
}
