import AppKit
import SwiftUI

/// Scrolls the scroll view it is placed in (`edgeAutoScroll`) up or down
/// while a drag holds the pointer near its top or bottom edge, the deeper
/// into the edge the faster, as Finder and Mail lists do. The timeline's
/// sideways scrolling has its own (`TimelineAutoScroll`), since it scrolls
/// itself rather than a scroll view.
///
/// It reads the pointer itself, so it keeps scrolling while the pointer
/// holds still at the edge; a drag only has to say it moved.
@MainActor
final class EdgeAutoScroll {
    /// How close to an edge, in points, the pointer starts scrolling.
    static let edgeWidth: CGFloat = 32
    /// The most it scrolls in one step, at the very edge or past it.
    static let maximumStep: CGFloat = 16

    fileprivate weak var anchor: NSView?
    private var task: Task<Void, Never>?
    /// Points scrolled since the drag began; positive is down.
    private(set) var scrolled: CGFloat = 0
    /// Called after each step, for a drag to place itself again.
    var onScroll: (() -> Void)?

    /// Starts a drag: nothing scrolled yet.
    func begin() {
        end()
        scrolled = 0
    }

    /// The drag moved. Near an edge this keeps scrolling until the pointer
    /// leaves it or the mouse button comes up.
    func dragMoved() {
        guard task == nil, step() != 0 else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, NSEvent.pressedMouseButtons & 1 != 0 else { break }
                let wanted = self.step()
                guard wanted != 0 else { break }
                let moved = self.scroll(by: wanted)
                guard moved != 0 else { break }
                self.scrolled += moved
                self.onScroll?()
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.task = nil
        }
    }

    /// Stops scrolling.
    func end() {
        task?.cancel()
        task = nil
    }

    /// How far to scroll this step: zero away from the edges, negative
    /// (up) near the top.
    private func step() -> CGFloat {
        guard let scrollView = anchor?.enclosingScrollView, let window = scrollView.window else { return 0 }
        let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        // Window coordinates run up from the bottom.
        let frame = scrollView.convert(scrollView.bounds, to: nil)
        guard frame.height > Self.edgeWidth * 3, (frame.minX...frame.maxX).contains(pointer.x) else { return 0 }
        let intoTop = pointer.y - (frame.maxY - Self.edgeWidth)
        let intoBottom = frame.minY + Self.edgeWidth - pointer.y
        if intoTop > 0 { return -Self.maximumStep * min(1, intoTop / Self.edgeWidth) }
        if intoBottom > 0 { return Self.maximumStep * min(1, intoBottom / Self.edgeWidth) }
        return 0
    }

    /// How far down the scroll view is scrolled, in points from its top;
    /// nil before it is laid out.
    var offset: CGFloat? {
        guard let scrollView = anchor?.enclosingScrollView, let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        let origin = clip.bounds.origin.y
        return clip.isFlipped ? origin : document.frame.height - clip.bounds.height - origin
    }

    /// Scrolls to `offset` points from the top, or as near as the content
    /// allows; true once it is there.
    @discardableResult
    func scroll(toOffset offset: CGFloat) -> Bool {
        guard let current = self.offset else { return false }
        scroll(by: offset - current)
        return abs((self.offset ?? current) - offset) < 0.5
    }

    /// Scrolls down by `distance` (up when negative) and returns how far
    /// it really went, which is less at either end.
    @discardableResult
    private func scroll(by distance: CGFloat) -> CGFloat {
        guard let scrollView = anchor?.enclosingScrollView, let document = scrollView.documentView else { return 0 }
        let clip = scrollView.contentView
        // Down is toward larger y in a flipped view, smaller otherwise.
        let sign: CGFloat = clip.isFlipped ? 1 : -1
        let limit = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        let before = origin.y
        origin.y = (origin.y + distance * sign).clamped(between: 0, and: limit)
        guard origin.y != before else { return 0 }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        return (origin.y - before) * sign
    }
}

extension View {
    /// Lets `scroller` scroll the scroll view this view is in. Put it on
    /// the scroll view's content.
    func edgeAutoScroll(_ scroller: EdgeAutoScroll) -> some View {
        background(EdgeAutoScrollAnchor(scroller: scroller))
    }
}

private struct EdgeAutoScrollAnchor: NSViewRepresentable {
    let scroller: EdgeAutoScroll

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        scroller.anchor = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        scroller.anchor = view
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
