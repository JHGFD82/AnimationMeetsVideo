import AppKit
import CoreMedia
import SwiftUI

/// The handles over the clip selected in the timeline, drawn on the viewer's
/// canvas (see docs/viewer-handles.md). With Show Handles on they show
/// while the viewer shows the timeline at the playhead, paused, and the
/// clip is in the picture there; playing, skimming or a trim preview hides
/// them.
///
/// Every drag runs the same way, whatever handle set it is on: nothing
/// happens until the pointer has moved 3 points; each step is worked out
/// from the clip as it was when the drag began and held to one side of the
/// project (`ProjectState.hold`), the handles drawn from the drag's own
/// copy of the clip; Shift and Option are read as they change; Escape puts
/// everything back; letting go writes it as one undo step.
///
/// A click gives the canvas the keys: Tab picks what the arrows change,
/// and the arrows nudge it. VoiceOver reaches each value as an adjustable
/// element with the same steps.
struct ViewerHandlesOverlay: View {
    let source: ViewerHandlesSource
    let mapping: ViewerMapping
    /// The parked playhead, in the timeline's time.
    let time: CMTime
    let playback: PlaybackModel
    let framing: ViewerFraming
    /// The viewer shows something other than the timeline at the playhead:
    /// a clip skimmed in the browser, or a trim preview.
    let showsOtherPicture: Bool

    @AppStorage(Preferences.viewerHandles) private var showsHandles = false
    @Environment(ProjectState.self) private var projectState: ProjectState?
    @Environment(\.projectHistory) private var history
    @Environment(ActivePanel.self) private var activePanel: ActivePanel?
    /// Footage's and stills' sizes as shown, read from their files.
    @State private var pictureSizes: [UUID: CGSize] = [:]
    @State private var book = HandleDragBook()
    @State private var hovered: HandleID?
    /// Where the pointer rests on the anchor, for its hover text.
    @State private var anchorHover: CGPoint?
    @FocusState private var isFocused: Bool

    /// The keys the canvas takes while it has the keyboard and handles
    /// show, which the panels' shortcuts leave to it (`claimsKeys`).
    private static let keys: Set<KeyEquivalent> = [.tab, .leftArrow, .rightArrow, .upArrow, .downArrow, .escape]
    private static let coordinates = "viewerHandles"
    /// How far the pointer moves before a press becomes a drag, in points.
    private static let slop = 3.0

    /// What the handles are drawn for at this moment.
    private struct Shown {
        /// The clip as drawn: the drag's while one is held.
        var clip: TimelineClip
        /// The clip as the project has it.
        var original: TimelineClip
        var context: HandleContext
        var sets: [any ViewerHandleSet]
        var name: String

        /// The context with the project's clip, which edits start from.
        var editing: HandleContext {
            var editing = self.context
            editing.clip = original
            return editing
        }
    }

    var body: some View {
        let shown = resolve()
        let list = shown.map { handles($0) } ?? []
        ZStack(alignment: .topLeading) {
            if let shown {
                Canvas { context, _ in draw(shown, list, in: &context) }
                    .decorative()
                readouts(shown, list)
                chips(shown)
                accessibilityElements(shown)
            }
        }
        .frame(width: mapping.wellSize.width, height: mapping.wellSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .coordinateSpace(name: Self.coordinates)
        .allowsHitTesting(shown != nil)
        .gesture(dragGesture(shown, forcing: nil))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in doubleClick(at: tap.location, shown) })
        .onContinuousHover { phase in hover(phase, shown, list) }
        .focusable(shown != nil)
        .focusEffectDisabled()
        .focused($isFocused)
        .claimsKeys(Self.keys, while: $isFocused)
        .onKeyPress(keys: Self.keys) { press in handleKey(press, shown) }
        .background(KeyPressMonitor { toggleKey($0) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shown.map { "Handles of \($0.name)" } ?? "")
        .accessibilityHidden(shown == nil)
        .accessibilityScrollAction { edge in framing.scrollHalfAWell(edge) }
        .task(id: mediaToMeasure) { await measure() }
        .onChange(of: shown == nil) { _, hidden in
            // Playing, another selection, or Show Handles off: a drag ends
            // as letting go would, and the keys go back.
            if hidden {
                finishDrag()
                isFocused = false
            }
        }
        .onChange(of: playback.isPlaying) { _, playing in if playing { finishDrag() } }
        .onDisappear { finishDrag() }
    }

