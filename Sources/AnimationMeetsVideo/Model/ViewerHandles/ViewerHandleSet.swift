import CoreGraphics
import CoreMedia
import Foundation

// The framework the viewer's handles are built on (see
// docs/viewer-handles.md, "The framework"). A handle set turns the clip
// selected in the timeline into handles, and a drag or a key press on one
// into an edit of the clip. It is plain logic: the canvas
// (`ViewerCanvas`) draws what it says, finds what is under the pointer,
// and runs every drag the same way.

/// What the canvas gives a handle set: the clip as it was when the drag
/// began (or as it is now, when drawing), and where and when.
struct HandleContext {
    var clip: TimelineClip
    /// The playhead in the clip's source time, where edits land.
    var sourceTime: CMTime
    var frameSize: CGSize
    /// The clip's picture before its stack, in the frame's pixels (origin
    /// top left, y down): its bounding box (`TransformHandles.pictureRect`).
    var pictureRect: CGRect
    /// The effect picked in the effects panel, if any.
    var selectedEffectID: UUID?
    /// Show Up to Here: the effect the viewer shows the clip up to, which
    /// cuts the stack short for the handles too.
    var shownUpTo: UUID?
    /// Frame pixels per view point at the viewer's zoom, for sizes and
    /// distances given in points.
    var pixelsPerPoint: Double = 1
    /// The Transform effect a drag adds when the clip has none on, made
    /// once when the drag begins (`TransformHandles.newTransform`), so
    /// every step of the drag inserts the same effect.
    var newTransform: Effect?
    /// Whether a tool has locked the clip (`ProjectState.lockedClipIDs`):
    /// its box is drawn, its handles aren't.
    var isLocked = false

    var center: CGPoint { CGPoint(x: frameSize.width / 2, y: frameSize.height / 2) }

    /// A distance in view points as frame pixels.
    func pixels(_ points: Double) -> Double { points * pixelsPerPoint }
}

/// The nine places on a clip's box, in its own terms (before the stack
/// turns it): the corners, the middles of the edges, and the center.
enum BoxPoint: Int, CaseIterable, Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, center

    /// Where it is on the box, 0...1 across and down.
    var unit: (x: Double, y: Double) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .right: (1, 0.5)
        case .bottomRight: (1, 1)
        case .bottom: (0.5, 1)
        case .bottomLeft: (0, 1)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        }
    }

    var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomRight || self == .bottomLeft }
    var isEdge: Bool { self == .top || self == .right || self == .bottom || self == .left }

    /// The eight a scale handle sits on, clockwise from the top left.
    static let rim: [BoxPoint] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    /// For an edge's middle: the one Scale number it changes, 0 for width
    /// (left and right), 1 for height (top and bottom).
    var axis: Int? {
        switch self {
        case .left, .right: 0
        case .top, .bottom: 1
        default: nil
        }
    }

    var name: String {
        switch self {
        case .topLeft: "Top Left Corner"
        case .top: "Top Edge"
        case .topRight: "Top Right Corner"
        case .right: "Right Edge"
        case .bottomRight: "Bottom Right Corner"
        case .bottom: "Bottom Edge"
        case .bottomLeft: "Bottom Left Corner"
        case .left: "Left Edge"
        case .center: "Center"
        }
    }

    /// The short name the anchor's readout gives a point it caught on.
    var shortName: String {
        switch self {
        case .topLeft: "Top Left"
        case .top: "Top"
        case .topRight: "Top Right"
        case .right: "Right"
        case .bottomRight: "Bottom Right"
        case .bottom: "Bottom"
        case .bottomLeft: "Bottom Left"
        case .left: "Left"
        case .center: "Center"
        }
    }

    /// The point in `rect`.
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * unit.x, y: rect.minY + rect.height * unit.y)
    }
}

