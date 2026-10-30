import CoreMedia
import SwiftUI

/// Everything a clip block draws from: the values `ClipBlockView.==`
/// compares, so a block whose clip, size and state are unchanged isn't
/// drawn again when its row is (another clip on the layer moved, the
/// selection went to another clip, a drag pushed its neighbours aside).
struct ClipBlockModel: Equatable {
    var clip: TimelineClip
    /// The timeline's rate: VoiceOver reads times as its timecode, and moves
    /// and trims by its frames.
    var frameRate: Double
    var info: ResolvedClipInfo?
    var typeColor: Color
    /// Shows a sound badge, and offers to detach the sound.
    var hasLinkedAudio: Bool
    /// Draws the clip's sound behind its label when the layer is tall
    /// enough; for clips that are sound alone.
    var showsWaveform: Bool
    /// Draws the waveform's channels apart, at any height.
    var splitsChannels: Bool
    /// Which transitions dropped from the panel it takes: of pictures, or
    /// of sound on a clip that only makes sound.
    var transitionsTaken: TransitionsTaken
    /// Set when the clip's way in joins it to the clip before: that
    /// transition is drawn over the cut by the row instead.
    var joinedLead: CMTime?
    var isSelected: Bool
    /// Whether the clip is one of several picked together with a lasso, which
    /// draw as selected and are copied, deleted and nested as one.
    var isInGroup = false
    /// Whether the clips picked together are on more than one layer, which
    /// the motion designer can't open on.
    var groupSpansLayers = false
    /// The transition selected on this clip, which shows its curve's points
    /// when there is room.
    var selectedTransition: TransitionEdge?
    var pixelsPerSecond: CGFloat
    var height: CGFloat
    var visibleX: ClosedRange<CGFloat>
    /// Arrow moves and trims, blade splits where clicked, slip changes the
    /// footage a clip plays.
    var tool: TimelineTool
    /// Clips with pictures take effects dragged from the effects panel.
    var acceptsEffects: Bool
    /// Clips with sound take sound effects.
    var acceptsSoundEffects = false
    /// How many effects are in the clip's stacks, picture and sound, for
    /// its badge.
    var effectCount: Int
    /// Draws the clip's volume as a line across it.
    var showsVolumeLine: Bool
    /// For a nested clip: whether its layers are drawn into the timeline it
    /// is placed in.
    var passesThrough: Bool
    /// Whether an effect of the clip has paste changes left to resolve.
    var hasPasteChanges: Bool
    /// Whether the clip makes sound, which a retimed clip's sound choice is for.
    var playsSound: Bool
    /// For a song: the timeline times the selected clips are tied to it at,
    /// marked on it to show what their music points hold on to.
    var musicMarks: [CMTime] = []
    /// For an adjustment clip: what it reaches, and the choices.
    var reach: ReachMenu?
}