    // MARK: What shows

    private var project: EditingProject { source.project.wrappedValue }

    /// The clip handles show for, or nil when none do.
    private func resolve() -> Shown? {
        guard showsHandles, !playback.isPlaying, playback.skimTime == nil, !playback.isTapeScrubbing, !showsOtherPicture,
              let selection = source.selection, selection.timelineID == source.timelineID, selection.transitionEdge == nil,
              let timeline = project.timeline(id: source.timelineID),
              let found = project.clipAndLayer(selection.timelineClipID, in: source.timelineID),
              found.clip.enabled, time >= found.clip.startOffset, time < found.clip.endOffset
        else { return nil }
        let original = found.clip, layer = found.layer
        let sets = ViewerHandleSets.active(for: original, on: layer, in: project)
        guard !sets.isEmpty else { return nil }
        let drawn = source.state.drag.flatMap { $0.clipID == original.id ? $0.clip : nil } ?? original
        let sourceTime = original.sourceTime(atTimelineTime: time)
        var pictureSize: CGSize?
        if case .media(let id) = original.source { pictureSize = pictureSizes[id] }
        let showing = source.effectsState.showUpTo
        let context = HandleContext(
            clip: drawn, sourceTime: sourceTime, frameSize: timeline.frameSize,
            pictureRect: TransformHandles.pictureRect(
                of: drawn, in: project, frameSize: timeline.frameSize, pictureSize: pictureSize, at: sourceTime
            ),
            selectedEffectID: source.effectsState.selectedEffectID,
            shownUpTo: showing?.clipID == original.id ? showing?.effectID : nil,
            pixelsPerPoint: mapping.pixelsPerPoint,
            isLocked: projectState?.lockedClipIDs.contains(original.id) ?? false
        )
        return Shown(clip: drawn, original: original, context: context, sets: sets, name: project.clipName(original.id, in: source.timelineID))
    }

    /// Every set's handles, in the order a press is given to them: the last
    /// set drawn is asked first.
    private func handles(_ shown: Shown) -> [ViewerHandle] {
        shown.sets.reversed().flatMap { $0.handles(shown.context) }
    }

    private var mediaToMeasure: UUID? {
        guard showsHandles, let selection = source.selection,
              let clip = project.clipAndLayer(selection.timelineClipID, in: source.timelineID)?.clip,
              case .media(let id) = clip.source
        else { return nil }
        return id
    }

    private func measure() async {
        guard let id = mediaToMeasure, pictureSizes[id] == nil, let media = project.mediaClip(id: id) else { return }
        if let size = await MediaFile.pictureSize(of: media) { pictureSizes[id] = size }
    }

    // MARK: Drawing