/// A handle, by what it does. Stable through a drag and from frame to
/// frame.
enum HandleID: Hashable, Sendable {
    /// The inside of the box: moves the clip.
    case move
    case scale(BoxPoint)
    /// The zone just outside a scale handle.
    case rotate(BoxPoint)
    case anchor
    /// The chip in the well's corner, dragged sideways.
    case opacity
    /// A later set's handle (a point control, a vertex), by its own name.
    case named(String)
}

/// How a handle is drawn.
enum HandleGlyph: Equatable, Sendable {
    /// A square turned with the box: a scale handle.
    case square
    case round
    /// A square turned on its corner: a handle an effect package declares.
    case diamond
    case crosshair
    /// Not drawn: a zone (a rotation zone).
    case none
}

/// The pointer over a handle. Angles are in radians on screen, y down,
/// 0 pointing right.
enum HandleCursor: Equatable, Sendable {
    /// A two-headed resize arrow along `angle`.
    case resize(angle: Double)
    /// A curved two-headed arrow, turned to `angle`.
    case rotate(angle: Double)
    case move
    case crosshair
    /// Left and right: a value dragged sideways.
    case slide
    /// The handle can't be dragged.
    case notAllowed
}

/// What a press on a handle gives instead of a drag.
enum HandleRefusal: Equatable, Sendable {
    /// The clip is locked by a tool.
    case locked
    /// A Keyframing effect drives the control the handle writes: the
    /// effect's ID, and the control's.
    case driven(keyframingEffectID: UUID, effectID: UUID, controlID: UUID)
}

/// A ring round a handle, in view points, that is the handle too, except
/// where it lies inside `excluding` (frame pixels): the zone outside a
/// scale handle that turns the clip.
struct HandleZone: Equatable, Sendable {
    var inner: Double
    var outer: Double
    var excluding: [CGPoint] = []
}

struct ViewerHandle: Identifiable, Equatable {
    var id: HandleID
    /// Frame pixels, origin top left.
    var place: CGPoint
    var glyph: HandleGlyph
    /// For a square: how far it is turned with the box, in radians.
    var angle: Double = 0
    var cursor: HandleCursor
    /// How near a press must be to take the handle, in view points; a
    /// handle with a zone is hit in its zone instead.
    var reach: Double = 6
    var zone: HandleZone?
    /// False: drawn dimmed, and a press does nothing (no lever to pull
    /// on), or gives `refusal`.
    var isEnabled = true
    var refusal: HandleRefusal?
    /// "Scale", "Top Left Corner", "Center".
    var name: String
    /// "150%", read by VoiceOver and the readout.
    var value: String
    /// Shown by the pointer while it rests on the handle: the anchor's.
    var hoverText: String?
    /// Lights up while the pointer rests on a handle that works about it:
    /// the crosshair, for the scale handles and the rotation zones.
    var isPivot = false
}

/// A line drawn with the handles: a box, a path, a guide. In frame pixels.
struct ViewerOutline: Equatable {
    enum Style: Equatable {
        /// The clip's box: the accent over a dark line.
        case box
        /// A thin line, as the lever from the anchor to the pointer.
        case guide
    }

    var points: [CGPoint]
    var isClosed: Bool
    var style: Style
}

/// A drag on a handle so far. `start` and `now` are in frame pixels;
/// `swept` is the angle the pointer has turned round the handle's pivot
/// since the press, added up as it goes (`move(to:about:holdingWithin:)`),
/// so it runs past a full turn.
struct HandleDrag: Equatable {
    var handle: HandleID
    var start: CGPoint
    var now: CGPoint
    var shift = false
    var option = false
    /// The drag is in the loupe (`FineDrag`), which slows the pointer
    /// itself: values go in their finest steps (tenths of a pixel for the
    /// anchor and a point), and the anchor doesn't catch.
    var fine = false
    private(set) var swept = 0.0
    /// The last point the sweep was measured from; nil while the pointer
    /// is too near the pivot to say which way it points.
    private var previous: CGPoint?

    init(handle: HandleID, start: CGPoint, shift: Bool = false, option: Bool = false) {
        self.handle = handle
        self.start = start
        now = start
        previous = start
        self.shift = shift
        self.option = option
    }

