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
        let thumbWidth = max(28, trackWidth * min(1, viewport.width / max(viewport.contentWidth, 1)))
        let travel = max(1, trackWidth - thumbWidth)
        let thumbX = viewport.maxScrollX > 0 ? viewport.scrollX / viewport.maxScrollX * travel : 0

        ZStack(alignment: .leading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let page = viewport.width * 0.9
                    onScroll(viewport.scrollX + (location.x < thumbX ? -page : page))
                }
            Capsule()
                .fill(Color.secondary.opacity(dragStartScrollX == nil ? 0.35 : 0.55))
                .frame(width: thumbWidth, height: 6)
                .frame(width: thumbWidth, height: Self.height)
                .contentShape(Rectangle())
                .offset(x: thumbX)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStartScrollX ?? viewport.scrollX
                            if dragStartScrollX == nil { dragStartScrollX = start }
                            onScroll(start + value.translation.width * viewport.maxScrollX / travel)
                        }
                        .onEnded { _ in dragStartScrollX = nil }
                )
        }
        .frame(width: trackWidth, height: Self.height)
        .opacity(viewport.maxScrollX > 0 ? 1 : 0)
        .allowsHitTesting(viewport.maxScrollX > 0)
    }
}
