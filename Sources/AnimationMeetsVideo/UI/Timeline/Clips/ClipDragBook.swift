import CoreMedia
import SwiftUI

/// What a clip block keeps about the drag in progress that it reads only
/// as the drag runs, not to draw: in a box, so that writing it on every
/// pointer move doesn't redraw the block.
@MainActor
final class ClipDragBook {
    /// What a drag of the block does.
    enum Kind: Equatable {
        case move, slip, trim

        /// What dragging the block's middle does with `tool`; nil for the
        /// blade, which only clicks.
        init?(tool: TimelineTool) {
            switch tool {
            case .arrow: self = .move
            case .slip: self = .slip
            case .blade: return nil
            }
        }
    }

    /// Whether the block's drag gesture is on with `tool`. Off is
    /// `.subviews`, never `.none`: `.none` also switches off the gestures
    /// of the views inside the block, and once left a block's other drag
    /// gesture switching this one off, so clips couldn't be moved.
    static func gestureMask(for tool: TimelineTool) -> GestureMask {
        Kind(tool: tool) == nil ? .subviews : .all
    }

    /// The drag in progress, from its first move until the button comes
    /// up; nil between drags. Fixed when it begins, so changing tools
    /// during one doesn't turn a move into a slip.
    private(set) var kind: Kind?
    /// Escape cancelled the last drag. Cleared only when the next one
    /// begins, so nothing the cancelled one still reports, its end
    /// included, can be taken for a new drag.
    private(set) var isCancelled = false

    /// Whether the drag in progress was cancelled: its other moves, and
    /// its end, do nothing. A press that never became a drag (a click)
    /// isn't one.
    var isCancelledDrag: Bool { kind != nil && isCancelled }
    private var escape: DragEscape?
    /// How far a slip in progress moves the footage.
    var slipDelta: CMTime?

    /// What was last sent up to the timeline. Each of these sets state
    /// that every row reads, so sending the same again would redraw them
    /// all for nothing; a drag sends on every pointer move.
    var snap = LastSent<CMTime?>(nil)
    var movePreview = LastSent<ClipMovePreview?>(nil)
    var trimPreview = LastSent<TrimDraft?>(nil)
    var slipDraft = LastSent<SlipDraft?>(nil)

    /// A trim draft as sent: the clip, and which of its frames to show.
    struct TrimDraft: Equatable {
        var clip: TimelineClip
        var frames: TrimPreviewFrames
    }

    /// A slip draft as sent: the clip, or nil at the end with whether the
    /// slip is being committed.
    struct SlipDraft: Equatable {
        var clip: TimelineClip?
        var committing: Bool
    }

    /// A drag of `kind` began; Escape calls `onEscape` until it ends.
    func begin(_ kind: Kind, onEscape: @escaping () -> Void) {
        self.kind = kind
        isCancelled = false
        escape?.end()
        escape = DragEscape(onEscape: onEscape)
    }

    /// Escape was pressed: the drag is over, though the button is still
    /// down.
    func cancel() {
        isCancelled = true
        escape?.end()
        escape = nil
    }

    /// The button came up.
    func finish() {
        kind = nil
        escape?.end()
        escape = nil
    }
}

/// The last value sent somewhere, to send only changes.
struct LastSent<Value: Equatable> {
    private var last: Value

    init(_ initial: Value) {
        last = initial
    }

    /// Whether `value` differs from the last sent, recording it if so.
    mutating func changes(to value: Value) -> Bool {
        guard value != last else { return false }
        last = value
        return true
    }
}
