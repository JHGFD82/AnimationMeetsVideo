import AppKit
import SwiftUI

extension View {
    /// Runs `action` the moment the mouse goes down anywhere in the view's
    /// frame, with the system's click count, alongside whatever the
    /// controls in it do with the click.
    ///
    /// For selecting: a tap gesture waits until it knows a click isn't the
    /// start of a double-click whenever one is attached for that, so the
    /// selection lagged and quick clicks seemed lost, and a tap only counts
    /// on the view it is attached to. The section lane selects the same way.
    func onMouseDown(perform action: @escaping (_ clickCount: Int) -> Void) -> some View {
        contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onChanged { _ in
                    // Only the press itself, not each step of a drag.
                    guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return }
                    action(event.clickCount)
                }
            )
    }
}
