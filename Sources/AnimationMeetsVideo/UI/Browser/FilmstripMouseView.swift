import AppKit
import SwiftUI

/// What a press on a filmstrip turned out to be.
enum FilmstripPress {
    /// Released without moving: a click, with the keys held at the press.
    case click(CGPoint, NSEvent.ModifierFlags)
    /// Moved while tracking a range (Option-drag, or a range's handle).
    case track(CGPoint)
    /// The tracked range was let go.
    case endTrack(CGPoint)
}

/// Catches the mouse over one row of a filmstrip. A press either tracks a
/// range (when `onDown` says so: Option was held, or it landed on a
/// handle) or becomes a click when released in place, or a drag of media
/// once it moves: the drag carries the text `dragText` gives for the point
/// pressed, as `MediaDragPayload` reads it. AppKit rather than SwiftUI
/// gestures, so the keys held at the press decide between a range and a
/// drag before any drag begins. Points are in the filmstrip's layout,
/// `rowOffset` below the row's own top.
struct FilmstripMouseView: NSViewRepresentable {
    var rowOffset: CGFloat
    /// The press at a point, with the keys held: true to track a range.
    var onDown: (CGPoint, NSEvent.ModifierFlags) -> Bool
    var onPress: (FilmstripPress) -> Void
    /// The payload for a drag starting at a point, with the picture that
    /// follows the pointer; nil not to drag.
    var dragText: (CGPoint) -> (text: String, image: NSImage)?
    /// Whether a point is on a range's handle, which shows the resize
    /// cursor.
    var isOnHandle: (CGPoint) -> Bool = { _ in false }
    /// The pointer over the strip, nil once it leaves.
    var onHover: (CGPoint?) -> Void = { _ in }

    func makeNSView(context: Context) -> MouseView {
        let view = MouseView()
        view.configuration = self
        return view
    }

    func updateNSView(_ view: MouseView, context: Context) {
        view.configuration = self
    }

    final class MouseView: NSView, NSDraggingSource {
        var configuration: FilmstripMouseView?
        private var downPoint: CGPoint?
        private var downFlags: NSEvent.ModifierFlags = []
        private var tracking = false
        private var dragging = false
        /// How far the pointer moves before a press becomes a drag.
        private let dragThreshold: CGFloat = 3
        /// The picture following the pointer, and whether it is hidden
        /// because a layer under the pointer draws the media instead.
        private var dragImage: NSImage?
        private var dragImageHidden = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func layoutPoint(_ event: NSEvent) -> CGPoint {
            let local = convert(event.locationInWindow, from: nil)
            return CGPoint(x: local.x, y: local.y + (configuration?.rowOffset ?? 0))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
            ))
        }

        override func mouseMoved(with event: NSEvent) {
            let point = layoutPoint(event)
            showCursor(over: point)
            configuration?.onHover(point)
        }

        override func mouseExited(with event: NSEvent) {
            if !tracking { NSCursor.arrow.set() }
            configuration?.onHover(nil)
        }

        /// The resize cursor over a handle, the arrow elsewhere.
        private func showCursor(over point: CGPoint) {
            if configuration?.isOnHandle(point) == true {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }

        override func mouseDown(with event: NSEvent) {
            let point = layoutPoint(event)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            downPoint = point
            downFlags = flags
            dragging = false
            tracking = configuration?.onDown(point, flags) ?? false
        }

        override func mouseDragged(with event: NSEvent) {
            let point = layoutPoint(event)
            if tracking {
                NSCursor.resizeLeftRight.set()
                configuration?.onPress(.track(point))
                return
            }
            guard !dragging, let downPoint, hypot(point.x - downPoint.x, point.y - downPoint.y) >= dragThreshold,
                  let drag = configuration?.dragText(downPoint)
            else { return }
            dragging = true
            let item = NSPasteboardItem()
            item.setString(drag.text, forType: .string)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let image = drag.image
            dragImage = image
            dragImageHidden = false
            let local = convert(event.locationInWindow, from: nil)
            draggingItem.setDraggingFrame(
                CGRect(x: local.x - image.size.width / 2, y: local.y - image.size.height / 2, width: image.size.width, height: image.size.height),
                contents: image
            )
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            let point = layoutPoint(event)
            if tracking {
                configuration?.onPress(.endTrack(point))
                showCursor(over: point)
            } else if !dragging, let downPoint {
                configuration?.onPress(.click(downPoint, downFlags))
            }
            downPoint = nil
            tracking = false
            dragging = false
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        /// Over a layer the media would fit on, the layer draws it where it
        /// would land, so the thumbnail under the pointer is hidden; it
        /// comes back anywhere else.
        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            let hide = MediaDragSession.shared.targetLayerID != nil
            guard hide != dragImageHidden, let dragImage else { return }
            dragImageHidden = hide
            let shown = hide ? NSImage(size: dragImage.size) : dragImage
            session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                item.setDraggingFrame(item.draggingFrame, contents: shown)
            }
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragImage = nil
            MediaDragSession.shared.end()
        }
    }
}
