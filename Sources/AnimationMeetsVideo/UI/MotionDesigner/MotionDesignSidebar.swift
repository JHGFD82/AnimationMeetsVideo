import CoreMedia
import SwiftUI

/// The motion designer's sidebar: the frame under the playhead, what is
/// selected and its settings, what to do next, and Undo and Redo, Cancel
/// and Done.
struct MotionDesignSidebar: View {
    @Bindable var session: MotionDesignSession
    let onDone: () -> Void
    let onCancel: () -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.group) {
                    MotionDesignMonitor(session: session)
                    if session.pickedPointIDs.count > 1 {
                        pickedPointsControls(session.pickedPointIDs.count)
                    } else if let point = session.selectedPoint {
                        pointControls(point)
                    } else if let id = session.selectedPieceID, let piece = session.run.pieces.first(id: id) {
                        pieceControls(piece)
                    } else {
                        guidance
                    }
                    if let message = session.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Design.Space.rail)
            }
            .controlSize(.small)
            Groove()
            HStack(spacing: Design.Space.close) {
                // As in Beat Match's footer, by the ways out.
                HStack(spacing: 0) {
                    Button(action: session.undo) { Image(systemName: Design.Symbol.undo) }
                        .buttonStyle(.icon)
                        .disabled(!session.canUndo)
                        .help("\(session.undoTitle) (⌘Z)")
                        .accessibilityLabel(session.undoTitle)
                    Button(action: session.redo) { Image(systemName: Design.Symbol.redo) }
                        .buttonStyle(.icon)
                        .disabled(!session.canRedo)
                        .help("\(session.redoTitle) (⇧⌘Z)")
                        .accessibilityLabel(session.redoTitle)
                }
                Spacer(minLength: 0)
                // ⌘. rather than Escape, which lets go of a drag or the
                // selection, as in Beat Match.
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Put the clips back as they were and close (⌘.)")
                Button("Done", action: onDone)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accentFill)
                    .help("Keep the retiming and close (⌘Return)")
            }
            .padding(Design.Space.rail)
        }
        .background(Design.Surface.base.color)
    }

    // MARK: Nothing selected

    private var guidance: some View {
        VStack(alignment: .leading, spacing: Design.Space.close) {
            heading("Retime to the music")
            Text("Grab the line to put a marker on that frame, and drag it along the music. Click a marker to lock its frame to that moment; click again to unlock it.")
            Text("Give a marker Ease In, Ease Out or Easy Ease to ramp the speed. Option-drag a marker to pull out a handle. L locks or unlocks the picked markers.")
            Text("M puts a marker under the playhead; ← → move the selected point a frame.")
                .foregroundStyle(Design.textTertiary)
        }
        .font(Design.Typeface.label)
        .foregroundStyle(Design.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: A point

    /// Several points picked: what can be done to them all at once.
    private func pickedPointsControls(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            heading("\(count) markers")
            HStack(spacing: Design.Space.close) {
                Button("Lock") { session.setLockedOfPicked(true) }
                    .help("Lock the picked markers (L)")
                Button("Unlock") { session.setLockedOfPicked(false) }
            }
            Menu("Ease") {
                ForEach(TimePoint.presets) { preset in
                    Button(preset.name) { session.setEaseOfPicked(preset) }
                        .help(Self.easeDetail(preset))
                }
            }
            .fixedSize()
            HStack(spacing: Design.Space.close) {
                Button { session.nudgeSelected(byFrames: -1) } label: { Image(systemName: "chevron.left") }
                    .help("A frame earlier (←)")
                    .accessibilityLabel("Move the points a frame earlier")
                Button { session.nudgeSelected(byFrames: 1) } label: { Image(systemName: "chevron.right") }
                    .help("A frame later (→)")
                    .accessibilityLabel("Move the points a frame later")
                Spacer()
                Button("Remove", role: .destructive) { session.deleteSelected() }
                    .disabled(!session.canRemovePicked)
                    .help("Remove the picked unlocked markers (Delete)")
            }
        }
    }

    private func pointControls(_ point: TimePoint) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            heading(session.selectedPlace?.index == 0 ? "First frame" : session.selectedPlace.map { $0.index == $0.map.points.count - 1 } == true ? "Last frame" : "Marker")
            reading("Plays at", session.timecode(point.time))
            reading("Frame", session.timecode(point.source))
            Toggle("Locked", isOn: Binding(get: { point.locked }, set: { session.setLocked($0, ofPoint: point.id) }))
                .toggleStyle(.checkbox)
                .help("Hold this frame at this moment (L)")
            if let place = session.selectedPlace {
                if place.index > 0 { reading("Speed before", "\(place.map.speed(after: place.index - 1).formatted(.number.precision(.fractionLength(1))))%") }
                if place.index + 1 < place.map.points.count { reading("Speed after", "\(place.map.speed(after: place.index).formatted(.number.precision(.fractionLength(1))))%") }
            }
            if let found = session.run.piece(holdingPoint: point.id) {
                footageNote(session.run.pieces[found.piece])
            }
            easeControls(point)
            HStack(spacing: Design.Space.close) {
                Button { session.nudgeSelected(byFrames: -1) } label: { Image(systemName: "chevron.left") }
                    .help("A frame earlier (←)")
                    .accessibilityLabel("Move a frame earlier")
                Button { session.nudgeSelected(byFrames: 1) } label: { Image(systemName: "chevron.right") }
                    .help("A frame later (→)")
                    .accessibilityLabel("Move a frame later")
                Spacer()
                if session.selectedPlace?.map.isEdge(point.id) == false {
                    Button("Remove", role: .destructive) { session.deleteSelected() }
                        .disabled(point.locked)
                        .help("Remove this marker (Delete)")
                }
            }
        }
    }

    /// The point's ease, chosen from the keyframe eases by name, and the
    /// handle on each side it eases: how far it reaches and the speed it
    /// sets at the point. Edge markers only offer their side inside the clip.
    @ViewBuilder
    private func easeControls(_ point: TimePoint) -> some View {
        let canEase = session.run.canEase(point: point.id)
        HStack(spacing: Design.Space.close) {
            Text("Ease")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 58, alignment: .leading)
            Picker("Ease", selection: Binding(get: { point.easePreset }, set: { session.setEase($0, ofPoint: point.id) })) {
                ForEach(TimePoint.presets) { preset in
                    Text(preset.name).tag(preset)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!canEase && !point.eased)
            .accessibilityLabel("Ease")
            .help("\(Self.easeDetail(point.easePreset)) (E for Easy Ease)")
        }
        if !canEase {
            Text(MotionDesignSession.nothingToEase)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let place = session.selectedPlace {
            if point.easeIn != nil, point.easeOut != nil {
                // The keyboard's way to part them, as Option-dragging does.
                Toggle("Handles in line", isOn: Binding(get: { point.smooth }, set: { smooth in
                    session.perform(smooth ? "Join Handles" : "Break Handles") { $0.setSmooth(smooth, ofPoint: point.id) }
                }))
                .font(Design.Typeface.label)
                .help("Keeps the speed from stepping at this point: tilting one handle tilts the other (Option-drag a handle to move it alone)")
            }
            ForEach([TimePoint.Side.before, .after], id: \.self) { side in
                if let ease = point.ease(side), place.map.canEase(side, of: place.index) {
                    handleControls(side, ease: ease, speed: place.map.speed(side, at: place.index), point: point)
                }
            }
        }
    }

    /// What an ease does at a point, as the keyframe eases' details say
    /// what they do to a value.
    static func easeDetail(_ preset: KeyframeEase.Preset) -> String {
        switch preset {
        case .linear, .hold: "Runs straight into and out of this point, so the speed steps here"
        case .easeIn: "Slows the footage into this point"
        case .easeOut: "Leaves this point slowly"
        case .easyEase: "Slows into this point and leaves it slowly"
        }
    }

    /// The handle on one side of a point, as dragging it on the graph sets
    /// it: how far into the stretch it reaches, and the speed the line has
    /// at the point. A drag of the slider is one undo step.
    private func handleControls(_ side: TimePoint.Side, ease: KeyframeEase, speed: Double, point: TimePoint) -> some View {
        let label = side == .before ? "Ease In" : "Ease Out"
        let percent = "\(Int((ease.influence * 100).rounded()))%"
        return VStack(alignment: .leading, spacing: Design.Space.close) {
            HStack(spacing: Design.Space.close) {
                Text(label)
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .frame(width: 58, alignment: .leading)
                Slider(
                    value: Binding(get: { ease.influence }, set: { reach in
                        session.perform("Shape \(label)") {
                            $0.setHandle(side, ofPoint: point.id, to: KeyframeEase(influence: reach, speed: ease.speed))
                        }
                    }),
                    in: 0.05...1
                ) { editing in
                    if editing { session.beginDragIfNeeded() } else { session.endDrag("Shape \(label)") }
                }
                .accessibilityLabel("\(label) reach")
                .accessibilityValue("\(percent) of the stretch")
                Text(percent)
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textPrimary)
                    .frame(width: 34, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .help(side == .before
                  ? "How far into the stretch before this point its handle reaches"
                  : "How far into the stretch after this point its handle reaches")
            HStack(spacing: Design.Space.close) {
                Text("Speed")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .frame(width: 58, alignment: .leading)
                NumericField(value: speed, unit: "%", fractionDigits: 1, accessibilityName: "\(label) speed at this point in percent") { typed in
                    session.setSelectedSpeed(side, to: typed)
                }
                .help(side == .before
                      ? "The speed the footage arrives at this point with, as tilting the handle sets it"
                      : "The speed the footage leaves this point with, as tilting the handle sets it")
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: A clip

    private func pieceControls(_ piece: MotionRun.Piece) -> some View {
        let drafted = session.drafted(piece)
        return VStack(alignment: .leading, spacing: Design.Space.step) {
            heading(session.project.resolvedInfo(for: piece.clip.source)?.name ?? "Clip")
            reading("Starts", session.timecode(drafted.startOffset))
            reading("Ends", session.timecode(drafted.endOffset))
            trimRow("Start", piece: piece, edge: .start)
            trimRow("End", piece: piece, edge: .end)
            footageNote(piece)
            if session.run.canMove(piece.id) {
                HStack(spacing: Design.Space.close) {
                    Button { session.nudgeSelectedPiece(byFrames: -1) } label: { Image(systemName: "chevron.left") }
                        .help("Move the clip a frame earlier")
                        .accessibilityLabel("Move the clip a frame earlier")
                    Button { session.nudgeSelectedPiece(byFrames: 1) } label: { Image(systemName: "chevron.right") }
                        .help("Move the clip a frame later")
                        .accessibilityLabel("Move the clip a frame later")
                }
                Text("Drag the clip in the strip to move it; it stops at the clips beside it.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A locked marker holds this clip to its moment. Unlock its markers to move it.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A frame either way for one edge of a clip, as dragging it does.
    private func trimRow(_ label: String, piece: MotionRun.Piece, edge: MotionRun.Edge) -> some View {
        HStack(spacing: Design.Space.close) {
            Text("Trim \(label.lowercased())")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
            Spacer()
            Button { session.trimSelectedPiece(edge, byFrames: -1) } label: { Image(systemName: "chevron.left") }
                .help("\(label) a frame earlier")
                .accessibilityLabel("\(label) a frame earlier")
            Button { session.trimSelectedPiece(edge, byFrames: 1) } label: { Image(systemName: "chevron.right") }
                .help("\(label) a frame later")
                .accessibilityLabel("\(label) a frame later")
        }
    }

    /// Says when a clip has used all the footage its scene has on a side.
    @ViewBuilder
    private func footageNote(_ piece: MotionRun.Piece) -> some View {
        let start = piece.isAtFootageEdge(.start), end = piece.isAtFootageEdge(.end)
        if start || end {
            let side = start && end ? "either side" : start ? "before its start" : "after its end"
            Text("No more of its scene \(side). Merge scenes in the browser to give it more footage.")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(Design.Typeface.groupTitle)
            .foregroundStyle(Design.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private func reading(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
            Spacer()
            Text(value)
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(Design.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The monitor: the editor's own player, which plays the project with the
/// run written in, as the viewer would, and its paused frame over it.
private struct MotionDesignMonitor: View {
    let session: MotionDesignSession

    var body: some View {
        ViewerLayerView(display: session.playback.display)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Design.Surface.well.color)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Monitor")
            .accessibilityAddTraits(.isImage)
    }

    /// The timeline's frame shape.
    private var aspect: CGFloat {
        let size = session.timeline.frameSize
        return size.height > 0 ? size.width / size.height : 16 / 9
    }
}
