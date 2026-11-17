import AppKit
import CoreMedia
import SwiftUI

/// The pen on the viewer's canvas (see docs/pen-tool.md), in place of the
/// handles while it is picked. It draws the path it works on whatever Show
/// Handles says, and only where handles could show: the viewer paused on
/// the timeline's picture. Playing or skimming, it takes no presses and
/// draws nothing; the pen stays picked.
///
/// Each press runs as every drag on the canvas does: nothing is a drag
/// until the pointer has moved 3 points; each step is worked out from the
/// project as it was when the press began (`PenTool.step`) and held to one
/// side of it (`ProjectState.hold`); Shift and Option are read as they
/// change; Escape puts the press back; letting go writes it as one undo
/// step, named for what it did. So undo goes back one point.
///
/// Command makes the pen the arrow for as long as it is held, on the
/// path's points and tangents. Space held makes it a hand, which drags the
/// picture in the well and never plays; Space going down during a point's
/// drag moves that point instead.
struct PenOverlay: View {
    let source: ViewerHandlesSource
    let mapping: ViewerMapping
    /// The parked playhead, in the timeline's time.
    let time: CMTime
    let playback: PlaybackModel
    let framing: ViewerFraming
    let showsOtherPicture: Bool

    @AppStorage(Preferences.penColor) private var penColor = Preferences.defaultPenColor
    @Environment(ProjectState.self) private var projectState: ProjectState?
    @Environment(\.projectHistory) private var history
    @State private var book = PenPressBook()
    /// Where the pointer rests, in view points, for the next stretch's
    /// preview and the pointer's badge.
    @State private var pointer: CGPoint?
    /// Command is held: the pen is the arrow.
    @State private var commandDown = false
    /// Space is held with the button up: the pen is a hand.
    @State private var spaceDown = false
    /// A refusal's words, shown a moment in the well.
    @State private var notice: String?
    @FocusState private var isFocused: Bool

    /// The keys the pen takes while it has the keyboard.
    private static let keys: Set<KeyEquivalent> = [.return, .escape, .delete, .tab, .leftArrow, .rightArrow, .upArrow, .downArrow]
    private static let coordinates = "pen"
    /// How far the pointer moves before a press becomes a drag, in points.
    private static let slop = 3.0