    /// The pointer moved to `point`. About `pivot`, the sweep grows by the
    /// angle turned, except within `radius` of it, where it holds until the
    /// pointer leaves again.
    mutating func move(to point: CGPoint, about pivot: CGPoint?, holdingWithin radius: Double) {
        now = point
        guard let pivot else { return }
        let distance = Double(hypot(point.x - pivot.x, point.y - pivot.y))
        guard distance > radius else {
            previous = nil
            return
        }
        if let previous {
            let a = atan2(previous.y - pivot.y, previous.x - pivot.x)
            let b = atan2(point.y - pivot.y, point.x - pivot.x)
            var turn = b - a
            if turn > .pi { turn -= 2 * .pi }
            if turn < -.pi { turn += 2 * .pi }
            swept += Double(turn)
        }
        previous = point
    }

    /// How far the pointer has moved since the press.
    var delta: CGVector { CGVector(dx: now.x - start.x, dy: now.y - start.y) }
}

/// An arrow key's direction.
enum NudgeDirection: Sendable {
    case left, right, up, down
}

/// How far an arrow key moves a value: its step, ten with Shift, a tenth
/// with Option.
enum NudgeStep: Sendable {
    case normal, large, fine

    var multiplier: Double {
        switch self {
        case .normal: 1
        case .large: 10
        case .fine: 0.1
        }
    }
}

/// What a drag or a key press does to the clip.
struct HandleEdit {
    /// Makes the change to the clip from before the drag.
    var change: (inout TimelineClip) -> Void
    /// The value reached, as the readout says it.
    var readout: String
    /// The undo step's name: "Move", "Scale", "Rotate", "Move Anchor
    /// Point", "Change Opacity".
    var actionName: String

    /// `clip` with the change made.
    func applied(to clip: TimelineClip) -> TimelineClip {
        var edited = clip
        change(&edited)
        return edited
    }
}

extension TimelineClip {
    /// What an edit of this clip into `edited` changes that the effects
    /// panel shows a row for: the IDs of the effects it has before and
    /// after and changes, and its own ID when its anchor point changes.
    /// An effect the edit adds has no row yet, so it isn't one of them.
    func partsChanged(to edited: TimelineClip) -> Set<UUID> {
        var parts: Set<UUID> = []
        for effect in edited.effects where self.effect(id: effect.id).map({ $0 != effect }) ?? false {
            parts.insert(effect.id)
        }
        if anchorPoint != edited.anchorPoint { parts.insert(id) }
        return parts
    }
}

/// One value the arrow keys and VoiceOver change, one of what Tab picks:
/// "Position", "Center".
struct HandleKeyTarget {
    /// The handle whose nudge changes it.
    var handle: HandleID
    var name: String
    /// As the readout says it: "120, −40".
    var value: String
    /// Its parts as VoiceOver's adjustable elements: Position X and Y.
    var axes: [HandleAxis]
    /// More of VoiceOver's actions on each of its elements: the anchor's
    /// moves to the box's points.
    var actions: [HandleAction] = []
}

/// One part of a key target, as VoiceOver adjusts it.
struct HandleAxis {
    /// "Position X".
    var name: String
    /// "120 pixels".
    var value: String
    /// The arrows that make it bigger and smaller.
    var increment: NudgeDirection
    var decrement: NudgeDirection
    /// The names of the ten-fold steps: "Move 10 pixels right", "Move 10
    /// pixels left".
    var larger: (increment: String, decrement: String)
}

/// A named edit VoiceOver offers.
struct HandleAction {
    var name: String
    var edit: (HandleContext) -> HandleEdit?
}