    private func draw(_ shown: Shown, _ list: [ViewerHandle], in context: inout GraphicsContext) {
        let drag = source.state.drag.flatMap { $0.clipID == shown.original.id ? $0 : nil }
        for set in shown.sets {
            for outline in set.outlines(shown.context) {
                var path = Path()
                path.addLines(outline.points.map(mapping.toView))
                if outline.isClosed { path.closeSubpath() }
                context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 3)
                context.stroke(path, with: .color(Design.accent), lineWidth: 1)
            }
        }
        guard !shown.context.isLocked else { return }
        let levered = drag.map { Self.worksAboutAnchor($0.handle) } ?? false
        // The lever: what a scale or a turn works about, in plain sight,
        // running off the edge toward an anchor out of view.
        // Its pointer is in the points of the display the drag is on; the
        // other display draws the clip moving, without it.
        if let drag, levered, book.began, let anchor = list.first(where: { $0.id == .anchor }) {
            var lever = Path()
            lever.move(to: mapping.toView(anchor.place))
            lever.addLine(to: drag.pointer)
            context.stroke(lever, with: .color(.black.opacity(0.35)), lineWidth: 3)
            context.stroke(lever, with: .color(.white.opacity(0.85)), lineWidth: 1)
        }
        let litPivot = levered || (drag == nil && hovered.map { id in list.contains { $0.id == id && $0.isPivot } } == true)
        for handle in list {
            // While dragging, only the crosshair stays, for a scale or a turn.
            if drag != nil, !(levered && handle.id == .anchor) { continue }
            let place = mapping.toView(handle.place)
            let alpha = handle.isEnabled ? 1.0 : 0.4
            switch handle.glyph {
            case .square:
                let side = TransformHandles.handleSize
                let square = Path(CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
                    .applying(CGAffineTransform(rotationAngle: handle.angle).concatenating(CGAffineTransform(translationX: place.x, y: place.y)))
                context.fill(square, with: .color(.white.opacity(alpha)))
                context.stroke(square, with: .color(Design.accent.opacity(alpha)), lineWidth: 1)
            case .round:
                let dot = Path(ellipseIn: CGRect(x: place.x - 4, y: place.y - 4, width: 8, height: 8))
                context.fill(dot, with: .color(.white.opacity(alpha)))
                context.stroke(dot, with: .color(Design.accent.opacity(alpha)), lineWidth: 1)
            case .crosshair:
                var cross = Path()
                cross.move(to: CGPoint(x: place.x - 5, y: place.y))
                cross.addLine(to: CGPoint(x: place.x + 5, y: place.y))
                cross.move(to: CGPoint(x: place.x, y: place.y - 5))
                cross.addLine(to: CGPoint(x: place.x, y: place.y + 5))
                let ring = Path(ellipseIn: CGRect(x: place.x - 3, y: place.y - 3, width: 6, height: 6))
                context.stroke(cross, with: .color(.black.opacity(0.5 * alpha)), lineWidth: 3)
                context.stroke(ring, with: .color(.black.opacity(0.5 * alpha)), lineWidth: 3)
                context.stroke(cross, with: .color(.white.opacity(alpha)), lineWidth: 1)
                context.stroke(ring, with: .color(.white.opacity(alpha)), lineWidth: 1)
                if litPivot {
                    let lit = Path(ellipseIn: CGRect(x: place.x - 8, y: place.y - 8, width: 16, height: 16))
                    context.stroke(lit, with: .color(Design.accent), lineWidth: 2)
                }
            case .none:
                break
            }
        }
    }

    private static func worksAboutAnchor(_ handle: HandleID) -> Bool {
        switch handle {
        case .scale, .rotate: true
        default: false
        }
    }

    /// The drag's readout by the pointer, and the anchor's position while
    /// the pointer rests on it.
    @ViewBuilder
    private func readouts(_ shown: Shown, _ list: [ViewerHandle]) -> some View {
        if let drag = source.state.drag, drag.clipID == shown.original.id, drag.handle != .opacity, book.began {
            readoutChip(drag.readout)
                .position(chipPlace(near: drag.pointer))
        } else if hovered == .anchor, let anchorHover, let text = list.first(where: { $0.id == .anchor })?.hoverText {
            readoutChip(text)
                .position(chipPlace(near: anchorHover))
        }
    }

    private func readoutChip(_ text: String) -> some View {
        Text(text)
            .font(Design.Typeface.numericSmall)
            .foregroundStyle(Design.textPrimary)
            .padding(.horizontal, Design.Space.close)
            .padding(.vertical, 3)
            .fixedSize()
            .beveledChip(fill: Design.Surface.overlay.color, radius: Design.Radius.control, strong: true)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
            .decorative()
    }