    var body: some View {
        let live = isLive
        let shown = live ? current() : nil
        ZStack(alignment: .topLeading) {
            if live {
                Canvas { context, _ in draw(shown, in: &context) }
                    .decorative()
                chips(shown)
                if let shown { accessibilityElements(shown) }
            }
        }
        .frame(width: mapping.wellSize.width, height: mapping.wellSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .coordinateSpace(name: Self.coordinates)
        .allowsHitTesting(live)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinates))
                .onChanged { pressChanged($0) }
                .onEnded { pressEnded($0) }
        )
        .onContinuousHover { phase in hover(phase) }
        .focusable(live)
        .focusEffectDisabled()
        .focused($isFocused)
        .claimsKeys(Self.keys, while: $isFocused)
        .onKeyPress(keys: Self.keys) { press in key(press) }
        .background(KeyHoldMonitor(keyCode: 49, isActive: true, onDown: { spaceWentDown() }, onUp: { spaceCameUp() }))
        .background(FlagsMonitor { flags in flagsChanged(flags) })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pen")
        .accessibilityHint(isDrawing
            ? "Drawing a path. Return ends it, Escape cancels it."
            : "Add Point places a point at the middle of the frame, which the arrows then move; Return ends the path, Escape cancels it.")
        .accessibilityHidden(!live)
        .accessibilityActions {
            if isDrawing {
                Button("End Path") { endDraw() }
                Button("Cancel Path") { cancelDraw() }
            }
            Button("Add Point") { addPointAfterPicked() }
        }
        .onChange(of: live) { _, isLive in
            if !isLive {
                finishPress()
                isFocused = false
            }
        }
        .onDisappear {
            finishPress()
            NSCursor.arrow.set()
        }
        // The chip saying a Path or Path Mask waits for its path is read
        // once as it appears.
        .onChange(of: live ? waitingText(shown) : nil) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    // MARK: What shows

    private var project: EditingProject { source.project.wrappedValue }

    /// The project as drawn: with the press so far while one is held.
    private var drawnProject: EditingProject { projectState?.held ?? project }

    /// Paused on the timeline's picture, where handles could show.
    private var isLive: Bool {
        !playback.isPlaying && playback.skimTime == nil && !playback.isTapeScrubbing && !showsOtherPicture
            && project.timeline(id: source.timelineID) != nil
    }

    private var setting: PenTool.Setting {
        PenTool.Setting(
            timelineID: source.timelineID, time: time, selection: source.selection,
            selectedEffectID: source.effectsState.selectedEffectID, shownUpTo: source.effectsState.showUpTo?.effectID,
            locked: projectState?.lockedClipIDs ?? []
        )
    }

    private var isDrawing: Bool { PenTool.isDrawing(source.state.pen, in: drawnProject, setting) }

    /// The path the pen works on, as drawn.
    private func current() -> (target: PenTarget, located: PathHandles.Located)? {
        PenTool.current(source.state.pen, in: drawnProject, setting)
    }

    private var picked: Int? { PathHandles.Part(source.state.picked)?.vertex }

    // MARK: Drawing

    private func draw(_ shown: (target: PenTarget, located: PathHandles.Located)?, in context: inout GraphicsContext) {
        guard let shown else { return }
        let located = shown.located, path = located.path
        let color = PathDrawing.color(penColor)
        func view(_ point: CGPoint) -> CGPoint { mapping.toView(located.frame(point)) }
        if !path.isEmpty {
            var line = Path()
            line.move(to: view(path.vertices[0].point))
            for index in 0..<path.segmentCount {
                let (_, c1, c2, p3) = path.segment(index)
                if path.isStraight(index) {
                    line.addLine(to: view(p3))
                } else {
                    line.addCurve(to: view(p3), control1: view(c1), control2: view(c2))
                }
            }
            if path.closed { line.closeSubpath() }
            PathDrawing.line(line, color: color, in: &context)
        }
        // The next stretch, from the last point to the pointer, curved by
        // the last point's out tangent.
        if isDrawing, book.begun == nil, !spaceDown, !commandDown, let pointer, let last = path.vertices.last,
           hoverAction(at: pointer) == .place {
            var next = Path()
            next.move(to: view(last.point))
            if last.outTangent == .zero {
                next.addLine(to: pointer)
            } else {
                next.addCurve(to: pointer, control1: view(last.outHandle), control2: pointer)
            }
            PathDrawing.preview(next, color: color, in: &context)
        }
        let picked = picked ?? (isDrawing ? path.vertices.count - 1 : nil)
        for index in PathHandles.pointsShowingTangents(of: path, picked: picked) {
            let vertex = path.vertices[index]
            for tangent in [vertex.inTangent, vertex.outTangent] where tangent != .zero {
                var stick = Path()
                stick.move(to: view(vertex.point))
                stick.addLine(to: view(vertex.point + tangent))
                PathDrawing.tangentLine(stick, color: color, in: &context)
                PathDrawing.tangentEnd(at: view(vertex.point + tangent), color: color, in: &context)
            }
        }
        for index in path.vertices.indices {
            PathDrawing.vertex(at: view(path.vertices[index].point), picked: index == picked, color: color, in: &context)
        }
        if let pointer, book.begun == nil, !commandDown, hoverAction(at: pointer) == .close, let first = path.vertices.first {
            PathDrawing.closingRing(at: view(first.point), color: color, in: &context)
        }
    }

    /// The chip that says a Path or Path Mask waits for its path, and a
    /// refusal's words.
    @ViewBuilder
    private func chips(_ shown: (target: PenTarget, located: PathHandles.Located)?) -> some View {
        if let text = notice ?? waitingText(shown) {
            Text(text)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textPrimary)
                .padding(.horizontal, Design.Space.step)
                .padding(.vertical, Design.Space.tight)
                .beveledChip(fill: Design.Surface.overlay.color, radius: Design.Radius.control, strong: true)
                .frame(width: mapping.wellSize.width, alignment: .center)
                .padding(.top, Design.Space.group)
                .accessibilityHidden(true)
        }
    }

    /// What the chip says while the path the pen works on has no points.
    private func waitingText(_ shown: (target: PenTarget, located: PathHandles.Located)?) -> String? {
        guard let shown, shown.located.path.isEmpty else { return nil }
        return shown.located.effect.kind == .pathMask ? "Click in the viewer to draw the mask" : "Click in the viewer to draw the path"
    }

    /// Says `text` a moment in the well, and to VoiceOver.
    private func show(notice text: String) {
        notice = text
        AccessibilityNotification.Announcement(text).post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if notice == text { notice = nil }
        }
    }

    // MARK: Pointer

    /// What a press at `point` would do now.
    private func hoverAction(at point: CGPoint) -> PenTool.Action {
        let shown = current()
        let option = NSEvent.modifierFlags.contains(.option)
        let hit = PenTool.hit(point, on: shown?.located, picked: picked ?? lastIfDrawing(shown), tangents: option, toView: mapping.toView)
        return PenTool.action(for: hit, path: shown?.located.path, drawing: isDrawing, option: option)
    }

    private func lastIfDrawing(_ shown: (target: PenTarget, located: PathHandles.Located)?) -> Int? {
        isDrawing ? shown.map { $0.located.path.vertices.count - 1 } : nil
    }

    private func hover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            pointer = location
            guard book.begun == nil, book.arrow == nil else { return }
            setCursor(at: location)
        case .ended:
            pointer = nil
            NSCursor.arrow.set()
        }
    }

    private func setCursor(at location: CGPoint?) {
        if spaceDown {
            HandleCursors.cursor(for: book.hand != nil ? .closedHand : .hand).set()
            return
        }
        guard let location else { return }
        if commandDown {
            let over = arrowHandle(at: location) != nil
            (over ? HandleCursors.cursor(for: .move) : NSCursor.arrow).set()
            return
        }
        HandleCursors.cursor(for: hoverAction(at: location).cursor).set()
    }

    /// Command or Option went down or up: the pointer changes, and a press
    /// under way follows Shift and Option.
    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let command = flags.contains(.command)
        if command != commandDown { commandDown = command }
        if var stroke = book.stroke, book.begun != nil {
            stroke.shift = flags.contains(.shift)
            stroke.setOption(flags.contains(.option))
            book.stroke = stroke
            step()
        } else if book.arrow != nil {
            book.arrowShift = flags.contains(.shift)
            book.arrowOption = flags.contains(.option)
            arrowStep()
        } else {
            setCursor(at: pointer)
        }
    }

    // MARK: Space

    /// Space with the pen picked: during a point's drag it moves the
    /// point; otherwise it is the hand. Either way it never plays.
    private func spaceWentDown() -> Bool {
        guard isLive else { return false }
        if var stroke = book.stroke, book.begun != nil {
            stroke.setSpace(true)
            book.stroke = stroke
            return true
        }
        spaceDown = true
        setCursor(at: pointer)
        return true
    }

    private func spaceCameUp() {
        if var stroke = book.stroke, stroke.isSpaceDown {
            stroke.setSpace(false)
            book.stroke = stroke
            step()
        }
        if spaceDown {
            spaceDown = false
            book.hand = nil
            setCursor(at: pointer)
        }
    }

    // MARK: Pressing

    private func pressChanged(_ value: DragGesture.Value) {
        if !book.isPressed {
            book.isPressed = true
            isFocused = true
            pressBegan(at: value.startLocation)
        }
        if let last = book.hand {
            // The hand: the picture follows the pointer, as a scroll moves it.
            let delta = CGVector(dx: value.location.x - last.x, dy: value.location.y - last.y)
            framing.apply((framing.current ?? mapping).scrolled(by: delta))
            book.hand = value.location
            return
        }
        guard !book.isDead else { return }
        if book.arrow != nil {
            arrowMoved(to: value.location)
            return
        }
        guard var stroke = book.stroke, let begun = book.begun else { return }
        if !stroke.dragged {
            let moved = hypot(value.location.x - book.startView.x, value.location.y - book.startView.y)
            guard Double(moved) >= Self.slop else { return }
            stroke.dragged = true
            if stroke.option { stroke.setOption(true) }
        }
        guard let spot = begun.located.toPath(mapping.toFrame(value.location)) else { return }
        stroke.move(to: spot)
        book.stroke = stroke
        pointer = value.location
        step()
    }

    private func pressBegan(at location: CGPoint) {
        book.startView = location
        if spaceDown {
            book.hand = location
            HandleCursors.cursor(for: .closedHand).set()
            return
        }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            arrowBegan(at: location)
            return
        }
        let shown = current()
        let option = flags.contains(.option)
        let hit = PenTool.hit(location, on: shown?.located, picked: picked ?? lastIfDrawing(shown), tangents: option, toView: mapping.toView)
        let action = PenTool.action(for: hit, path: shown?.located.path, drawing: isDrawing, option: option)
        switch PenTool.begin(action, on: shown?.target, state: source.state.pen, in: project, setting) {
        case .failure(let refusal):
            refuse(refusal)
            book.isDead = true
        case .success(let begun):
            guard let spot = begun.located.toPath(mapping.toFrame(location)) else {
                book.isDead = true
                return
            }
            book.before = project
            book.begun = begun
            book.stroke = PenTool.Stroke(action: action, at: spot, shift: flags.contains(.shift), option: option)
            source.state.isPenPressed = true
            history?.beginGesture()
            projectState?.beginHold()
            book.escape = DragEscape(onEscape: { cancelPress() })
            step()
        }
    }

    /// The press so far, worked out from the project before it, held to
    /// one side.
    private func step() {
        guard let begun = book.begun, let stroke = book.stroke else { return }
        let outcome = PenTool.step(begun, stroke, setting)
        book.outcome = outcome
        let edited = outcome?.project ?? begun.project
        let binding = source.project
        if let projectState {
            projectState.hold { binding.wrappedValue = edited }
        } else {
            binding.wrappedValue = edited
        }
    }

    private func pressEnded(_ value: DragGesture.Value) {
        if book.arrow != nil {
            arrowEnded()
        } else {
            finishPress()
        }
        book.reset()
        setCursor(at: pointer)
    }

    /// The press let go: what it made goes to the project, as one undo step
    /// named for what it did, and the pen keeps what it now works on.
    private func finishPress() {
        guard let begun = book.begun else { return }
        let outcome = book.outcome
        book.escape?.end()
        book.escape = nil
        projectState?.endHold()
        source.state.isPenPressed = false
        if let outcome {
            if project != outcome.project { source.project.wrappedValue = outcome.project }
            source.state.pen = outcome.state
            if let picked = outcome.picked { source.state.picked = PathHandles.Part.vertex(picked).handle }
            if let made = outcome.made {
                source.state.select?(TimelineSelection(timelineID: source.timelineID, layerID: made.layerID, timelineClipID: made.clipID))
                source.effectsState.select(effect: made.effectID)
            } else if begun.starts {
                source.effectsState.select(effect: begun.target.effectID)
            }
            history?.nameNextStep(outcome.name)
        } else if project != book.before, let before = book.before {
            // Let go part way (`ProjectState.letGo`): back as it was.
            source.project.wrappedValue = before
        }
        book.begun = nil
        let history = self.history
        Task { @MainActor in history?.endGesture() }
    }

    /// Escape during a press: that point goes, and the rest of the press
    /// does nothing.
    private func cancelPress() {
        guard book.begun != nil else { return }
        projectState?.endHold()
        if let before = book.before, project != before { source.project.wrappedValue = before }
        book.begun = nil
        book.outcome = nil
        book.isDead = true
        source.state.isPenPressed = false
        let history = self.history
        Task { @MainActor in history?.endGesture() }
    }

    private func refuse(_ refusal: PenTool.Refusal) {
        switch refusal {
        case .nothingToMask:
            show(notice: refusal.message ?? "")
        case .locked:
            if let projectState { projectState.onRefused(.lockedClip) } else { NSSound.beep() }
        case .driven(.driven(let keyframingID, let effectID, let controlID)):
            guard let projectState, let clip = project.clipAndLayer(current()?.target.clipID ?? UUID(), in: source.timelineID)?.clip else {
                NSSound.beep()
                return
            }
            projectState.onRefused(.drivenKeyframes(DrivenKeyframesEdit(
                timelineID: source.timelineID, clipID: clip.id, effectID: keyframingID,
                controlName: project.name(of: .control(effectID: effectID, controlID: controlID), in: clip),
                methodName: clip.effect(id: keyframingID)?.kind.name ?? "Keyframing"
            )))
        case .driven:
            NSSound.beep()
        }
    }

    // MARK: Command: the arrow

    /// The path's handles under `location`, for the arrow Command makes of
    /// the pen.
    private func arrowHandle(at location: CGPoint) -> (handle: ViewerHandle, set: PathHandles, context: HandleContext)? {
        guard let shown = current(), let context = handleContext(shown.target) else { return nil }
        let set = PathHandles(effectID: shown.target.effectID)
        guard let handle = HandleHitTest.handle(at: location, in: set.handles(context), toView: mapping.toView) else { return nil }
        return (handle, set, context)
    }

    private func handleContext(_ target: PenTarget) -> HandleContext? {
        guard let timeline = project.timeline(id: source.timelineID),
              let clip = project.clipAndLayer(target.clipID, in: source.timelineID)?.clip
        else { return nil }
        return HandleContext(
            clip: clip, sourceTime: clip.sourceTime(atTimelineTime: time), frameSize: timeline.frameSize, pictureRect: .zero,
            selectedEffectID: target.effectID, shownUpTo: source.effectsState.showUpTo?.effectID,
            pixelsPerPoint: mapping.pixelsPerPoint,
            isLocked: projectState?.lockedClipIDs.contains(target.clipID) ?? false,
            picked: source.state.picked
        )
    }

    private func arrowBegan(at location: CGPoint) {
        let hit = arrowHandle(at: location)
        guard let found = hit, found.handle.isEnabled else {
            if let refusal = hit?.handle.refusal { refuse(.driven(refusal)) }
            book.isDead = true
            return
        }
        book.arrow = HandleDrag(handle: found.handle.id, start: mapping.toFrame(location))
        book.arrowSet = found.set
        book.arrowContext = found.context
        book.before = project
        if let part = PathHandles.Part(found.handle.id) { source.state.picked = PathHandles.Part.vertex(part.vertex).handle }
        source.state.isPenPressed = true
        history?.beginGesture()
        projectState?.beginHold()
        book.escape = DragEscape(onEscape: { cancelArrow() })
    }

    private func arrowMoved(to location: CGPoint) {
        guard var drag = book.arrow else { return }
        if !book.arrowBegan {
            guard hypot(location.x - book.startView.x, location.y - book.startView.y) >= Self.slop else { return }
            book.arrowBegan = true
        }
        drag.move(to: mapping.toFrame(location), about: nil, holdingWithin: 0)
        book.arrow = drag
        arrowStep()
    }

    private func arrowStep() {
        guard var drag = book.arrow, book.arrowBegan, let set = book.arrowSet, let context = book.arrowContext else { return }
        drag.shift = book.arrowShift
        drag.option = book.arrowOption
        let edited = set.edit(drag, context)?.applied(to: context.clip) ?? context.clip
        book.arrowEdited = edited
        let binding = source.project, timelineID = source.timelineID
        let write = { binding.wrappedValue.editClip(edited.id, in: timelineID) { $0 = edited } }
        if let projectState { projectState.hold(write) } else { write() }
    }

    private func arrowEnded() {
        guard book.arrow != nil else { return }
        book.escape?.end()
        book.escape = nil
        projectState?.endHold()
        source.state.isPenPressed = false
        if let edited = book.arrowEdited, project.clipAndLayer(edited.id, in: source.timelineID)?.clip != edited {
            source.project.wrappedValue.editClip(edited.id, in: source.timelineID) { $0 = edited }
            history?.nameNextStep("Move Point")
        }
        let history = self.history
        Task { @MainActor in history?.endGesture() }
    }

    private func cancelArrow() {
        projectState?.endHold()
        if let before = book.before, project != before { source.project.wrappedValue = before }
        book.arrow = nil
        book.arrowEdited = nil
        book.isDead = true
        source.state.isPenPressed = false
        let history = self.history
        Task { @MainActor in history?.endGesture() }
    }

    // MARK: Keys

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard isLive else { return .ignored }
        switch press.key {
        case .return:
            if press.modifiers.contains(.command) {
                addPointAfterPicked()
            } else if press.modifiers.contains(.option) {
                convertPicked()
            } else {
                endDraw()
            }
            return .handled
        case .escape:
            if isDrawing { cancelDraw() } else { source.state.pick(.arrow) }
            return .handled
        case .delete:
            removePicked()
            return .handled
        case .tab:
            guard let shown = current(), !shown.located.path.isEmpty else { return .ignored }
            let count = shown.located.path.vertices.count
            guard let next = TabStep.next(after: picked, of: count, back: press.modifiers.contains(.shift)) else { return .ignored }
            source.state.picked = PathHandles.Part.vertex(next).handle
            return .handled
        default:
            let direction: NudgeDirection
            switch press.key {
            case .leftArrow: direction = .left
            case .rightArrow: direction = .right
            case .upArrow: direction = .up
            default: direction = .down
            }
            let step: NudgeStep = press.modifiers.contains(.shift) ? .large : press.modifiers.contains(.option) ? .fine : .normal
            nudgePicked(direction, step)
            return .handled
        }
    }

    /// An edit of the project from a key or VoiceOver, as one undo step.
    private func apply(_ outcome: PenTool.Outcome?) {
        guard let outcome else { return }
        source.state.pen = outcome.state
        source.state.picked = outcome.picked.map { PathHandles.Part.vertex($0).handle } ?? source.state.picked
        guard outcome.project != project else { return }
        history?.nameNextStep(outcome.name)
        source.project.wrappedValue = outcome.project
        if let made = outcome.made {
            source.state.select?(TimelineSelection(timelineID: source.timelineID, layerID: made.layerID, timelineClipID: made.clipID))
            source.effectsState.select(effect: made.effectID)
        }
    }

    /// Return: ends the draw.
    private func endDraw() {
        apply(PenTool.end(source.state.pen, in: project, setting))
    }

    /// Escape while drawing: the draw goes, as one step of its own.
    private func cancelDraw() {
        apply(PenTool.cancel(source.state.pen, in: project, setting))
    }

    /// A clip edit of the path the pen works on, from `PathHandles`.
    private func applyHandleEdit(_ make: (PathHandles, HandleContext) -> HandleEdit?) {
        guard let shown = current(), let context = handleContext(shown.target) else { return }
        if let refusal = PathHandles.driver(of: shown.located, in: context.clip) {
            refuse(.driven(refusal))
            return
        }
        guard !context.isLocked else {
            refuse(.locked)
            return
        }
        guard let edit = make(PathHandles(effectID: shown.target.effectID), context) else { return }
        let edited = edit.applied(to: context.clip)
        guard edited != context.clip else { return }
        history?.nameNextStep(edit.actionName)
        source.project.wrappedValue.editClip(edited.id, in: source.timelineID) { $0 = edited }
    }

    /// The point the keys act on: the picked one, or while drawing the
    /// last.
    private func keyPoint() -> Int? {
        let shown = current()
        return picked.flatMap { index in shown.map { index < $0.located.path.vertices.count ? index : $0.located.path.vertices.count - 1 } }
            ?? lastIfDrawing(shown)
    }

    /// ⌘Return: a point halfway along the stretch after the picked one, or
    /// past the end of an open path; with no path yet, the first point, at
    /// the middle of the frame.
    private func addPointAfterPicked() {
        guard let shown = current(), !shown.located.path.isEmpty else {
            // The first point, at the middle of the frame.
            guard let timeline = project.timeline(id: source.timelineID) else { return }
            let middle = CGPoint(x: timeline.frameSize.width / 2, y: timeline.frameSize.height / 2)
            switch PenTool.begin(.place, on: current()?.target, state: source.state.pen, in: project, setting) {
            case .failure(let refusal):
                refuse(refusal)
            case .success(let begun):
                guard let spot = begun.located.toPath(middle) else { return }
                apply(PenTool.step(begun, PenTool.Stroke(action: .place, at: spot), setting))
            }
            return
        }
        let index = keyPoint() ?? shown.located.path.vertices.count - 1
        let target = shown.target
        applyHandleEdit { set, context in
            var clip = context.clip
            guard let e = clip.effects.index(of: target.effectID) else { return nil }
            clip.effects[e].changeControl(.path) { PathHandles.addingPoint(after: index, to: &$0) }
            return HandleEdit(change: { $0 = clip }, readout: "Add Point", actionName: "Add Point")
        }
        source.state.picked = PathHandles.Part.vertex(index + 1).handle
    }

    /// ⌥Return: the picked point between linear and ease.
    private func convertPicked() {
        guard let shown = current(), let index = keyPoint() else { return }
        let target = shown.target
        applyHandleEdit { _, context in
            var clip = context.clip
            guard let e = clip.effects.index(of: target.effectID) else { return nil }
            clip.effects[e].changeControl(.path) { PathHandles.converting(index, of: &$0, at: context.sourceTime) }
            return HandleEdit(change: { $0 = clip }, readout: "Convert Point", actionName: "Convert Point")
        }
    }

    /// ⌫: the picked point goes; while drawing, the last. A draw left with
    /// no points is cancelled.
    private func removePicked() {
        guard let shown = current(), let index = keyPoint() else { return }
        if isDrawing, shown.located.path.vertices.count <= 1 {
            cancelDraw()
            return
        }
        let target = shown.target
        applyHandleEdit { _, context in
            var clip = context.clip
            guard let e = clip.effects.index(of: target.effectID) else { return nil }
            clip.effects[e].changeControl(.path) { $0.mapPath { $0.remove(index) } }
            return HandleEdit(change: { $0 = clip }, readout: "Remove Point", actionName: "Remove Point")
        }
        let count = shown.located.path.vertices.count - 1
        source.state.picked = count > 0 ? PathHandles.Part.vertex(min(index, count - 1)).handle : .move
    }

    private func nudgePicked(_ direction: NudgeDirection, _ step: NudgeStep) {
        guard let index = keyPoint() else { return }
        applyHandleEdit { set, context in set.nudge(PathHandles.Part.vertex(index).handle, direction, step: step, context) }
    }

    // MARK: VoiceOver

    /// Each point as an adjustable element, across and down, with the
    /// pen's actions, from `PathHandles.keyTargets`.
    @ViewBuilder
    private func accessibilityElements(_ shown: (target: PenTarget, located: PathHandles.Located)) -> some View {
        if let context = handleContext(shown.target) {
            let set = PathHandles(effectID: shown.target.effectID)
            let targets = set.keyTargets(context)
            ZStack {
                ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                    ForEach(Array(target.axes.enumerated()), id: \.offset) { _, axis in
                        Color.clear
                            .accessibilityElement()
                            .accessibilityLabel("\(target.name), \(axis.name)")
                            .accessibilityValue(axis.value)
                            .accessibilityAdjustableAction { direction in
                                source.state.picked = target.handle
                                switch direction {
                                case .increment: nudgePicked(axis.increment, .normal)
                                case .decrement: nudgePicked(axis.decrement, .normal)
                                @unknown default: break
                                }
                            }
                            .accessibilityActions {
                                ForEach(Array(target.actions.enumerated()), id: \.offset) { _, action in
                                    Button(action.name) {
                                        source.state.picked = target.handle
                                        applyHandleEdit { _, context in action.edit(context) }
                                    }
                                }
                            }
                    }
                }
            }
            .frame(width: mapping.wellSize.width, height: mapping.wellSize.height)
        }
    }
}

