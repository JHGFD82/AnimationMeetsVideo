import SwiftUI

/// One part of a timeline in the Timelines tab that takes drops: its row
/// in the tree, or in filmstrips its title or one row of its strip. Kept
/// apart so moving from one part of a timeline to the next, whose enter
/// can come before the other's exit, keeps the timeline lit.
struct TimelineDropPart: Hashable {
    let timelineID: UUID
    let part: Int
}

extension View {
    /// Takes timelines dragged in the Timelines tab and embeds them in
    /// `timelineID` (`onDrop`), as Embed in Active Timeline would the open
    /// one: back to back on a new layer at its top, from its start. While a
    /// drag it can take is over it, its part is in `hovered`, for the
    /// timeline to draw lit. A drag it can't take, such as a timeline into
    /// itself or into one it is drawn into, isn't lit and does nothing.
    func timelineDropTarget(
        _ part: TimelineDropPart, project: EditingProject, hovered: Binding<Set<TimelineDropPart>>,
        onDrop: @escaping ([MediaPiece], UUID) -> Bool
    ) -> some View {
        dropDestination(for: MediaDragPayload.self) { payloads, _ in
            // A drag SwiftUI started (a timeline's name) has no end of its
            // own to tell the session.
            MediaDragSession.shared.end()
            hovered.wrappedValue.remove(part)
            let pieces = payloads.flatMap(\.pieces)
            guard project.canPlaceAll(pieces, in: part.timelineID) else { return false }
            return onDrop(pieces, part.timelineID)
        } isTargeted: { inside in
            if inside, project.canPlaceAll(MediaDragSession.shared.pieces, in: part.timelineID) {
                hovered.wrappedValue.insert(part)
            } else {
                hovered.wrappedValue.remove(part)
            }
        }
    }
}

extension Set<TimelineDropPart> {
    /// Whether a drag is over any part of `timelineID` that takes it.
    func lights(_ timelineID: UUID) -> Bool {
        contains { $0.timelineID == timelineID }
    }
}
