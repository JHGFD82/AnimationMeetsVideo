import CoreMedia
import SwiftUI

/// A row of the effects panel's stack, built and drawn again only when
/// `key`, what it shows, changes (its parent marks it `.equatable()`).
/// Without it, every edit and every playhead step rebuilt every row of the
/// stack, though one row changed or none did. A row kept from an earlier
/// redraw keeps its closures, so they act by ID and read the playhead
/// through `RowContext.now`, never from what they captured. A row whose
/// value is animated reads the playhead as it draws (`RowContext.sourceNow(animated:)`)
/// and so is redrawn as it moves, with nothing above it.
struct StackRow<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content

    var body: some View { content() }

    nonisolated static func == (lhs: StackRow, rhs: StackRow) -> Bool {
        MainActor.assumeIsolated { lhs.key == rhs.key }
    }
}

/// What a lane draws its keyframes against: where the clip sits, how it
/// is retimed, the frame rate times snap to, and the lane's width. The
/// lane geometry holds the whole timeline, which every edit changes.
struct LaneKey: Equatable {
    var startOffset: CMTime
    var trimStart: CMTime
    var trimEnd: CMTime
    var time: ClipTime
    var frameRate: Double
    var width: CGFloat

    init(_ geometry: ClipLaneGeometry) {
        startOffset = geometry.clip.startOffset
        trimStart = geometry.clip.trimStart
        trimEnd = geometry.clip.trimEnd
        time = geometry.clip.time
        frameRate = geometry.timeline.frameRate
        width = geometry.width
    }
}