/// What a press of the pen has led to so far: kept by reference, since the
/// gesture's steps, the key monitors and Escape all reach it.
@MainActor
private final class PenPressBook {
    var isPressed = false
    var startView = CGPoint.zero
    /// The project before the press, which Escape puts back.
    var before: EditingProject?
    var begun: PenTool.Begun?
    var stroke: PenTool.Stroke?
    var outcome: PenTool.Outcome?
    /// The press is the hand's: where the pointer was last.
    var hand: CGPoint?
    /// The press drags nothing: it was refused, or Escape cancelled it.
    var isDead = false
    var escape: DragEscape?
    /// Command's arrow: the drag on a point or tangent, its set and the
    /// context it started from.
    var arrow: HandleDrag?
    var arrowSet: PathHandles?
    var arrowContext: HandleContext?
    var arrowBegan = false
    var arrowShift = false
    var arrowOption = false
    var arrowEdited: TimelineClip?

    /// The button came up: ready for the next press.
    func reset() {
        escape?.end()
        escape = nil
        isPressed = false
        before = nil
        begun = nil
        stroke = nil
        outcome = nil
        hand = nil
        isDead = false
        arrow = nil
        arrowSet = nil
        arrowContext = nil
        arrowBegan = false
        arrowShift = false
        arrowOption = false
        arrowEdited = nil
    }

    isolated deinit {
        escape?.end()
    }
}

/// Calls `onChange` as a modifier key goes down or comes up in this view's
/// window.
private struct FlagsMonitor: NSViewRepresentable {
    let onChange: (NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stop()
    }

    final class MonitorView: NSView {
        var onChange: ((NSEvent.ModifierFlags) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return }
                    self.onChange?(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