/// What a clip block does: the closures its gestures, drops, menus and
/// VoiceOver actions call. Not compared, so a block that isn't drawn again
/// keeps the gestures it installed when it last was; they reach these
/// through `LiveClipHandlers`, which its row fills anew every time it is
/// drawn, so they always act with what the row last saw. A closure here
/// must not hold anything the row doesn't redraw for (see
/// `LayerClipRow.==`): what it needs beyond that it reads as it runs,
/// through reference-type stores (`liveSnap`, the host's `readProject`).
struct ClipBlockHandlers {
    /// Adds the clip to the clips picked together, or takes it out: the way to
    /// pick several without a lasso.
    var onToggleInGroup: () -> Void
    /// Shift-click: picks the clips from the one last clicked to this one.
    var onSelectRange: () -> Void
    /// How far the clips picked with this one can go dragged by a time:
    /// whole frames, none before zero.
    var resolveGroupMove: (CMTime) -> CMTime
    /// Hears how far the clips picked together are being dragged, and nil
    /// when the drag ends.
    var onGroupMovePreview: (CMTime?) -> Void
    /// Moves the clips picked together by a time, each on its own layer.
    var onMoveGroup: (CMTime) -> Bool
    /// For a nested timeline's clip: goes into the timeline it plays (a
    /// double-click, the menu's Open Timeline).
    var onOpenNested: (() -> Void)?
    var resolveMove: (CMTime, CGPoint) -> ClipMovePreview?
    var resolveTrimStart: (CMTime) -> TimelineClip?
    var resolveTrimEnd: (CMTime) -> TimelineClip?
    var onSelect: () -> Void
    // The edits a drag lets go of say whether they were made: one that
    // wasn't (it was refused) springs back at once, and says so.
    var onMove: (CMTime, UUID?) -> Bool
    /// Onto a new layer of a kind, starting at a time.
    var onMoveToNewLayer: (LayerKind, CMTime) -> Bool
    var onDragging: (Bool) -> Void
    /// Hears where a move drag will land, and nil when it ends.
    var onMovePreview: (ClipMovePreview?) -> Void
    var onTrimStart: (CMTime) -> Bool
    var onTrimEnd: (CMTime) -> Bool
    /// Hears each trim draft with the edge being dragged, for the viewer
    /// to show the frame there, then nil when the drag ends.
    var onTrimPreview: (TimelineClip?, TrimPreviewFrames) -> Void
    var onSetTransition: (TransitionKind, TransitionEdge) -> Void
    var onRemoveTransition: (TransitionEdge) -> Void
    var onSelectTransition: (TransitionEdge) -> Void
    var onSetTransitionCurve: (TransitionEdge, TransitionCurve) -> Void
    var onDetachAudio: () -> Void
    var snap: (CMTime) -> CMTime
    /// Splits the clip at a timeline time, from the blade.
    var onBlade: (CMTime) -> Void
    /// The clip after slipping by a time (positive plays later footage).
    var resolveSlip: (CMTime) -> TimelineClip?
    var onSlip: (CMTime) -> Bool
    /// Hears each slip draft, then nil when the drag ends (with whether the
    /// slip is being committed).
    var onSlipDraft: (TimelineClip?, Bool) -> Void
    /// The snap target near a timeline time, if snapping is on.
    var snapTime: (CMTime) -> CMTime?
    /// Where a moved clip starting at a time and lasting a duration snaps
    /// to, by whichever end is nearer a target, and that target.
    var snapSpan: (CMTime, CMTime) -> (start: CMTime, target: CMTime)?
    var onSnapIndicator: (CMTime?) -> Void
    /// Sets a transition's length, from dragging its inner side.
    var onSetTransitionDuration: (TransitionEdge, CMTime) -> Void
    var onAddEffect: (EffectKind) -> Void
    var onApplyPreset: (String) -> Void
    var onPasteEffects: () -> Void
    var onClipboard: (ClipboardCommand) -> Void
    /// An Option-drag: a copy goes where the drag would have moved the
    /// clip (its start, and the layer if another, or a new layer's kind).
    var onCopy: (CMTime, UUID?, LayerKind?) -> Void
    /// Files from the Finder dropped on the clip go onto its layer there.
    var onDropFiles: ([URL], CMTime) -> Void
    /// A generator (text or a shape) from the browser dropped on a clip
    /// that isn't one, and the time it lands at: it makes a clip of its
    /// own on a new layer above, since it can't go into this clip.
    var onDropGenerator: (EffectKind, CMTime) -> Void
    var onSetPassThrough: (Bool) -> Void
    var onEditTime: ((inout ClipTime) -> Void) -> Void
    var onEditClip: ((inout TimelineClip) -> Void) -> Void
    /// Sets how far down an adjustment clip reaches: to a layer, or every
    /// layer below for nil.
    var onSetReach: (UUID?) -> Void = { _ in }
    /// Opens the beat match panel for the clip's song; nil for clips that
    /// aren't on a Music layer.
    var onBeatMatch: (() -> Void)?
    /// Removes the song's beat map; nil unless the clip's song has one.
    var onRemoveBeats: (() -> Void)?
    /// Ties the clip to the music at the playhead; nil for clips on a Music
    /// layer, which are the music.
    var onAttachToMusic: (() -> Void)?
    /// Ties the frame playing at a timeline time inside the clip to the
    /// music there, from dragging its music point; nil where
    /// `onAttachToMusic` is.
    var onSetMusicPoint: ((CMTime) -> Void)?
    /// Opens the motion designer on the clip, or on the clips picked with
    /// it; nil for songs and clips that play backwards.
    var onMotionDesign: (() -> Void)?
    /// Gives the timeline the clip's frame size, frame rate and colour
    /// space; nil for clips without pictures of their own.
    var onConformTimeline: (() -> Void)?

    /// Which of the optional actions are there. They change what the block
    /// draws and offers (its menu, its music point, its VoiceOver actions),
    /// so `ClipBlockView.==` compares this along with the model.
    struct Offered: Equatable {
        var openNested: Bool
        var beatMatch: Bool
        var removeBeats: Bool
        var attachToMusic: Bool
        var setMusicPoint: Bool
        var motionDesign: Bool
        var conformTimeline: Bool
    }

    var offered: Offered {
        Offered(
            openNested: onOpenNested != nil, beatMatch: onBeatMatch != nil, removeBeats: onRemoveBeats != nil,
            attachToMusic: onAttachToMusic != nil, setMusicPoint: onSetMusicPoint != nil,
            motionDesign: onMotionDesign != nil, conformTimeline: onConformTimeline != nil
        )
    }
}

/// A clip block's handlers in a box that stays the same for the clip's
/// life in its row: the row puts the handlers it has just made in it each
/// time it is drawn, and the block reads them from it when a gesture or
/// menu item runs, so a block that wasn't drawn again still acts with the
/// row's latest closures. Writing it doesn't redraw anything.
@MainActor
final class LiveClipHandlers {
    var current: ClipBlockHandlers

    init(_ handlers: ClipBlockHandlers) {
        current = handlers
    }
}

/// A row's `LiveClipHandlers`, by clip.
@MainActor
final class LiveClipHandlerStore {
    private var boxes: [UUID: LiveClipHandlers] = [:]

    /// The clip's box, holding `handlers` from now on.
    func box(for clipID: UUID, holding handlers: ClipBlockHandlers) -> LiveClipHandlers {
        if let box = boxes[clipID] {
            box.current = handlers
            return box
        }
        let box = LiveClipHandlers(handlers)
        boxes[clipID] = box
        return box
    }

    /// Lets go of the boxes of clips no longer on the row.
    func keep(only clipIDs: Set<UUID>) {
        boxes = boxes.filter { clipIDs.contains($0.key) }
    }
}