/// Something the canvas draws handles for.
protocol ViewerHandleSet {
    /// The handles at the playhead, in the order a press is given to them:
    /// the first one hit takes it.
    func handles(_ context: HandleContext) -> [ViewerHandle]
    /// Lines drawn with the handles: a box, a path, a guide.
    func outlines(_ context: HandleContext) -> [ViewerOutline]
    /// A handle with an area rather than a spot (the inside of the box),
    /// for a press that hit no handle.
    func area(at point: CGPoint, _ context: HandleContext) -> HandleID?
    /// The point a handle's drag turns about, if it turns (the anchor, for
    /// a rotation zone), in frame pixels.
    func pivot(of handle: HandleID, _ context: HandleContext) -> CGPoint?
    /// The clip after the drag so far, worked out from the clip in
    /// `context`, which is the clip from before the drag; nil when the
    /// drag has changed nothing yet.
    func edit(_ drag: HandleDrag, _ context: HandleContext) -> HandleEdit?
    /// The same for one press of an arrow key.
    func nudge(_ handle: HandleID, _ direction: NudgeDirection, step: NudgeStep, _ context: HandleContext) -> HandleEdit?
    /// What the arrows can pick with Tab, in order.
    func keyTargets(_ context: HandleContext) -> [HandleKeyTarget]
    /// What a handle changes, back at its default: VoiceOver's Reset.
    func reset(_ handle: HandleID, _ context: HandleContext) -> HandleEdit?
    /// Why a press on `handle` can't drag it, beyond the clip being
    /// locked: a Keyframing effect drives what it writes.
    func refusal(for handle: HandleID, _ context: HandleContext) -> HandleRefusal?
}

/// Finding the handle under the pointer, in view points.
enum HandleHitTest {
    /// The first of `handles` a press at `point` (view points) lands on.
    /// `toView` maps frame pixels to view points.
    static func handle(at point: CGPoint, in handles: [ViewerHandle], toView: (CGPoint) -> CGPoint) -> ViewerHandle? {
        handles.first { hits($0, point, toView: toView) }
    }

    static func hits(_ handle: ViewerHandle, _ point: CGPoint, toView: (CGPoint) -> CGPoint) -> Bool {
        let place = toView(handle.place)
        let distance = Double(hypot(point.x - place.x, point.y - place.y))
        guard let zone = handle.zone else { return distance <= handle.reach }
        guard distance > zone.inner, distance <= zone.outer else { return false }
        return !contains(zone.excluding.map(toView), point)
    }

    /// Whether `point` is inside the polygon `corners` (any winding).
    static func contains(_ corners: [CGPoint], _ point: CGPoint) -> Bool {
        guard corners.count >= 3 else { return false }
        var inside = false
        var j = corners.count - 1
        for i in corners.indices {
            let a = corners[i], b = corners[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

/// Numbers as the handles' readouts and VoiceOver say them.
enum HandleFormat {
    /// `value` to at most `digits` places, with a real minus sign.
    static func number(_ value: Double, digits: Int = 1) -> String {
        let scale = pow(10, Double(digits))
        var rounded = (value * scale).rounded() / scale
        if rounded == 0 { rounded = 0 }
        var text = String(format: "%.\(digits)f", rounded)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text.replacingOccurrences(of: "-", with: "\u{2212}")
    }

    static func pair(_ x: Double, _ y: Double, digits: Int = 1) -> String {
        "\(number(x, digits: digits)), \(number(y, digits: digits))"
    }

    static func percent(_ value: Double, digits: Int = 1) -> String {
        number(value, digits: digits) + "%"
    }

    /// Scale: "150%", or "150% × 120%" when its numbers are apart.
    static func scale(_ values: [Double]) -> String {
        guard values.count == 2 else { return values.first.map { percent($0) } ?? "" }
        let x = (values[0] * 10).rounded(), y = (values[1] * 10).rounded()
        return x == y ? percent(values[0]) : "\(percent(values[0])) \u{00D7} \(percent(values[1]))"
    }

    /// Rotation, always to a tenth: "37.5°".
    static func degrees(_ value: Double) -> String {
        let text = String(format: "%.1f", (value * 10).rounded() / 10 == 0 ? 0 : value)
        return text.replacingOccurrences(of: "-", with: "\u{2212}") + "\u{00B0}"
    }
}