    /// Below and to the right of the pointer, kept in the well.
    private func chipPlace(near point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x + 60).clamped(between: 60, and: max(60, mapping.wellSize.width - 60)),
            y: (point.y + 26).clamped(between: 14, and: max(14, mapping.wellSize.height - 14))
        )
    }

    /// The opacity chip in the well's top left, and beside it, while the
    /// canvas has the keys, what the arrows change.
    private func chips(_ shown: Shown) -> some View {
        let reading = TransformHandles.reading(shown.context)
        // A fade dragged on either display shows here as it goes.
        let dragged = source.state.drag.flatMap { $0.clipID == shown.original.id && $0.handle == .opacity ? $0.readout : nil }
        return HStack(spacing: Design.Space.close) {
            HStack(spacing: Design.Space.tight) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(Design.Typeface.label)
                Text(dragged ?? TransformHandles.text(of: .opacity, reading))
                    .font(Design.Typeface.numericSmall)
            }
            .foregroundStyle(Design.textPrimary)
            .padding(.horizontal, Design.Space.close)
            .padding(.vertical, 3)
            .beveledChip(fill: Design.Surface.overlay.color, radius: Design.Radius.control, strong: true)
            .opacity(refusal(for: .opacity, shown) == nil ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { HandleCursors.cursor(for: refusal(for: .opacity, shown) == nil ? .slide : .notAllowed).set() }
            }
            .highPriorityGesture(dragGesture(shown, forcing: .opacity))
            .help("Drag left or right to fade the clip; Shift for ten at a time, Option for a tenth")
            .accessibilityHidden(true)
            if isFocused {
                Text("\(source.state.part.name) \(TransformHandles.text(of: source.state.part, reading))")
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textSecondary)
                    .padding(.horizontal, Design.Space.close)
                    .padding(.vertical, 3)
                    .beveledChip(fill: Design.Surface.overlay.color, radius: Design.Radius.control)
                    .decorative()
            }
        }
        .padding(Design.Space.group)
    }

    // MARK: Pointer

    /// The handle or area a press at `point` (view points) lands on.
    private func hit(_ point: CGPoint, _ shown: Shown, _ list: [ViewerHandle]) -> HandleID? {
        if let handle = HandleHitTest.handle(at: point, in: list, toView: mapping.toView) { return handle.id }
        let spot = mapping.toFrame(point)
        for set in shown.sets.reversed() {
            if let area = set.area(at: spot, shown.context) { return area }
        }
        return nil
    }

    private func hover(_ phase: HoverPhase, _ shown: Shown?, _ list: [ViewerHandle]) {
        switch phase {
        case .active(let location):
            guard let shown, source.state.drag == nil else { return }
            let id = hit(location, shown, list)
            if hovered != id { hovered = id }
            if id == .anchor { anchorHover = location } else if anchorHover != nil { anchorHover = nil }
            cursor(for: id, shown, list).set()
        case .ended:
            hovered = nil
            anchorHover = nil
            NSCursor.arrow.set()
        }
    }

    private func cursor(for id: HandleID?, _ shown: Shown, _ list: [ViewerHandle]) -> NSCursor {
        guard let id else { return .arrow }
        if refusal(for: id, shown) != nil { return HandleCursors.cursor(for: .notAllowed) }
        if let handle = list.first(where: { $0.id == id }) {
            return HandleCursors.cursor(for: handle.isEnabled ? handle.cursor : .notAllowed)
        }
        return HandleCursors.cursor(for: .move)
    }

    // MARK: Refusals

    /// Why a press on `handle` can't drag it, if it can't: the clip is
    /// locked, or a Keyframing effect drives the control it writes.
    private func refusal(for handle: HandleID, _ shown: Shown) -> HandleRefusal? {
        if shown.context.isLocked { return .locked }
        guard let kind = TransformHandles.Part(handle)?.control else { return nil }
        let context = shown.editing
        return TransformHandles.driver(of: kind, in: shown.original, at: TransformHandles.targetIndex(in: shown.original, context))
    }

    /// Gives the notice a refused press gets; returns whether it was
    /// refused.
    private func refuse(_ handle: HandleID, _ shown: Shown) -> Bool {
        guard let refusal = refusal(for: handle, shown) else { return false }
        guard let projectState else {
            NSSound.beep()
            return true
        }
        switch refusal {
        case .locked:
            projectState.onRefused(.lockedClip)
        case .driven(let keyframingID, let effectID, let controlID):
            let clip = shown.original
            projectState.onRefused(.drivenKeyframes(DrivenKeyframesEdit(
                timelineID: source.timelineID, clipID: clip.id, effectID: keyframingID,
                controlName: project.name(of: .control(effectID: effectID, controlID: controlID), in: clip),
                methodName: clip.effect(id: keyframingID)?.kind.name ?? "Keyframing"
            )))
        }
        return true
    }

    // MARK: Dragging

    private func dragGesture(_ shown: Shown?, forcing forced: HandleID?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinates))
            .onChanged { value in dragChanged(value, shown, forcing: forced) }
            .onEnded { _ in dragEnded() }
    }

    private func dragChanged(_ value: DragGesture.Value, _ shown: Shown?, forcing forced: HandleID?) {
        if !book.isPressed {
            guard let shown else { return }
            isFocused = true
            book.press(at: value.startLocation)
            let list = handles(shown)
            let id = forced ?? hit(value.startLocation, shown, list)
            book.handle = id
            book.shown = shown.editing
            book.sets = shown.sets
            if let id {
                if refuse(id, shown) || list.first(where: { $0.id == id })?.isEnabled == false { book.isDead = true }
            } else {
                // The arrow tool: a press on nothing does nothing.
                book.isDead = true
            }
        }
        guard !book.isDead, let id = book.handle else { return }
        if !book.began {
            let moved = hypot(value.location.x - book.startView.x, value.location.y - book.startView.y)
            guard Double(moved) >= Self.slop else { return }
            begin(id)
        }
        move(to: value.location)
    }

    private func begin(_ id: HandleID) {
        guard var context = book.shown else { return }
        context.newTransform = TransformHandles.newTransform(for: context.clip)
        book.shown = context
        book.began = true
        let flags = NSEvent.modifierFlags
        book.drag = HandleDrag(handle: id, start: mapping.toFrame(book.startView), shift: flags.contains(.shift), option: flags.contains(.option))
        history?.beginGesture()
        projectState?.beginHold()
        book.escape = DragEscape(onEscape: { cancelDrag() })
        book.watchModifiers { flags in modifiersChanged(flags) }
    }

    private func move(to location: CGPoint) {
        guard var drag = book.drag, let context = book.shown, let set = book.sets.first else { return }
        let pivot = set.pivot(of: drag.handle, context)
        drag.move(to: mapping.toFrame(location), about: pivot, holdingWithin: context.pixels(TransformHandles.leverMinimum))
        let flags = NSEvent.modifierFlags
        drag.shift = flags.contains(.shift)
        drag.option = flags.contains(.option)
        book.drag = drag
        book.pointer = location
        step()
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard book.began, var drag = book.drag else { return }
        let shift = flags.contains(.shift), option = flags.contains(.option)
        guard shift != drag.shift || option != drag.option else { return }
        drag.shift = shift
        drag.option = option
        book.drag = drag
        step()
    }

    /// The drag so far, worked out from the clip before it, held to one
    /// side of the project.
    private func step() {
        guard let drag = book.drag, let context = book.shown, let set = book.sets.first else { return }
        let start = context.clip
        let edit = set.edit(drag, context)
        let edited = edit?.applied(to: start) ?? start
        let readout = edit?.readout
            ?? TransformHandles.Part(drag.handle).map { TransformHandles.text(of: $0, TransformHandles.reading(context)) }
            ?? ""
        source.state.drag = ViewerCanvasState.Drag(handle: drag.handle, clipID: start.id, clip: edited, readout: readout, pointer: book.pointer)
        let binding = source.project, timelineID = source.timelineID
        let write = { binding.wrappedValue.editClip(start.id, in: timelineID) { $0 = edited } }
        if let projectState { projectState.hold(write) } else { write() }
    }

    private func dragEnded() {
        finishDrag()
        book.release()
    }

    /// The drag let go: its last step goes to the project, as one undo.
    private func finishDrag() {
        guard book.began, let start = book.shown?.clip else { return }
        let edited = source.state.drag?.clip ?? start
        book.endDrag()
        projectState?.endHold()
        // A drag let go (`ProjectState.letGo`) has written it already.
        if project.clipAndLayer(start.id, in: source.timelineID)?.clip != edited {
            source.project.wrappedValue.editClip(start.id, in: source.timelineID) { $0 = edited }
        }
        source.state.drag = nil
        let history = self.history
        Task { @MainActor in history?.endGesture() }
    }

    /// Escape: everything goes back as it was, a Transform the drag added
    /// included, and the rest of the press drags nothing.
    private func cancelDrag() {
        guard book.began, let start = book.shown?.clip else { return }
        book.endDrag()
        book.isDead = true
        projectState?.endHold()
        if project.clipAndLayer(start.id, in: source.timelineID)?.clip != start {
            source.project.wrappedValue.editClip(start.id, in: source.timelineID) { $0 = start }
        }
        source.state.drag = nil
        let history = self.history
        Task { @MainActor in history?.endGesture() }
    }

    /// A double-click on the crosshair puts the anchor back at the middle
    /// of the picture, keeping the picture still.
    private func doubleClick(at location: CGPoint, _ shown: Shown?) {
        guard let shown, hit(location, shown, handles(shown)) == .anchor, !refuse(.anchor, shown),
              let edit = TransformHandles.resetAnchor(shown.editing)
        else { return }
        apply(edit, shown)
    }

    // MARK: Keys

    private func handleKey(_ press: KeyPress, _ shown: Shown?) -> KeyPress.Result {
        guard let shown else { return .ignored }
        if press.key == .escape {
            // During a drag Escape is the drag's (`DragEscape`); otherwise
            // the keys go back to the timeline.
            isFocused = false
            return .handled
        }
        if press.key == .tab {
            let parts = TransformHandles.Part.allCases
            let current = parts.firstIndex(of: source.state.part)
            guard let next = TabStep.next(after: current, of: parts.count, back: press.modifiers.contains(.shift)) else { return .ignored }
            source.state.part = parts[next]
            return .handled
        }
        let direction: NudgeDirection
        switch press.key {
        case .leftArrow: direction = .left
        case .rightArrow: direction = .right
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        default: return .ignored
        }
        let step: NudgeStep = press.modifiers.contains(.shift) ? .large : press.modifiers.contains(.option) ? .fine : .normal
        nudge(source.state.part, direction, step, shown)
        return .handled
    }

    /// H shows or hides the handles while the viewer or the timeline has
    /// the keys (`KeyPressMonitor` leaves it alone while text is typed).
    private func toggleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option, .shift]),
              event.charactersIgnoringModifiers?.lowercased() == "h",
              activePanel.map({ $0.current == .viewer || $0.current == .timeline }) ?? true
        else { return false }
        showsHandles.toggle()
        return true
    }

    /// One press of an arrow key, or a VoiceOver adjustment: an edit of its
    /// own, as a nudge on the tone graph is.
    private func nudge(_ part: TransformHandles.Part, _ direction: NudgeDirection, _ step: NudgeStep, _ shown: Shown) {
        guard book.drag == nil, !refuse(part.handle, shown),
              let edit = TransformHandles().nudge(part.handle, direction, step: step, shown.editing)
        else { return }
        apply(edit, shown)
    }

    private func reset(_ part: TransformHandles.Part, _ shown: Shown) {
        guard !refuse(part.handle, shown), let edit = TransformHandles.reset(part, shown.editing) else { return }
        apply(edit, shown)
    }

    private func moveAnchor(to point: BoxPoint, _ shown: Shown) {
        guard !refuse(.anchor, shown), let edit = TransformHandles.moveAnchor(to: point, shown.editing) else { return }
        apply(edit, shown)
    }

    private func apply(_ edit: HandleEdit, _ shown: Shown) {
        let edited = edit.applied(to: shown.original)
        guard edited != shown.original else { return }
        source.project.wrappedValue.editClip(shown.original.id, in: source.timelineID) { $0 = edited }
    }

    // MARK: VoiceOver

    /// Each thing a drag can change, as an adjustable element over the box:
    /// increment and decrement are the arrow keys' nudges, with named
    /// actions for the ten-fold steps and Reset.
    @ViewBuilder
    private func accessibilityElements(_ shown: Shown) -> some View {
        let reading = TransformHandles.reading(shown.context)
        let box = boxRect(shown)
        let position = reading.position.count == 2 ? reading.position : [0, 0]
        Group {
            element("Position X", "\(HandleFormat.number(position[0])) pixels", .position, up: .right, down: .left,
                    larger: ("Move 10 pixels right", "Move 10 pixels left"), shown)
            element("Position Y", "\(HandleFormat.number(position[1])) pixels", .position, up: .down, down: .up,
                    larger: ("Move 10 pixels down", "Move 10 pixels up"), shown)
            element("Scale", scaleValue(reading.scale), .scale, up: .up, down: .down,
                    larger: ("Scale up 10 percent", "Scale down 10 percent"), shown)
            element("Rotation", "\(HandleFormat.number(reading.rotation)) degrees", .rotation, up: .right, down: .left,
                    larger: ("Turn 15 degrees clockwise", "Turn 15 degrees counterclockwise"), shown)
            element("Anchor X", "\(HandleFormat.number(reading.anchor.x)) pixels", .anchor, up: .right, down: .left,
                    larger: ("Move 10 pixels right", "Move 10 pixels left"), shown)
            element("Anchor Y", "\(HandleFormat.number(reading.anchor.y)) pixels", .anchor, up: .down, down: .up,
                    larger: ("Move 10 pixels down", "Move 10 pixels up"), shown)
            element("Opacity", "\(HandleFormat.number(reading.opacity)) percent", .opacity, up: .up, down: .down,
                    larger: ("Increase 10 percent", "Decrease 10 percent"), shown)
        }
        .frame(width: max(box.width, 1), height: max(box.height, 1))
        .position(x: box.midX, y: box.midY)
    }

    private func scaleValue(_ scale: [Double]) -> String {
        guard scale.count == 2, (scale[0] * 10).rounded() != (scale[1] * 10).rounded() else {
            return "\(HandleFormat.number(scale.first ?? 100)) percent"
        }
        return "\(HandleFormat.number(scale[0])) by \(HandleFormat.number(scale[1])) percent"
    }

    private func element(
        _ label: String, _ value: String, _ part: TransformHandles.Part, up: NudgeDirection, down: NudgeDirection,
        larger: (String, String), _ shown: Shown
    ) -> some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(part, up, .normal, shown)
                case .decrement: nudge(part, down, .normal, shown)
                @unknown default: break
                }
            }
            .accessibilityActions {
                Button(larger.0) { nudge(part, up, .large, shown) }
                Button(larger.1) { nudge(part, down, .large, shown) }
                Button("Reset") { reset(part, shown) }
                if part == .anchor {
                    ForEach(BoxPoint.allCases, id: \.self) { point in
                        Button("Move to \(point.name)") { moveAnchor(to: point, shown) }
                    }
                }
            }
    }

    /// The box's bounds in the well, where VoiceOver's elements are.
    private func boxRect(_ shown: Shown) -> CGRect {
        let points = shown.sets.flatMap { $0.outlines(shown.context) }.flatMap(\.points).map(mapping.toView)
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for point in points.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect.intersection(CGRect(origin: .zero, size: mapping.wellSize))
    }
}

/// What a press on the canvas has led to so far: kept by reference, since
/// the gesture's steps, the modifier monitor and Escape all reach it.
@MainActor
private final class HandleDragBook {
    private(set) var isPressed = false
    var startView = CGPoint.zero
    var handle: HandleID?
    /// The context the press found, with the clip from before the drag.
    var shown: HandleContext?
    var sets: [any ViewerHandleSet] = []
    /// The press drags nothing: it hit nothing, was refused, or Escape
    /// cancelled it.
    var isDead = false
    var began = false
    var drag: HandleDrag?
    var pointer = CGPoint.zero
    var escape: DragEscape?
    private var monitor: Any?
    private var onFlags: ((NSEvent.ModifierFlags) -> Void)?

    func press(at point: CGPoint) {
        isPressed = true
        startView = point
        pointer = point
        isDead = false
        began = false
    }

    /// Calls `onChange` as Shift or Option is pressed or let go, with the
    /// pointer still.
    func watchModifiers(_ onChange: @escaping (NSEvent.ModifierFlags) -> Void) {
        stopWatching()
        onFlags = onChange
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self?.onFlags?(event.modifierFlags.intersection(.deviceIndependentFlagsMask)) }
            return event
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onFlags = nil
    }

    /// The drag is over; the press goes on until the button comes up.
    func endDrag() {
        escape?.end()
        escape = nil
        stopWatching()
        began = false
        drag = nil
        isDead = true
    }

    /// The button came up: ready for the next press.
    func release() {
        endDrag()
        isPressed = false
        isDead = false
        handle = nil
        shown = nil
        sets = []
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
